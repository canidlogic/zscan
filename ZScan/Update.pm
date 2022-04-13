package ZScan::Update;
use strict;

# Non-core imports
#
use Crypt::Bcrypt qw( bcrypt_check );

# Database imports
#
# Get DBD::SQLite to install all you need
#
use DBI qw(:sql_types);

=head1 NAME

ZScan::Update - Handle an attempt to update a server dataset.

=head1 SYNOPSIS

  use ZScan::Update;
  
  # Create a new update request
  my $upd = ZScan::Update->create;
  
  # Add new and updated records to the request
  $upd->add($seq, $isbn, $tstamp, $cflag);
  ...
  
  # Attempt an update with the records in the request
  $upd->update("dbpath", "dataset_name", "passcode");

=head1 DESCRIPTION

This module handles the process of updating a specific dataset with new
and altered records.

In order to keep the client and server databases synchronized, the
client first receives the initial records in the dataset from the server
when claiming the dataset.  Once the dataset is claimed, only that
specific client has the passcode needed to update the dataset.  The
client therefore only needs to send the server updates, and doesn't have
to worry about receiving further updates from the server, since no other
client is allowed to modify the claimed dataset.

No record can actually be deleted from a dataset.  Instead, each record
has a cancel flag that can be set if the record should be "deleted."
The client therefore only needs to be able to tell the server about new
records and changed records.

The sequence number of a record is never allowed to change once
assigned.  Therefore, if the client sends the server a record with a
sequence number matching something that is already in the database, the
server assumes this is an update and replaces the existing record with
the provided record.  If the client sends the server a record with a
sequence number that does not match anything already existing in the
database, the server assumes this is a new record and inserts it into
the dataset.  It is harmless (though inefficient) to provide the same
record update multiple times to the server.

Before using this update module, you must claim a dataset using the
Claim module.  Then, in order to perform an update, create a new update
object, add all new and updated records to it, and then use the update
method to perform the actual update.

=head1 CONSTRUCTOR

=over 4

=item B<ZScan::Update->create()>

Create a new, empty update object with no records in it.

=cut

sub create {
  
  # Check parameter count
  ($#_ == 0) or die "Wrong number of parameters, stopped";
  
  # Get invocant and parameters
  my $invocant = shift;
  my $class = ref($invocant) || $invocant;
  
  # Define the object, store an empty hash reference within it, bless
  # it, and return; the hash reference will map integer sequence numbers
  # to array references containing the ISBN, timestamp, and cancel flag
  my $self = { };
  bless($self, $class);
  
  $self->{'recset'} = { };
  return $self;
}

=back

=head1 INSTANCE METHODS

=over 4

=item B<object->add(seq, isbn, tstamp, cflag)>

Add another update record to the update request.

seq is the sequence number of the record.  It must be an integer.  No
record currently in the update recordset may match this sequence number.
In the server dataset, if the sequence number does not exist, this
record will be a new record that is added.  If the sequence number
already exists, this record will replace the current record in the
server dataset.  The range of seq must be [0, 2^31 - 1].

isbn is the ISBN-13 number that was scanned.  It must be a string of
exactly 13 ASCII decimal digits.  This function will verify that the
thirteenth digit is a valid check digit according to the ISBN-13 rules,
causing a fault if it is not.

tstamp is an integer value that counts the number of minutes that have
passed since the Unix epoch until the time the scan was made.  The range
of tstamp is [0, 2^31 - 1].

cflag is an integer value that is zero for regular records or one for
canceled records.  Canceled records are "deleted."  (Since there is no
way to delete existing records from a dataset, this cancel flag is used
instead.)

=cut

sub add {
  # Check parameter count
  ($#_ == 4) or die "Wrong number of parameters, stopped";
  
  # Get parameters and check types
  my $self = shift;
  ((ref $self) and ($self->isa(__PACKAGE__))) or
    die "Wrong parameter type, stopped";
  
  my $seq    = shift;
  my $isbn   = shift;
  my $tstamp = shift;
  my $cflag  = shift;
  
  ((not (ref $seq)) and (not (ref $isbn)) and
      (not (ref $tstamp)) and (not (ref $cflag))) or
    die "Wrong parameter type, stopped";
  
  $isbn = "$isbn";
  
  ((int($seq) == $seq) and (int($tstamp) == $tstamp) and
      (int($cflag) == $cflag)) or
    die "Wrong parameter type, stopped";
  
  $seq    = int($seq);
  $tstamp = int($tstamp);
  $cflag  = int($cflag);
  
  # Check integer ranges
  (($seq >= 0) and ($seq <= 2147483647)) or
    die "Sequence number out of range, stopped";
  (($tstamp >= 0) and ($tstamp <= 2147483647)) or
    die "Sequence number out of range, stopped";
  (($cflag == 0) or ($cflag == 1)) or
    die "Cancel flag out of range, stopped";
  
  # Check that ISBN is 13 decimal digits
  ($isbn =~ /^[0-9]{13}$/) or
    die "ISBN format incorrect, stopped";
  
  # Compute the weighted sum of all ISBN digits
  my $wsum = 0;
  my $wval = 1;
  for my $c (split //, $isbn) {
    my $d = ord($c) - ord('0');
    $wsum = $wsum + ($d * $wval);
    if ($wval == 1) {
      $wval = 3;
    } else {
      $wval = 1;
    }
  }
  
  # Make sure the weighted sum of all ISBN digits mod 10 is zero
  (($wsum % 10) == 0) or
    die "ISBN check digit incorrect, stopped";
  
  # Make sure the sequence number is not already in the update recordset
  (not (exists $self->{'recset'}->{"$seq"})) or
    die "Sequence number used twice in update request, stopped";
  
  # Add the new record to the recordset
  $self->{'recset'}->{"$seq"} = [$isbn, $tstamp, $cflag];
}

=item B<object->update(dbpath, dsname, passcode)>

Perform an update operation on the database using the update records
currently stored within the update object.

C<dbpath> is the path to the SQLite database.  It should have been
created with the C<zscan_createdb.pl> script.

C<dsname> is the name of the dataset.  It must name an existing dataset
within the database, and the dataset must either be claimed or have the
special "all" mode of C<!>.  The dataset name must be 1 to 255 ASCII
alphanumeric characters and underscore.  This function will normalize it
to lowercase.

C<passcode> is a plain-text password that was provided by the client
when the dataset was claimed.  This must be a string of US-ASCII
printing, non-whitespace characters in range [U+0021, U+007E], and the
length of this string must be in range [1, 64].  If the dataset is in
the special "all" mode then the passcode is not checked and the update
operation proceeds regardless of what passcode was provided.  Else, if
the dataset is claimed, the provided passcode must match the password
hash stored in the server dataset table.

If successful, the dataset will be updated from all records within the
update object.  If there is any error, a fault occurs and the database
is not modified.  If you want to catch errors, use an C<eval> block.

If you call this function but there are no records stored within the
update object, this function does nothing.  The update object is not
modified by this function and you may continue on using it, though bear
in mind whatever records have already been declared stay declared in the
object.

=cut

sub update {
  
  # Check parameter count
  ($#_ == 3) or die "Wrong number of parameters, stopped";
  
  # Get parameters and check types
  my $self = shift;
  ((ref $self) and ($self->isa(__PACKAGE__))) or
    die "Wrong parameter type, stopped";
  
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
  
  # Get all update records in ascending sequence field order
  my @upl;
  for my $k (sort { int($a) <=> int($b) } keys %{$self->{'recset'}}) {
    push @upl, [
      int($k),
      $self->{'recset'}->{$k}->[0],
      $self->{'recset'}->{$k}->[1],
      $self->{'recset'}->{$k}->[2]
    ];
  }
  
  # If no update records, do nothing further
  ($#upl >= 0) or return;
  
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
    
    # Look up the internal ID and password field of the dataset
    my $dsr = $dbh->selectrow_arrayref(
            'SELECT zsetid, zsetpwh FROM zset WHERE zsetuid=?',
            undef,
            $dsname);
    (ref($dsr) eq 'ARRAY') or
      die "Dataset identifier '$dsname' not found, stopped";
    my $dsi = $dsr->[0];
    my $dsp = $dsr->[1];
    
    # Handle the different passcode field cases
    if (length($dsp) > 1) {
      # Claimed state, so check the passcode
      (bcrypt_check($passcode, $dsp)) or
        die "Dataset authentication failed, stopped";
      
    } else {
      # If not in a claimed state, then we must be in the "all" state or
      # else fault
      ($dsp eq '*') or die "Dataset authentication failed, stopped";
    }
    
    # We are authenticated and know the dataset code, so now we perform
    # each of the updates
    for my $r (@upl) {
      # Get update record fields
      my $seq    = $r->[0];
      my $isbn   = $r->[1];
      my $tstamp = $r->[2];
      my $cflag  = $r->[3];
      
      # Look for a primary key with a matching dataset and sequence
      # number
      my $pkq = $dbh->selectrow_arrayref(
                  'SELECT zscanid FROM zscan '
                  . 'WHERE zsetid=? AND zscanseq=?',
                  undef,
                  $dsi, $seq);
      
      # Different handling depending on whether sequence number is
      # defined already
      if (ref($pkq) eq 'ARRAY') {
        # We found an existing record, so get its primary key
        $pkq = $pkq->[0];
        
        # Update the record
        $dbh->do(
              'UPDATE zscan SET zscanisbn=?, zscantime=?, zscancflag=? '
              . 'WHERE zscanid=?',
              undef,
              $isbn, $tstamp, $cflag, $pkq);
        
      } else {
        # We did not find an existing record, so add a new one
        $dbh->do(
              'INSERT INTO zscan (zsetid, zscanseq, zscanisbn, '
              . 'zscantime, zscancflag) VALUES (?,?,?,?,?)',
              undef,
              $dsi, $seq, $isbn, $tstamp, $cflag);
      }
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
  
  # We have done all we need, so disconnect from the database
  $dbh->disconnect;
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
