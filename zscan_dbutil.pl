#!/usr/bin/env perl
use strict;
use warnings;

# Database imports
#
# Get DBD::SQLite to install all you need
#
use DBI qw(:sql_types);

=head1 NAME

zscan_dbutil.pl - Perl script for administrative utilities for working
with ZScan SQL databases.

=head1 SYNOPSIS

  ./zscan_dbutil.pl list  [dbpath]
  ./zscan_dbutil.pl new   [dbpath] [uid] [mode]
  ./zscan_dbutil.pl mode  [dbpath] [uid] [mode]
  ./zscan_dbutil.pl query [dbpath] [uid]

=head1 DESCRIPTION

Administrative utilities for working with ZScan SQL databases.  Use the
C<list> verb to see all datasets in the database and what their modes
are.  Use the C<new> verb to create a new dataset.  Use the C<mode>
verb to change the mode of an existing dataset.  Use the C<query> verb
to print out all the records associated with a specific dataset.

All utility verbs take a C<[dbpath]> argument that is the path to the
SQL database to work with.  Transactions are used, so it is safe to use
these utilities on active databases.  The database should have been
created with the C<zscan_createdb.pl> script so that it has the proper
structure.

All utility verbs except C<list> take a C<[uid]> argument that specifies
a unique database identifier.  For the C<new> verb, no dataset may
currently have this identifier, and a new dataset will be created.  For
the C<mode> and C<query> verbs, the dataset must currently exist.
Unique identifiers must be strings of one to 255 ASCII alphanumerics and
underscores, and they are case insensitive, being normalized to
lowercase before being inserted.

The C<new> and C<mode> verbs also take a C<[mode]> argument that
specifies one of the special modes to set for the dataset.  For C<new>,
this is the initial mode that will be set.  For C<mode>, the current
mode will be changed to the specified mode.  The C<wait> mode
corresponds to a C<?> symbol in the C<zsetpwh> database field, and it
means that this dataset can be claimed by the first client that attempts
to claim it.  The C<block> mode corresponds to a C<!> symbol, and it
means that this dataset can neither be claimed nor connected to by
clients.  The C<all> mode corresponds to a C<*> symbol, and it means
that the dataset can't be claimed, but any client may connect to it as
if it had claimed it, and any password will work.

(The C<all> mode is intended to fix error cases in clients, where you
need to allow the client to sync one last time before resetting it.  You
should never leave a dataset in C<all> mode for more than a short time
because there is no authentication.)

There is another mode, in which a specific client has claimed the
dataset and is using it.  You can't set this mode directly.  Instead,
set the C<wait> mode and then when the client claims the dataset, it
will be changed into this claimed mode.

=cut

# ==================
# Program entrypoint
# ==================

# If no arguments passed, print a syntax summary and exit
#
if ($#ARGV < 0) {
  print q{zscan_dbutil syntax:

  ./zscan_dbutil.pl list  [dbpath]
  ./zscan_dbutil.pl new   [dbpath] [uid] [mode]
  ./zscan_dbutil.pl mode  [dbpath] [uid] [mode]
  ./zscan_dbutil.pl query [dbpath] [uid]

[dbpath] is the path to the database
[uid] is the unique ID of a dataset
[mode] is either 'wait' or 'block' or 'all'
};

  exit;
}

# Get the needed arguments for the specific verb
#
my $arg_verb;
my $arg_dbpath;
my $arg_uid;
my $arg_mode;
my $count_of_args;

$arg_verb = $ARGV[0];

if ($arg_verb eq 'list') {
  ($#ARGV == 1) or die "Wrong number of arguments for verb, stopped";
  $arg_dbpath = $ARGV[1];
  $count_of_args = 1;
  
} elsif ($arg_verb eq 'new') {
  ($#ARGV == 3) or die "Wrong number of arguments for verb, stopped";
  $arg_dbpath = $ARGV[1];
  $arg_uid    = $ARGV[2];
  $arg_mode   = $ARGV[3];
  $count_of_args = 3;
  
} elsif ($arg_verb eq 'mode') {
  ($#ARGV == 3) or die "Wrong number of arguments for verb, stopped";
  $arg_dbpath = $ARGV[1];
  $arg_uid    = $ARGV[2];
  $arg_mode   = $ARGV[3];
  $count_of_args = 3;
  
} elsif ($arg_verb eq 'query') {
  ($#ARGV == 2) or die "Wrong number of arguments for verb, stopped";
  $arg_dbpath = $ARGV[1];
  $arg_uid    = $ARGV[2];
  $count_of_args = 2;
  
} else {
  die "Unrecognized verb '$ARGV[0]', stopped";
}

# Convert arguments to strings and check; also, normalize uid argument
# to lowercase if given
#
if ($count_of_args >= 1) {
  $arg_dbpath = "$arg_dbpath";
  (-f $arg_dbpath) or die "Failed to find file '$arg_dbpath', stopped";
}

if ($count_of_args >= 2) {
  $arg_uid = "$arg_uid";
  ($arg_uid =~ /^[A-Za-z0-9_]{1,255}$/) or
    die "Invalid format for dataset uid, stopped";
  $arg_uid =~ tr/A-Z/a-z/;
}

if ($count_of_args >= 3) {
  $arg_mode = "$arg_mode";
  (($arg_mode eq 'wait') or ($arg_mode eq 'block')
    or ($arg_mode eq 'all')) or die "Invalid mode, stopped";
}

# Connect to the SQLite database; also, turn autocommit mode off so we
# can use transactions, and set RaiseError so we get exceptions
#
my $dbh = DBI->connect("dbi:SQLite:dbname=$arg_dbpath", "", "", {
                        AutoCommit => 0,
                        RaiseError => 1
                      }) or
  die "Can't connect to database '$arg_dbpath', stopped";

# Wrap the rest of the program in an eval so that a rollback is issued
# if there is any error
#
eval {

  # Handle the different verbs
  if ($arg_verb eq 'list') { # =========================================
    # Query all dataset unique identifiers and their modes
    my $qr = $dbh->selectall_arrayref(
        'SELECT zsetuid, zsetpwh FROM zset');
    
    # If results, then print them
    if (ref($qr) eq 'ARRAY') {
      for my $r (@$qr) {
        
        # Get the fields for this result record
        my $uid  = $r->[0];
        my $mode = $r->[1];
        
        # If mode is not exactly one character, change it to a dot
        if (length($mode) != 1) {
          $mode = '.';
        }
        
        # Print this record
        print "$mode $uid\n";
      }
    }
    
  } elsif ($arg_verb eq 'new') { # =====================================
    # Begin immediate transaction
    $dbh->do('BEGIN IMMEDIATE TRANSACTION');
    
    # Check whether the given unique ID already exists
    (not ref($dbh->selectrow_arrayref(
            'SELECT zsetid FROM zset WHERE zsetuid=?',
            undef,
            $arg_uid))) or
      die "Dataset identifier '$arg_uid' already defined, stopped";
    
    # Convert mode to appropriate special character value
    if ($arg_mode eq 'wait') {
      $arg_mode = '?';
      
    } elsif ($arg_mode eq 'block') {
      $arg_mode = '!';
      
    } elsif ($arg_mode eq 'all') {
      $arg_mode = '*';
      
    } else {
      die "Unexpected";
    }
    
    # Insert new record
    $dbh->do(
      'INSERT INTO zset (zsetuid, zsetpwh) VALUES (?, ?)',
      undef,
      $arg_uid, $arg_mode);
    
  } elsif ($arg_verb eq 'mode') { # ====================================
    # Begin immediate transaction
    $dbh->do('BEGIN IMMEDIATE TRANSACTION');
    
    # Check whether the given unique ID already exists
    (ref($dbh->selectrow_arrayref(
            'SELECT zsetid FROM zset WHERE zsetuid=?',
            undef,
            $arg_uid))) or
      die "Dataset identifier '$arg_uid' not defined, stopped";
    
    # Convert mode to appropriate special character value
    if ($arg_mode eq 'wait') {
      $arg_mode = '?';
      
    } elsif ($arg_mode eq 'block') {
      $arg_mode = '!';
      
    } elsif ($arg_mode eq 'all') {
      $arg_mode = '*';
      
    } else {
      die "Unexpected";
    }
    
    # Update mode
    $dbh->do(
      'UPDATE zset SET zsetpwh=? WHERE zsetuid=?',
      undef,
      $arg_mode, $arg_uid);
    
  } elsif ($arg_verb eq 'query') { # ===================================
    # Look up the internal ID of the dataset
    my $dsr = $dbh->selectrow_arrayref(
            'SELECT zsetid FROM zset WHERE zsetuid=?',
            undef,
            $arg_uid);
    (ref($dsr) eq 'ARRAY') or
      die "Dataset identifier '$arg_uid' not defined, stopped";
    my $dsi = $dsr->[0];
    
    # Get all records for the dataset
    my $ra = $dbh->selectall_arrayref(
            'SELECT zscanisbn, zscantime, zscancflag '
            . 'FROM zscan WHERE zsetid=? ORDER BY zscanseq',
            undef,
            $dsi);
    
    # Print any results
    if (ref($ra) eq 'ARRAY') {
      for my $r (@$ra) {
        
        # Get fields
        my $isbn  = $r->[0];
        my $stime = $r->[1];
        my $cflag = $r->[2];
        
        # Change cflag to a space if not set, and an asterisk if set
        if ($cflag == 0) {
          $cflag = ' ';
        } else {
          $cflag = '*';
        }
        
        # Parse the time, minute accuracy
        my (undef,$min,$hour,$mday,$mon,$year,undef,undef,undef) =
          gmtime($stime * 60);
        
        # Reassemble the time in standard format
        $stime = sprintf '%04u-%02u-%02uT%02u:%02u',
                    ($year + 1900), ($mon + 1), $mday, $hour, $min;
        
        # Print the record
        print "$cflag $isbn $stime\n";
      }
    }
    
  } else {
    # Shouldn't happen
    die "Unexpected";
  }
  
  # If we got here, commit all our changes to the database
  $dbh->commit or
    die "Commit error: $dbh->errstr, stopped";

};
if ($@) {
  # An error happened, so rollback, disconnect from database, and raise
  # the error again
  $dbh->rollback;
  $dbh->disconnect;
  die $@;
}

# If we got here successfully, we can disconnect from the database
#
$dbh->disconnect;

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
