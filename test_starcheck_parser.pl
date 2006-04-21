#!/usr/bin/env /proj/sot/ska/bin/perlska
# Doesn't actually do any tests, but prints out dumps of
# star and warning hashes for each obsid and for each index
# to confirm that StarcheckParsers is getting all of the
# right data.

use StarcheckParser;
use Data::Dumper;	

my $starcheck = StarcheckParser->new_starcheck("./test.txt");

my @obsids = $starcheck->get_obsids();

#print "$#obsids \n";

for my $obsid (@obsids){

    print "Catalog and Warnings for $obsid \n";
    my $obs_data = $starcheck->get_obsdata($obsid);
    my @catalog = $obs_data->get_stars();
    foreach my $entry (@catalog) {
	print Dumper $entry;
	my @warnings = $obs_data->get_warnings($entry->{'IDX'});
	foreach my $warning (@warnings) {
	    print "Warnings for ", $entry->{'IDX'}, "\n";
	    print Dumper $warning;
    
	}	
	
    }
}



