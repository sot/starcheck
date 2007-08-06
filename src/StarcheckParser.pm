##Starcheck parsing utilities   
##Brett Unks                      
##Jan 2003                        

# Used by /proj/sot/ska/bin/new_obs.pl - which is no longer running
# Used by /proj/sot/ska/database/star_parse.pl
# part of the starcheck cvs project

##***************************************************************************
##***************************************************************************
package StarcheckParser;
##***************************************************************************
##***************************************************************************

use Carp;
use strict;

#@EXPORT = qw(new_starcheck
#	     get_obsids
#             get_obsdata);

1;
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
    my @tmp1 = grep /OBSID:\s+0*$obsid(\s|\n)/, @tmp;
    my $obs_data;
    if (scalar(@tmp1) == 1){
	$obs_data = shift @tmp1;
	return ObsidParser->new_obsid($obs_data);
    }
    else{
	croak("Error. Obsid not found in starcheck file for load.\n");
    }


}

##***************************************************************************
sub get_load_record{
##***************************************************************************
    my $starcheck = shift;
    my $mp_path = shift;
    my $ap_date = shift;
    return LoadRecord->new_record($starcheck, $mp_path, $ap_date);
}

##***************************************************************************
sub get_header_lines{
##***************************************************************************
    my $starcheck = shift;
    my @tmp = split /\={84}\n\n/, $$starcheck;
    my $header_text = $tmp[0];

    my %header;

    $header_text =~ s/\n------------/\nPARSEBREAK\n------------/g;
    my @tmp1 = split /PARSEBREAK\n/, $header_text;

    my @top_match = grep /Starcheck/, @tmp1;
    if ( scalar(@top_match) == 1){
	my $very_top = $top_match[0];
	my @top_lines = split /\n/, $very_top;
	$header{very_top} = \@top_lines;
    }

    my @proc_match = grep /PROCESSING\sWARNINGS\s/, @tmp1;
    if (scalar(@proc_match) == 1){
	my $processing_warnings = $proc_match[0];
	#remove header
	$processing_warnings =~ s/^------------.*\n//g;
	# remove blank lines
	$processing_warnings =~ s/^\n//g;
	my @warning_lines = split /\n/, $processing_warnings;
	$header{processing_warnings} = \@warning_lines;
    }

    my @file_match = grep /PROCESSING\sFILES/, @tmp1;
    if (scalar(@file_match) == 1){
	my $proc_files = $file_match[0];
	#remove header
        $proc_files =~ s/^------------.*\n//g;
        #remove blank lines
        $proc_files =~ s/^\n//g;
	my @file_lines = split /\n/, $proc_files;
	$header{processing_files} = \@file_lines;
    }


    my @summ_match = grep /SUMMARY\sOF\sOBSIDS\s/, @tmp1;
    if (scalar(@summ_match) == 1){
	my $obsid_summary = $summ_match[0];
	#remove header
	$obsid_summary =~ s/^------------.*\n//g;
	#remove blank lines
	$obsid_summary =~ s/^\n//g;
	my @summary_lines = split /\n/, $obsid_summary;
	$header{obsid_summary} = \@summary_lines;
    }


    
    return %header;

}
##***************************************************************************




##***************************************************************************
##***************************************************************************
package ObsidParser;
##***************************************************************************
##***************************************************************************

use strict;
use Carp;

1;
#@EXPORT = qw(new_obsid
#	     get_full_record
#	     get_target
#	     get_manvr
#	     get_times
#	     get_coords
#	     get_quat
#	     get_stars
#	     get_warnings
#	     get_star_type
#	     get_all_warnings
#	     get_dither_info);

##***************************************************************************
sub new_obsid {
##***************************************************************************
    my ($class, $obs_data) = @_;
    bless \$obs_data, $class;
}

##***************************************************************************
sub get_full_record{
##***************************************************************************
    my $obs_data = shift;
    my $obsid = shift;
    return StarcheckRecord->new_record($obs_data,$obsid)
}

##***************************************************************************
sub get_target{
##***************************************************************************
    my $data = shift;
    my @block = split "\n", $$data;
    my $topline = $block[0];
    my %target;
    if ($topline =~ /OBSID:\s(\S{5})\s*/){
    }
    else{
	if ($topline =~ /OBSID:\s*(\S{1,5})\s+(.*)\s+(\S+)\s+SIM\sZ\soffset:\s*(-*\d+)\s.*\sGrating:\s*(\S+)\s*/ ){
	    if ($topline =~ /OBSID:\s*(\S{1,5})\s+(.*)\s+(\S+)\s+SIM\sZ\soffset:\s*(-*\d+)\s+Grating:\s*(\S+)\s*/ ){
		%target = (
			   'obsid' => $1,
			   'target' => $2,
			   'sci_instr' => $3,
			   'sim_z_offset_steps' => $4,
			   'grating' => $5
			   );
		$target{'target'} =~ s/\s+$//;

	    }
	    if ($topline =~ /OBSID:\s*(\S{1,5})\s+(.*)\s+(\S+)\s+SIM\sZ\soffset:\s*(-*\d+)\s+\((-*.+)mm\)\s+Grating:\s*(\S+)\s*/ ){
		%target = (
			   'obsid' => $1,
			   'target' => $2,
			   'sci_instr' => $3,
			   'sim_z_offset_steps' => $4,
			   'sim_z_offset_mm' => $5,
			   'grating' => $6
			   );
		$target{'target'} =~ s/\s+$//;

	    }
	}
	else{
	    %target = ();
	}
    }
    return %target;
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
	
	if ($tmp[$i] =~ /.*WARNING.*\[ *(\d+)\]((\w|\s)*)\.(.*)$/){
	    if ($1 == $index){
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
	}
	else{
	    if ($tmp[$i] =~ /^\>\>\s+WARNING:\s+(.+)\.\s+(?:\[ |\[)(\d+)\].\s(.+)/){
		if ($2 == $index){
		    push @warnings, {
			TYPE    => $1,
			INDEX   => $2,
			DETAILS => $3,
		    };
		}
	   }
	}
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
sub get_all_warnings {
##***************************************************************************
    my $data = shift;
    my @block = split "\n", $$data;
    my @warnings = grep /^\>\>\s+WARNING:/, @block;
    map { s/^\>\>\s+WARNING:\s+// } @warnings;
    return @warnings;
}

##***************************************************************************
sub get_dither_info {
##***************************************************************************
    my $data = shift;
    my %dither;

    if ($$data =~ /Dither:\s(\S+)\s+Y_amp=\s*(\S+)\s+Z_amp=\s*(\S+)\s+Y_period=\s*(\S+)\s+Z_period=\s*(\S+)\s*\n/){
	%dither = (
		      'state' => $1,
		      'y_amp' => $2,
		      'z_amp' => $3,
		      'y_period' => $4,
		      'z_period' => $5
		      );
    }
    return %dither;
}

##***************************************************************************
sub get_times{
##***************************************************************************
    my $data = shift;
#MP_TARGQUAT at 2006:156:06:36:46.768 (VCDU count = 3473057)
    my %times;
#MP_STARCAT at 2006:156:06:36:48.411 (VCDU count = 3473063)
    if ($$data =~ /MP_STARCAT\sat\s(\S+)\s\(VCDU\scount\s=\s(\d+)\)\n/g){
	$times{'MP_STARCAT'} = $1;
	$times{'VCDU_cnt'} = $2;
    }
    return %times;
}

##***************************************************************************
sub get_manvr{
##***************************************************************************
    my $data = shift;
    my @data_array = split( /\n/, $$data);
#    use Data::Dumper;
#    print Dumper @data_array;
    my @new_man;
    foreach my $i (0 .. $#data_array){
	next unless ($data_array[$i] =~ /\AMP_TARGQUAT/);
	my %temp_manvr;
	if ($data_array[$i] =~ /MP_TARGQUAT\sat\s(\S+)\s\(VCDU\scount\s=\s(\d+)\)/){
	    $temp_manvr{'MP_TARGQUAT'} = $1;
	    $temp_manvr{'VCDU_cnt'} = $2;
	}	
	if ($data_array[$i + 1] =~ /(Q1,Q2,Q3,Q4):\s+(.+)/){
	    my @tmp = split ",", $1;
	    my @tmp1 = split " ", $2;
	    my %quat = (
			$tmp[0] => $tmp1[0],
			$tmp[1] => $tmp1[1],
			$tmp[2] => $tmp1[2],
			$tmp[3] => $tmp1[3]
			);
	    $temp_manvr{Q1}=$quat{Q1};
	    $temp_manvr{Q2}=$quat{Q2};
	    $temp_manvr{Q3}=$quat{Q3};
	    $temp_manvr{Q4}=$quat{Q4};
	}
	if ($data_array[$i + 2] =~ /\s+MANVR:\sAngle=\s+(\S+)\sdeg\s+Duration=\s+(\S+)\ssec\s+Slew\serr=\s+(\S+)\sarcsec\s*/){
	    $temp_manvr{'angle_deg'} = $1;
	    $temp_manvr{'duration_sec'} = $2;
	    $temp_manvr{'slew_err_arcsec'} = $3;
	}
	push @new_man, \%temp_manvr;
    }

    return @new_man;

#    my %manvr;
##  MANVR: Angle=  91.35 deg  Duration= 1878 sec  Slew err= 62.7 arcsec
#    if ($$data =~ /\s+MANVR:\sAngle=\s+(\S+)\sdeg\s+Duration=\s+(\S+)\ssec\s+Slew\serr=\s+(\S+)\sarcsec\s*\n/){
#	%manvr = (
#		  'angle_deg' => $1,
#		  'duration_sec' => $2,
#		  'slew_err_arcsec' => $3
#		  );
#    }
#    if ($$data =~ /MP_TARGQUAT\sat\s(\S+)\s\(VCDU\scount\s=\s(\d+)\)\n/){
#	$manvr{'MP_TARGQUAT'} = $1;
#    }
#
#    if ($$data =~ /(Q1,Q2,Q3,Q4):\s+(.+)\n/){
#	my @tmp = split ",", $1;
#	my @tmp1 = split " ", $2;
#	my %quat = (
#		    $tmp[0] => $tmp1[0],
#		    $tmp[1] => $tmp1[1],
#		    $tmp[2] => $tmp1[2],
#		    $tmp[3] => $tmp1[3]
#		    );
#	$manvr{Q1}=$quat{Q1};
#	$manvr{Q2}=$quat{Q2};
#	$manvr{Q3}=$quat{Q3};
#	$manvr{Q4}=$quat{Q4};
#    }
#
#
#    return %manvr;
}


##***************************************************************************
sub print {
##***************************************************************************
    my ($data, $handle) = (@_, *STDOUT{IO});
    print $handle $$data;
}


package StarcheckRecord;

use strict;
use Carp;

#@EXPORT = qw(new_record);

1;

##***************************************************************************
sub new_record{
##***************************************************************************
    my $classname = shift;
    my $obs_data = shift;

    my $self = {};
    bless ($self);

    $self->{obsid} = shift;

    %{$self->{coords}} = $obs_data->get_coords();
#    %{$self->{quat}} = $obs_data->get_quat();
    @{$self->{warnings}} = $obs_data->get_all_warnings();
    @{$self->{stars}} = $obs_data->get_stars();
    %{$self->{dither}} = $obs_data->get_dither_info();
    %{$self->{target}} = $obs_data->get_target();
    %{$self->{times}} = $obs_data->get_times();
    @{$self->{manvr}} = $obs_data->get_manvr();

    return $self;
    
}

package LoadRecord;

use strict;
use Carp;

1;

##***************************************************************************
sub new_record{
##***************************************************************************
    my $classname = shift;
    my $starcheck_data = shift;
    my $mp_path = shift;
    my $last_ap_date = shift;

    my $self = {};
    bless ($self);

    $self->{mp_path} = $mp_path;
    $self->{last_ap_date} = $last_ap_date;
#    @{$self->{lines}} = $starcheck_data->get_header_lines();
    %{$self->{lines}}= $starcheck_data->get_header_lines();

    return $self;

}
