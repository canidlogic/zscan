package ZScan::Claim;
use strict;

# Non-core imports
#
use Crypt::Bcrypt qw( bcrypt );
use Crypt::Random qw( makerandom_octet );

# Database imports
#
# Get DBD::SQLite to install all you need
#
use DBI qw(:sql_types);

=head1 NAME

ZScan::Claim - Handle an attempt to claim a dataset.

=head1 SYNOPSIS

  use ZScan::Claim;
  
  # Claim dataset_name and set passcode to "passcode"
  my $claim = ZScan::Claim->bind("dbpath", "dataset_name", "passcode");
  
  # Add each existing record
  for(my $i = 0; $i < $claim->count; $i++) {
    my ($seq, $isbn, $tstamp, $cflag) = $claim->record($i);
    ...
  }

=head1 DESCRIPTION

This module handles the process of claiming a specific dataset with a
given password, and then retrieving a list of all records that are
currently in the dataset.

When a client has just created a new local database, they must then
claim a specific dataset on the server which they will synchronize with.
The records returned during the claim process is the initial act of
synchronizing the existing server database to the new client database.
After that, the client synchronizes changes to records with the server
database (covered by a different module).

Only one client database can be bound to a specific dataset, so that
there are no complex issues of trying to synchronize server databases
and multiple client copies.

=head1 CONSTRUCTOR

=over 4

=item B<ZScan::Claim->bind(dbpath, dsname, passcode)>

Claim a dataset and construct an object that holds all the records
currently in the server database.

C<dbpath> is the path to the SQLite database.  It should have been
created with the C<zscan_createdb.pl> script.

C<dsname> is the name of the dataset.  It must name an existing dataset
within the database.  Also, the dataset must have the special status
C<?> set in its C<zsetpwh> field.  You can use the C<zscan_dbutil.pl>
script to create datasets and change modes.  The mode you need to allow
for a claim to succeed is C<wait>.  The dataset name must be 1 to 255
ASCII alphanumeric characters and underscore.  This function will
normalize it to lowercase.

C<passcode> is a plain-text password that the client will use to access
the dataset.  This must be a string of US-ASCII printing, non-whitespace
characters in range [U+0021, U+007E], and the length of this string must
be in range [1, 64].  The password will be stored in an encrypted form
in the SQLite database.

If successful, the dataset will be claimed and any other attempt to
claim it will fail.  (Unless C<zscan_dbutil.pl> is used to change its
mode back to C<wait>)

If there is any error, a fault occurs and the database is not modified.
If you want to catch errors, use an C<eval> block.

=cut

sub bind {
  
  # Check parameter count
  ($#_ == 3) or die "Wrong number of parameters, stopped";
  
  # Get invocant and parameters
  my $invocant = shift;
  my $class = ref($invocant) || $invocant;
  
  my $dbpath   = shift;
  my $dsname   = shift;
  my $passcode = shift;
  
  ((not ref($dbpath)) and (not ref($dsname)) and
      (not ref($passcode))) or die "Wrong parameter types, stopped";
  
  $dbpath   = "$dbpath";
  $dsname   = "$dsname";
  $passcode = "$passcode";
  
  # Check that database exists
  (-f $dbpath) or die "Can't find database, stopped";
  
  # Check dataset name
  ($dsname =~ /^[A-Za-z0-9_]{1,255}$/) or
    die "Invalid dataset name, stopped";
  
  # Normalize dataset name to lowercase
  $dsname =~ tr/A-Z/a-z/;
  
  # Check passcode
  ($passcode =~ /^[\x{21}-\x{7e}]{1,64}$/) or
    die "Invalid passcode, stopped";
  
  # Replace passcode with a bcrypt hash
  $passcode = bcrypt(
                $passcode, '2b', 5, makerandom_octet( Length => 16));
  
  # Connect to the SQLite database; also, turn autocommit mode off so we
  # can use transactions, and set RaiseError so we get exceptions
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbpath", "", "", {
                          AutoCommit => 0,
                          RaiseError => 1
                        }) or
    die "Can't connect to database, stopped";
  
  # Wrap the rest of the function in an eval so that a rollback is
  # issued if there is any error before rethrowing
  my $recset;
  eval {
    # Begin immediate transaction
    $dbh->do('BEGIN IMMEDIATE TRANSACTION');
    
    # Look up the internal ID of the dataset and make sure it can be
    # claimed
    my $dsr = $dbh->selectrow_arrayref(
            'SELECT zsetid FROM zset WHERE zsetuid=? AND zsetpwh=?',
            undef,
            $dsname, '?');
    (ref($dsr) eq 'ARRAY') or
      die "Dataset identifier '$dsname' not claimable, stopped";
    my $dsi = $dsr->[0];
    
    # Claim the dataset
    $dbh->do(
            'UPDATE zset SET zsetpwh=? WHERE zsetid=?',
            undef,
            $passcode, $dsi);
    
    # Get all records currently in the dataset
    $recset = $dbh->selectall_arrayref(
            'SELECT zscanseq, zscanisbn, zscantime, zscancflag '
            . 'FROM zscan WHERE zsetid=? ORDER BY zscanseq ASC',
            undef,
            $dsi);
    if (not (ref($recset) eq 'ARRAY')) {
      $recset = [];
    }
    
    # If we got here, commit all our changes to the database
    $dbh->commit or
      die "Commit error: $dbh->errstr, stopped";
    
  };
  if ($@) {
    # An error happened, so rollback, disconnect from database, and
    # raise the error again
    $dbh->rollback;
    $dbh->disconnect;
    die $@;
  }
  
  # We have all we need, so disconnect from the database
  $dbh->disconnect;
  
  # Define the object, store the recordset within it, bless it, and
  # return
  my $self = { };
  bless($self, $class);
  
  $self->{'recset'} = $recset;
  return $self;
}

=back

=head1 INSTANCE METHODS

=over 4

=item B<object->count()>

Return the total number of records stored within the claim object.  This
might be zero or greater.

The records stored within the claim object represent the records that
were already present in the dataset when the client claimed it.  The
client should initialize their local data using these claimed records.

=cut

sub count {
  # Check parameter count
  ($#_ == 0) or die "Wrong number of parameters, stopped";
  
  # Get parameters and check
  my $self = shift;
  ((ref $self) and ($self->isa(__PACKAGE__))) or
    die "Wrong parameter type, stopped";
  
  # Return count
  return scalar(@{$self->{'recset'}});
}

=item B<object->record(i)>

Return a specific record stored within the claim object.

The given parameter C<i> is the record index, which must be at least
zero and less than the value returned from the count method.  Records
are sorted in ascending order of sequence number.

The return value in list context will be the sequence number of the
record as an integer, the ISBN-13 number of a string of 13 digits, the
scan time as a number of minutes since the epoch, and an integer flag
that is zero normally or one if the record has been canceled.

=cut

sub record {
  # Check parameter count
  ($#_ == 1) or die "Wrong number of parameters, stopped";
  
  # Get parameters and check
  my $self = shift;
  ((ref $self) and ($self->isa(__PACKAGE__))) or
    die "Wrong parameter type, stopped";
  
  my $i = shift;
  (not (ref $i)) or die "Wrong parameter type, stopped";
  (int($i) == $i) or die "Wrong parameter type, stopped";
  $i = int($i);
  
  # Check index range
  (($i >= 0) and ($i < scalar(@{$self->{'recset'}}))) or
    die "Index out of range, stopped";
  
  # Get record reference
  my $r = $self->{'recset'}->[$i];
  
  # Return record fields
  return ($r->[0], $r->[1], $r->[2], $r->[3]);
}

=back

=head1 AUTHOR

Noah Johnson, C<noah.johnson@loupmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2022 Multimedia Data Technology Inc.

MIT License:

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=cut

# End with something that evaluates to true
#
1;
