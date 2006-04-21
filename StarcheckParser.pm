##Starcheck parsing utilities   
##Brett Unks                      
##Jan 2003                        


##***************************************************************************
##***************************************************************************
package StarcheckParser;
##***************************************************************************
##***************************************************************************

use Carp;

@EXPORT = qw(new_starcheck
	     get_obsids
             get_obsdata);

##***************************************************************************
sub new_starcheck {
##***************************************************************************
    my ($class, $fn) = @_;
    local $/ = undef;
    open(my $file, $fn) or croak "Invalid filename: $fn";
    my $starcheck = <$file>;
    bless \$starcheck, $class;
}

##***************************************************************************
sub get_obsids {
##***************************************************************************
    my ($starcheck) = @_;
    my @tmp = split "\n", $$starcheck;
    my @obsids = map { /OBSID: (\d+) / } @tmp;
    return @obsids;
}

##***************************************************************************
sub get_obsdata {
##***************************************************************************
    my ($starcheck, $obsid) = @_;
    my @tmp = split /\={84}\n\n/, $$starcheck;
    my @tmp1 = grep /OBSID: $obsid/, @tmp;
    my $obs_data = shift @tmp1;
    return ObsidParser->new_obsid($obs_data);
}





##***************************************************************************
##***************************************************************************
package ObsidParser;
##***************************************************************************
##***************************************************************************

use Carp;

@EXPORT = qw(new_obsid
	     get_coords
	     get_quat
	     get_stars
	     get_warnings
	     get_star_type);

##***************************************************************************
sub new_obsid {
##***************************************************************************
    my ($class, $obs_data) = @_;
    bless \$obs_data, $class;
}

##***************************************************************************
sub get_coords {
##***************************************************************************
    my ($data) = @_;
    $$data =~ /RA, Dec, Roll \(deg\):\s+(.+)\n/;
    my @tmp = split " ", $1;
    my %coords = (
		  RA   => $tmp[0],
		  DEC  => $tmp[1],
		  ROLL => $tmp[2]
		  );
    return %coords;
}

##***************************************************************************
sub get_quat {
##***************************************************************************
    my ($data) = @_;
    $$data =~ /(Q1,Q2,Q3,Q4):\s+(.+)\n/;
    my @tmp = split ",", $1;
    my @tmp1 = split " ", $2;
    my %quat = (
		  $tmp[0] => $tmp1[0],
		  $tmp[1] => $tmp1[1],
		  $tmp[2] => $tmp1[2],
		  $tmp[3] => $tmp1[3]
		  );
    return %quat;
}

##***************************************************************************
sub get_stars {
##***************************************************************************
    my ($data) = @_;
    my @stars;
    #pull out the header
    $$data =~ /\-+\n\s+(.+)\n\-+\n/;
    my @hdr = split " ", $1;
    #now parse out the stars and return an array of hashes
    my @block = split "\n", $$data;
    my @indices = grep /^\[.+\]\s+(.+)/, @block;
    map { s/^(?:\[ |\[)(.+)\]\s+(.+)/$1 $2/} @indices;
    for my $i (0.. $#indices){
	my @tmp = split " ", $indices[$i];
	for my $j (0.. $#hdr) { $stars[$i]{$hdr[$j]} = $tmp[$j] if defined $tmp[$j]};
    }
    return @stars;
} 

##***************************************************************************
sub get_warnings {
##***************************************************************************
    my ($data, $index) = @_;
    my @block = split "\n", $$data;
    my @tmp = grep /^\>\>\s+WARNING:/, @block;
    my @warnings;
    for my $i (0.. $#tmp) {

	next unless $tmp[$i] =~ /.*WARNING.*\[ *(\d+)\]((\w|\s)*)\.(.*)$/;
	next unless $1 == $index;
	my $type = $2;
	my $warn_index = $1;
	my $details = $4;
	$details =~ s/^\s*//;
	push @warnings, {
	    TYPE    => $type,
	    INDEX   => $warn_index,
	    DETAILS => $details,
	};
    }
    return @warnings;
}	

##***************************************************************************
sub get_star_type {
##***************************************************************************
    my ($data, $type) = @_;
    croak "Invalid star type specified" unless $type =~ /(ACQ|GUI|BOT|FID|MON)/;
    $type = "\($type\|BOT\)" if $type =~ /ACQ|GUI/;
    my @stars = $data->get_stars();
    my @acq_stars = grep { $_->{TYPE} =~ /$type/ } @stars;
    return @acq_stars;
}

##***************************************************************************
sub print {
##***************************************************************************
    my ($data, $handle) = (@_, *STDOUT{IO});
    print $handle $$data;
}
