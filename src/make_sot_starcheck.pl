#!/usr/bin/env perl


use warnings;
use strict;
use Getopt::Long;


my %opt = ();

GetOptions(\%opt,
	   "ska=s",
	   "destdir=s",
	   );


my $starcheck = 'starcheck';
if (defined $opt{destdir}){
    $starcheck = "$opt{destdir}/$starcheck";
}

my $TASK = "ska_re";

my $PREFIX = $opt{ska} || "/usr/local";
my $BIN = "$opt{ska}/bin";

my $SCRIPT;

open($SCRIPT,">$starcheck") || die("Cannot Open File");
print $SCRIPT "#!/bin/sh\n";
print $SCRIPT "/usr/bin/env -u LD_LIBRARY_PATH ";
print $SCRIPT "${BIN}/starcheck.pl ";
print $SCRIPT '"$@"';
print $SCRIPT "\n";
close $SCRIPT;
