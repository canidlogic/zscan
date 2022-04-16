#!/usr/bin/env perl
use strict;
use warnings;

# Non-core imports
#
use JSON::Tiny qw( decode_json encode_json );

=head1 NAME

zscan.pl - Perl CGI script for server-side operations of ZScan.

=head1 SYNOPSIS

  /cgi-bin/zscan.pl

=head1 DESCRIPTION

This CGI script provides access to the ZScan::Claim and ZScan::Update
modules.

First, the script makes sure that the CGI environment variable
C<REQUEST_METHOD> is defined and has the value C<POST>.  If the variable
is not defined, this script faults saying that it is a CGI script.  If
the variable has some other value, this script returns HTTP 505 Method
Not Allowed.

Second, the script makes sure that the CGI environment variable
C<CONTENT_LENGTH> is defined and consists of a sequence of one or more
ASCII decimal digits that stores a value that is at least one and at
most 999999999.  Otherwise, this script returns HTTP 400 Bad Request.

Third, the script reads however many bytes were indicated by the
C<CONTENT_LENGTH> environment variable from standard input and then
parses this as JSON.  If parsing fails, this script returns HTTP 400 Bad
Request.

Fourth, the script makes sure that the top-level JSON entity is a JSON
object and that it has a scalar property named C<verb> with HTTP 400 Bad
Request returned if this is not the case.  The value of the C<verb>
property selects the specific action performed by the script, and the
following subsections describe the subsequent actions of the script for
each supported verb.  If the client provided an unsupported verb, the
script returns HTTP 400 Bad Request.

=head2 Claim verb request

If the C<verb> property of the passed JSON object is a case-sensitive
match for C<claim> then this script will process a claim request.

For this verb, the passed JSON object must also include property
C<dsname> and a property C<dspass> both of which must have scalar values
which are interpreted as strings.  Both of these string values will be
passed to the ZSync::Claim module.  See the documentation in that module
for further detail.  HTTP 400 Bad Request is returned if the passed JSON
object doesn't have the required format.

If the claim operation fails, this script returns HTTP 403 Forbidden
indicating that the requested dataset could not be claimed.

If the claim operation succeeds, this script returns HTTP 200 OK and
then its return data is JSON.  This return JSON is an array of zero or
more existing records in the dataset.  Each record is an array of
exactly four scalar values:  (1) an integer sequence number; (2) a
string of 13 digits for the ISBN-13 number; (3) an integer storing the
number of minutes since the Unix epoch until the scan; (4) false for
regular records, true if the record has been canceled.

=head2 Update verb request

If the C<verb> property of the passed JSON object is a case-sensitive
match for C<update> then this script will process an update request.

For this verb, the passed JSON object must also include properties
C<dsname> C<dspass> and C<recset> where C<dsname> and C<dspass> are
scalar values holding the dataset name and the passcode for the dataset,
and C<recset> is an array of zero or more update records.

Each update record is an array of exactly four scalar values:  (1) an
integer sequence number; (2) a string of 13 digits for the ISBN-13
number; (3) an integer storing the number of minutes since the Unix
epoch until the scan; (4) false for regular records, true if the record
has been canceled.

The provided data will be passed through to the ZSync::Update module.
See the documentation in that module for further detail.  HTTP 400 Bad
Request is returned if the passed JSON object doesn't have the required
format.

If the update operation fails, this script returns HTTP 403 Forbidden.
If the update operation succeeds, this script returns HTTP 200 OK.  The
data returned in HTTP 200 OK is just a plain-text message C<Updated.>
with a line break.

=head1 INSTALLATION

First, you will need to create a configuration module.  The
configuration module contents look like this:

  package ZScanConfig;
  use parent qw(Exporter);
  
  our @EXPORT = qw($zscan_conf_dbpath);
  
  $zscan_conf_dbpath = "/path/to/zscan/db";
  
  1;

Replace the C</path/to/zscan/db> with the path to the ZScan SQLite
database that this CGI script will provide access to.  You should use
the C<zscan_createdb.pl> script to generate a ZScan SQLite database with
the appropriate structure.

Second, place this configuration module into a directory somewhere on
the server and name it C<ZScanConfig.pm>  This directory should I<not>
be one of the public directories that can be accessed over HTTP, nor
should it be the cgi-bin directory.  If you have multiple ZScan
instances running on the same server, each ZScan configuration script
will need to be in its own unique directory.

Third, make a copy of this C<zscan.pl> CGI script into a public
directory where it can be accessed over HTTP and where it will be
interpreted as a CGI script.  This is usually a C<cgi-bin> directory.
Each instance of ZScan that is running on a server must have its own
copy of the CGI script.  You may rename this CGI script to something
else if you wish to allow multiple copies of it to be present in the
same C<cgi-bin> directory.

Fourth, edit the first line of this script (the shebang line that begins
with C<#!>) to invoke the Perl interpreter in a manner appropriate for
the specific server, and including the following dependencies into the
Perl include path:

=over 4

=item Configuration module directory

Include the directory that holds the configuration module you defined
in the first and second steps.  If you have multiple ZScan databases on
a single server, each ZScan database needs its own unique configuration
directory, and you must I<only> include the configuration directory for
the database you want this CGI script to connect to.

=item ZScan module directory

Include a directory that holds a subdirectory named C<ZScan> which
includes the C<Claim.pm> and C<Update.pm> modules.  If you have multiple
ZScan databases on a single server, you can share this ZScan module
directory across all instances.

=item CPAN dependencies directory

ZScan depends on certain non-core modules that are part of CPAN.  You
may need to install some or all of these modules if they are not part of
the default Perl environment on your server.

It is recommended that you use C<cpanm> to handle installing CPAN
dependencies.  You can get this by running the following command in your
home directory on the server:

  curl -L https://cpanmin.us | perl - App::cpanminus

You will then get a script C<cpanm> installed in your home directory.
In your home directory, pull in the ZScan dependencies with the 
following command:

  ./cpanm DBD::SQLite Crypt::Bcrypt Crypt::Random JSON::Tiny

In the likely event that you don't have root access, C<cpanm> will
complain about not being able to install files in certain system
locations.  This is fine, because C<cpanm> will fall back to installing
them into a directory within your home directory.  The location of the
installed libraries is probably something like this:

  /home/username/perl5/lib/perl5

You will need to include the appropriate installed CPAN libraries
directory into the shebang line of this script so that ZScan will be
able to find its dependencies.

=back

Suppose that files are in the following locations on the server:

  /home/example/siteconfig/ZScanConfig.pm
  /home/example/liblocal/ZScan/Claim.pm
  /home/example/liblocal/ZScan/Update.pm
  /home/example/perl5/lib/perl5 (CPAN packages)
  /home/example/public_html/cgi-bin/zscan.pl

Then, the shebang line for C<zscan.pl> would look like this (all on one
line):

  #!/usr/bin/perl -I/home/example/siteconfig -I/home/example/liblocal
  -I/home/example/perl5/lib/perl5

=cut

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
