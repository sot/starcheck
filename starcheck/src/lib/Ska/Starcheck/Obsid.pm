package Ska::Starcheck::Obsid;

##.################################################################################
#
# Encapsulate all relevant information for an Obsid:
#  @commands:  List of spacecraft commands associated with obsid.
#         Each $commands[] is actually a hash reference pointing
#         to command parameters.  The commands are taken from
#         the backstop report
#  obsid: Obsid
#  ra, dec, roll: Attitude for obsid
#  target_cmd: Shortcut to 'MP_TARGQUAT' $command[]
#  @fid, @acq, @gui: Lists of fid, acq, guide star indices
#
# part of the starcheck cvs project
#
##################################################################################

# Library dependencies

use strict;
use warnings;

use Inline Python => q{
import numpy as np
from chandra_aca.star_probs import guide_count
import Quaternion
from Ska.quatutil import radec2yagzag
import agasc

def _guide_count(mags, t_ccd):
    return float(guide_count(np.array(mags), t_ccd))


def _get_agasc_stars(ra, dec, roll, radius, date, agasc_file):
    """
    Fetch the cone of agasc stars.  Update the table with the yag and zag of each star.
    Return as a dictionary with the agasc ids as keys and all of the values as
    simple Python types (int, float)
    """
    stars = agasc.get_agasc_cone(float(ra), float(dec), float(radius), date.decode('ascii'),
                                 agasc_file.decode('ascii'))
    q_aca = Quaternion.Quat([float(ra), float(dec), float(roll)])
    yags, zags = radec2yagzag(stars['RA_PMCORR'], stars['DEC_PMCORR'], q_aca)
    yags *= 3600
    zags *= 3600
    stars['yang'] = yags
    stars['zang'] = zags

    # Get a dictionary of the stars with the columns that are used
    # This needs to be de-numpy-ified to pass back into Perl
    stars_dict = {}
    for star in stars:
        stars_dict[str(star['AGASC_ID'])] = {
            'id': int(star['AGASC_ID']),
            'class': int(star['CLASS']),
            'ra': float(star['RA_PMCORR']),
            'dec': float(star['DEC_PMCORR']),
            'mag_aca': float(star['MAG_ACA']),
            'bv': float(star['COLOR1']),
            'color1': float(star['COLOR1']),
            'mag_aca_err': float(star['MAG_ACA_ERR']),
            'poserr': float(star['POS_ERR']),
            'yag': float(star['yang']),
            'zag': float(star['zang']),
            'aspq': int(star['ASPQ1']),
            'var': int(star['VAR']),
            'aspq1': int(star['ASPQ1'])}

    return stars_dict

};


use List::Util qw( max );
use Quat;
use Ska::ACACoordConvert;
use File::Basename;
use POSIX qw(floor);
use English;
use IO::All;
use Ska::Convert qw(date2time time2date);

use Ska::Starcheck::FigureOfMerit qw( make_figure_of_merit set_dynamic_mag_limits );
use RDB;

use SQL::Abstract;
use Ska::DatabaseUtil qw( sql_fetchall_array_of_hashref );
use Carp;

# Constants

my $VERSION = '$Id$';  # '
my $ER_MIN_OBSID = 38000;
my $ACA_MANERR_PAD = 20;		# Maneuver error pad for ACA effects (arcsec)
my $r2a = 3600. * 180. / 3.14159265;
my $faint_plot_mag = 11.0;
my $alarm = ">> WARNING:";
my $info  = ">> INFO   :";
my %Default_SIM_Z = ('ACIS-I' => 92905,
		     'ACIS-S' => 75620,
		     'HRC-I'  => -50505,
		     'HRC-S'  => -99612);

my $font_stop = qq{</font>};
my ($red_font_start, $blue_font_start, $orange_font_start, $yellow_font_start);

my $ID_DIST_LIMIT = 1.5;		# 1.5 arcsec box for ID'ing a star

my $agasc_start_date = '2000:001:00:00:00.000';

# Actual science global structures.
my @bad_pixels;
my %odb;
my %bad_acqs;
my %bad_gui;
my %bad_id;
my %config;
my $db_handle;


1;

##################################################################################
sub new {
##################################################################################
    my $classname = shift;
    my $self = {};
    bless ($self);

    $self->{obsid} = shift;
    $self->{date}  = shift;
    $self->{dot_obsid} = $self->{obsid};
    @{$self->{warn}} = ();
    @{$self->{orange_warn}} = ();
    @{$self->{yellow_warn}} = ();
    @{$self->{fyi}} = ();
    $self->{n_guide_summ} = 0;
    @{$self->{commands}} = ();
    %{$self->{agasc_hash}} = ();
#    @{$self->{agasc_stars}} = ();
    $self->{ccd_temp} = undef;
    $self->{config} = \%config;
    return $self;
}
    
##################################################################################
sub set_db_handle {
##################################################################################
    my $handle = shift;
    $db_handle = $handle;
}


##################################################################################
sub setcolors {
##################################################################################
    my $colorref = shift;
    $red_font_start = $colorref->{red};
    $blue_font_start = $colorref->{blue};
    $yellow_font_start = $colorref->{yellow};
    $orange_font_start = $colorref->{orange};
}



##################################################################################
sub add_command {
##################################################################################
    my $self = shift;
    push @{$self->{commands}}, $_[0];
}


##################################################################################
sub set_config {
# Import characteristics from characteristics file
##################################################################################
    my $config_ref = shift;
    %config = %{$config_ref};
}


##################################################################################
sub set_odb {
# Import %odb variable into starcheck_obsid package
##################################################################################
    %odb= @_;
    $odb{"ODB_TSC_STEPS"}[0] =~ s/D/E/;
}

##################################################################################
sub set_ACA_bad_pixels {
##################################################################################
    my $pixel_file = shift;
    my @tmp = io($pixel_file)->slurp;
    my @lines = grep { /^\s+(\d|-)/ } @tmp;
    splice(@lines, 0, 2); # the first two lines are quadrant boundaries
    foreach (@lines) {
	my @line = split /;|,/, $_;
	#cut out the quadrant boundaries
	foreach my $i ($line[0]..$line[1]) {
	    foreach my $j ($line[2]..$line[3]) {
		my $pixel = {};
		my ($yag,$zag) = Ska::ACACoordConvert::toAngle($i,$j);
		$pixel->{yag} = $yag;
		$pixel->{zag} = $zag;
		push @bad_pixels, $pixel;
	    }
	}
    }

    print STDERR "Read ", ($#bad_pixels+1), " ACA bad pixels from $pixel_file\n";
}

##################################################################################
sub set_bad_acqs {
##################################################################################

    my $rdb_file = shift;
    if ( -r $rdb_file ){
	my $rdb = new RDB $rdb_file or warn "Problem Loading $rdb_file\n";
	
	my %data;
	while($rdb && $rdb->read( \%data )) { 
	    $bad_acqs{ $data{'agasc_id'} }{'n_noids'} = $data{'n_noids'};
	    $bad_acqs{ $data{'agasc_id'} }{'n_obs'} = $data{'n_obs'};
	}
	
	undef $rdb;
	return 1;
    }
    else{
	return 0;
    }

}


##################################################################################
sub set_bad_gui {
##################################################################################

    my $rdb_file = shift;
    if ( -r $rdb_file ){
	my $rdb = new RDB $rdb_file or warn "Problem Loading $rdb_file\n";
	
	my %data;
	while($rdb && $rdb->read( \%data )) { 
	    $bad_gui{ $data{'agasc_id'} }{'n_nbad'} = $data{'n_nbad'};
	    $bad_gui{ $data{'agasc_id'} }{'n_obs'} = $data{'n_obs'};
	}
	
	undef $rdb;
	return 1;
    }
    else{
	return 0;
    }

}


##################################################################################
sub set_bad_agasc {
# Read bad AGASC ID file
# one object per line: numeric id followed by commentary.
##################################################################################

    my $bad_file = shift;
    my $BS = io($bad_file);
    while (my $line = $BS->getline()) {
	$bad_id{$1} = 1 if ($line =~ (/^ \s* (\d+)/x));
    }

    print STDERR "Read ",(scalar keys %bad_id) ," bad AGASC IDs from $bad_file\n";
    return 1;
}


##################################################################################
sub set_obsid {
# Set self->{obsid} to the commanded (numeric) obsid value.  
# Use the following (in order of preference):
# - Backstop command (this relies on the DOT to associate cmd with star catalog)
# - Guide summary which provides ofls_id and obsid for each star catalog
# - OFLS ID from the DOT (as a fail-thru to still get some output)
##################################################################################
    my $self = shift;
    my $gs = shift;  # Guide summary
    my $oflsid = $self->{dot_obsid};
    my $gs_obsid;
    my $bs_obsid;
    my $mp_obsid_cmd = find_command($self, "MP_OBSID");
    $gs_obsid = $gs->{$oflsid}{guide_summ_obsid} if defined $gs->{$oflsid};
    $bs_obsid = $mp_obsid_cmd->{ID} if $mp_obsid_cmd;
    $self->{obsid} = $bs_obsid || $gs_obsid || $oflsid;
    if (defined $bs_obsid and defined $gs_obsid and $bs_obsid != $gs_obsid) {
        push @{$self->{warn}}, sprintf("$alarm Obsid mismatch: guide summary %d != backstop %d\n",
                                      $gs_obsid, $bs_obsid);
    }
}


##################################################################################
sub print_cmd_params {
##################################################################################
    my $self = shift;
    foreach my $cmd (@{$self->{commands}}) {
	print "  CMD = $cmd->{cmd}\n";
	foreach my $param (keys %{$cmd}) {
	    print  "   $param = $cmd->{$param}\n";
	}
    }
}

##################################################################################
sub set_files {
##################################################################################
    my $self = shift;
    ($self->{STARCHECK}, $self->{backstop}, $self->{guide_summ}, $self->{or_file},
     $self->{mm_file}, $self->{dot_file}, $self->{tlr_file}) = @_;
}

##################################################################################
sub set_target {
#
# Set the ra, dec, roll attributes based on target
# quaternion parameters in the target_md
#
##################################################################################
    my $self = shift;
    
    my $manvr = find_command($self, "MP_TARGQUAT", -1); # Find LAST TARGQUAT cmd
    ($self->{ra}, $self->{dec}, $self->{roll}) = 
	$manvr ? quat2radecroll($manvr->{Q1}, $manvr->{Q2}, $manvr->{Q3}, $manvr->{Q4})
	    : (undef, undef, undef);	   

    $self->{ra} = defined $self->{ra} ? sprintf("%.6f", $self->{ra}) : undef;
    $self->{dec} = defined $self->{dec} ? sprintf("%.6f", $self->{dec}) : undef;
    $self->{roll} = defined $self->{roll} ? sprintf("%.6f", $self->{roll}) : undef;

}

##################################################################################
sub radecroll {
##################################################################################
    my $self = shift;
    if (@_) {
	my $target = shift;
	($self->{ra}, $self->{dec}, $self->{roll}) =
	    quat2radecroll($target->{Q1}, $target->{Q2}, $target->{Q3}, $target->{Q4});
    }
    return ($self->{ra}, $self->{dec}, $self->{roll});
}

	    
##################################################################################
sub find_command {
##################################################################################
    my $self = shift;
    my $command = shift;
    my $number = shift || 1;
    my @commands = ($number > 0) ? @{$self->{commands}} : reverse @{$self->{commands}};
    $number = abs($number);

    foreach (@commands) {
	$number-- if ($_->{cmd} eq $command);
	return ($_) if ($number == 0);
    }
    return undef;
}

##################################################################################
sub set_maneuver {
#
# Find the right obsid for each maneuver.  Note that obsids in mm_file don't
# always match those in DOT, etc
#
##################################################################################
    my $self = shift;
    my %mm = @_;
    my $n = 1;
    my $c;
    my $found;


    while ($c = find_command($self, "MP_TARGQUAT", $n++)) {
	$found = 0;
	foreach my $m (values %mm) {
	    my $manvr_obsid = $m->{manvr_dest};
	    # where manvr_dest is either the final_obsid of a maneuver or the eventual destination obsid
	    # of a segmented maneuver 
	    if ( ($manvr_obsid eq $self->{dot_obsid})
		 && abs($m->{q1} - $c->{Q1}) < 1e-7
		 && abs($m->{q2} - $c->{Q2}) < 1e-7
		 && abs($m->{q3} - $c->{Q3}) < 1e-7) {
		$found = 1;
		foreach (keys %{$m}) {
		    $c->{$_} = $m->{$_};
		}
		# Set the default maneuver error (based on WS Davis data) and cap at 85 arcsec
		$c->{man_err} = (exists $c->{angle}) ? 35 + $c->{angle}/2. : 85;
		$c->{man_err} = 85 if ($c->{man_err} > 85);
		# Now check for consistency between quaternion from MANUEVER summary
		# file and the quat from backstop (MP_TARGQUAT cmd)

		# Get quat from MP_TARGQUAT (backstop) command.  
		# Compute 4th component (as only first 3 are uplinked) and renormalize.
		# Intent is to match OBC Target Reference subfunction
		my $q4_obc = sqrt(abs(1.0 - $c->{Q1}**2 - $c->{Q2}**2 - $c->{Q3}**2));
		my $norm = sqrt($c->{Q1}**2 + $c->{Q2}**2 + $c->{Q3}**2 + $q4_obc**2);
		if (abs(1.0 - $norm) > 1e-6){
		   push @{$self->{warn}}, sprintf("$alarm Uplink quaternion norm value $norm is too far from 1.0\n");
		}
		my @c_quat_norm = ($c->{Q1} / $norm,
	                       $c->{Q2} / $norm,
                           $c->{Q3} / $norm,
                           $q4_obc / $norm);

		# Get quat from MANEUVER summary file.  This is correct to high precision
		my $q_man = Quat->new($m->{ra}, $m->{dec}, $m->{roll});
		my $q_obc = Quat->new(@c_quat_norm);
		my @q_man = @{$q_man->{q}};
		my $q_diff = $q_man->divide($q_obc);
		    
		if (abs($q_diff->{ra0}*3600) > 1.0 || abs($q_diff->{dec}*3600) > 1.0 || abs($q_diff->{roll0}*3600) > 10.0) {
		    push @{$self->{warn}}, sprintf("$alarm Target uplink precision problem for MP_TARGQUAT at $c->{date}\n" 
						   . "   Error is yaw, pitch, roll (arcsec) = %.2f  %.2f  %.2f\n"
						   . "   Use Q1,Q2,Q3,Q4 = %.12f %.12f %.12f %.12f\n",
						   $q_diff->{ra0}*3600, $q_diff->{dec}*3600, $q_diff->{roll0}*3600,
						   $q_man[0], $q_man[1], $q_man[2], $q_man[3]);
		}
	    }
	
	    
	}
	push @{$self->{yellow_warn}}, sprintf("$alarm Did not find match in MAN summary for MP_TARGQUAT at $c->{date}\n")
	    unless ($found);
	
    }
}

##################################################################################
sub set_manerr {
#
# Set the maneuver error for each MP_TARGQUAT command within the obsid
# using the more accurate values from Bill Davis' code
#
##################################################################################
    my $self = shift;
    my @manerr = @_;
    my $n = 1;
    my $c;
    while ($c = find_command($self, "MP_TARGQUAT", $n)) {
	
	foreach my $me (@manerr) {
	    # There should be a one-to-one mapping between maneuver segments in the maneuver
	    # error file and those in the obsid records.  First, find what *should* be the
	    # match.  Then check quaternions to make sure
	    
	    if ($self->{obsid} eq $me->{obsid} && $n == $me->{Seg}) {
		if (   abs($me->{finalQ1} - $c->{Q1}) < 1e-7
		       && abs($me->{finalQ2} - $c->{Q2}) < 1e-7
		       && abs($me->{finalQ3} - $c->{Q3}) < 1e-7)
		{
		    $c->{man_err} = $me->{MaxErrYZ} + $ACA_MANERR_PAD;
		    $c->{man_err_data} = $me; # Save the whole record just in case
		} else {
		    push @{$self->{yellow_warn}}, sprintf("$alarm Mismatch in target quaternion ($c->{date}) and maneuver error file\n");
		}
	    }
	}
	$n++;
    }
}

##################################################################################
sub set_ps_times{
# Get the observation start and stop times from the processing summary
# Just planning to use the stop time on the last observation to check dither
# (that observation has no maneuver after it)
##################################################################################
    my $self = shift;
    my @ps = @_;
    my $obsid = $self->{obsid};
    my $or_er_start;
    my $or_er_stop;

    for my $ps_line (@ps){
	my @tmp = split ' ', $ps_line;
	next unless scalar(@tmp) >= 4;
	if ($tmp[1] eq 'OBS') {
	    my $length = length($obsid);
	    if (substr($tmp[0], 5-$length, $length) eq $obsid){
		$or_er_start = $tmp[2];
		$or_er_stop = $tmp[3];
		last;
	    }
	}
	if (($ps_line =~ /OBSID\s=\s(\d\d\d\d\d)/) && (scalar(@tmp) >= 8 )) {
	    if ( $obsid eq $1 ){
		$or_er_start = $tmp[2];
		$or_er_stop = $tmp[3];
	    }
	}
    }
    if (not defined $or_er_start or not defined $or_er_stop){
        push @{$self->{warn}}, "$alarm Could not find obsid $obsid in processing summary\n";
        $self->{or_er_start} = undef;
        $self->{or_er_stop} = undef;
    }
    else{
        $self->{or_er_start} = date2time($or_er_start);
        $self->{or_er_stop} = date2time($or_er_stop);
    }


}

#############################################################################################
sub set_npm_times{
# This needs to be run after the maneuvers for the *next* obsid have
# been set, so it can't run in the setup loop in starcheck.pl that
# calls set_maneuver().
#############################################################################################
    my $self = shift;

    # NPM range that will be checked for momentum dumps
    # duplicates check_dither range...
    my ($obs_tstart, $obs_tstop);
    
    # as with dither, check for end of associated maneuver to this attitude
    # and finding none, set start time as obsid start
    my $manvr = find_command($self, "MP_TARGQUAT", -1);
    if ((defined $manvr) and (defined $manvr->{tstop})){
        $obs_tstart = $manvr->{tstop};
    }
    else{
        $obs_tstart = date2time($self->{date});
    }
    
    # set the observation stop as the beginning of the next maneuever
    # or, if last obsid in load, use the processing summary or/er observation
    # stop time
    if (defined $self->{next}){
        my $next_manvr = find_command($self->{next}, "MP_TARGQUAT", -1);
        if ((defined $next_manvr) & (defined $next_manvr->{tstart})){
            $obs_tstop  = $next_manvr->{tstart};
        }
        else{
            # if the next obsid doesn't have a maneuver (ACIS undercover or whatever)
            # just use next obsid start time
            my $next_cmd_obsid = find_command($self->{next}, "MP_OBSID", -1);
            if ( (defined $next_cmd_obsid) and ( $self->{obsid} != $next_cmd_obsid->{ID}) ){
		push @{$self->{fyi}}, "$info Next obsid has no manvr; using next obs start date for checks (dither, momentum)\n";
                $obs_tstop = $next_cmd_obsid->{time};
                $self->{no_following_manvr} = 1;
            }
        }
    }
    else{
        $obs_tstop = $self->{or_er_stop};
    }

    if (not defined $obs_tstart or not defined $obs_tstop){
        push @{$self->{warn}}, "$alarm Could not determine obsid start and stop times for checks (dither, momentum)\n";
    }
    else{
        $self->{obs_tstart} = $obs_tstart;
        $self->{obs_tstop} = $obs_tstop;

    }
}



##################################################################################
sub set_fids {
#
# Find the commanded fids (if any) for this observation.
# always match those in DOT, etc
#
##################################################################################
    my $self = shift;
    my $fidsel = shift;
    my $tstart;
    my $manvr;
    $self->{fidsel} = [];  # Init to know that fids have been set and should be checked

    # Return unless there is a maneuver command and associated tstop value (from manv summ)

    return unless ($manvr = find_command($self, "MP_TARGQUAT", -1));

    return unless ($tstart = $manvr->{tstop});	# "Start" of observation = end of manuever
    
    # Loop through fidsel commands for each fid light and find any intervals
    # where fid is on at time $tstart

    for my $fid (1 .. 14) {
	foreach my $fid_interval (@{$fidsel->[$fid]}) {
	    if ($fid_interval->{tstart} <= $tstart &&
		(! exists $fid_interval->{tstop} || $tstart <= $fid_interval->{tstop}) ) {
		push @{$self->{fidsel}}, $fid;
		last;
	    }
	}
    }

}

##################################################################################
sub set_star_catalog {
##################################################################################
    my $self = shift;
    my @sizes = qw (4x4 6x6 8x8);
    my @monhalfw = qw (10 15 20);
    my @types = qw (ACQ GUI BOT FID MON);
    my $r2a = 180. * 3600. / 3.14159265;
    my $c;

    return unless ($c = find_command($self, "MP_STARCAT"));
	
    $self->{date} = $c->{date};

    @{$self->{fid}} = ();
    @{$self->{gui}} = ();
    @{$self->{acq}} = ();
    @{$self->{mon}} = ();

    foreach my $i (1..16) {
	$c->{"SIZE$i"} = $sizes[$c->{"IMGSZ$i"}];
	$c->{"MAG$i"} = ($c->{"MINMAG$i"} + $c->{"MAXMAG$i"})/2;
	$c->{"TYPE$i"} = ($c->{"TYPE$i"} or $c->{"MINMAG$i"} != 0 or $c->{"MAXMAG$i"} != 0)? 
	    $types[$c->{"TYPE$i"}] : 'NUL';
	push @{$self->{mon}},$i if ($c->{"TYPE$i"} eq 'MON');
	push @{$self->{fid}},$i if ($c->{"TYPE$i"} eq 'FID');
	push @{$self->{acq}},$i if ($c->{"TYPE$i"} eq 'ACQ' or $c->{"TYPE$i"} eq 'BOT');
	push @{$self->{gui}},$i if ($c->{"TYPE$i"} eq 'GUI' or $c->{"TYPE$i"} eq 'BOT');
	$c->{"YANG$i"} *= $r2a;
	$c->{"ZANG$i"} *= $r2a;
	$c->{"HALFW$i"} = ($c->{"TYPE$i"} ne 'NUL')? 
	    ( 40 - 35*$c->{"RESTRK$i"} ) * $c->{"DIMDTS$i"} + 20 : 0;
	$c->{"HALFW$i"} = $monhalfw[$c->{"IMGSZ$i"}] if ($c->{"TYPE$i"} eq 'MON');
	$c->{"YMAX$i"} = $c->{"YANG$i"} + $c->{"HALFW$i"};
	$c->{"YMIN$i"} = $c->{"YANG$i"} - $c->{"HALFW$i"};
	$c->{"ZMAX$i"} = $c->{"ZANG$i"} + $c->{"HALFW$i"};
	$c->{"ZMIN$i"} = $c->{"ZANG$i"} - $c->{"HALFW$i"};
        $c->{"P_ACQ$i"} = '---';

	# Fudge in values for guide star summary, in case it isn't there
	$c->{"GS_ID$i"} = '---';	
	$c->{"GS_MAG$i"} = '---';
	$c->{"GS_YANG$i"} = 0;
	$c->{"GS_ZANG$i"} = 0;
	$c->{"GS_PASS$i"} = '';
    }
}

#############################################################################################
sub check_dither {
#############################################################################################
    my $self = shift;

    my $dthr = shift;		  # Ref to array of hashes containing dither states
    my %dthr_cmd = (ON => 'ENAB',   # Translation from OR terminology to dither state term.
		    OFF => 'DISA');

    my $large_dith_thresh = 30;   # Amplitude larger than this requires special checking/handling

    my $obs_beg_pad = 8*60;       # Check dither status at obs start + 8 minutes to allow 
                                  # for disabled dither because of mon star commanding
    my $obs_end_pad = 3*60;
    my $manvr;

    if ( $self->{obsid} =~ /^\d*$/){
	return if ($self->{obsid} >= $ER_MIN_OBSID); # For eng obs, don't have OR to specify dither
    }
    # If there's no starcat on purpose, return
    if (defined $self->{ok_no_starcat} and $self->{ok_no_starcat}){
        return;
    }
    unless ($manvr = find_command($self, "MP_TARGQUAT", -1)
            and defined $manvr->{tstart}) {
	push @{$self->{warn}}, "$alarm Dither status not checked\n";
	return;
    }

    unless (defined $dthr){
      push @{$self->{warn}}, "$alarm Dither states unavailable. Dither not checked\n";
      return;
    }

    # set the observation start as the end of the maneuver
    my $obs_tstart = $self->{obs_tstart};
    my $obs_tstop = $self->{obs_tstop};

    # Determine current dither status by finding the last dither commanding before
    # the start of observation (+ 8 minutes)
    my $dither;
    foreach my $dither_state (reverse @{$dthr}) {
	if ($obs_tstart + $obs_beg_pad >= $dither_state->{time}) {
            $dither = $dither_state;
            last;
        }
    }

    my $bs_val = $dither->{state};
    # Get the OR value of dither and compare if available
    my $or_val;
    if (defined $self->{DITHER_ON}){
        $or_val = $dthr_cmd{$self->{DITHER_ON}};
        # ACA-002
        push @{$self->{warn}}, "$alarm Dither mismatch - OR: $or_val != Backstop: $bs_val\n"
            if ($or_val ne $bs_val);
    }
    else{
        push @{$self->{warn}},
            "$alarm Unable to determine dither from OR list\n";
    }

    # If dither is anabled according to the OR, check that parameters match OR vs Backstop
    if ((defined $or_val) and ($or_val eq 'ENAB')){
        my $y_amp = $self->{DITHER_Y_AMP} * 3600;
        my $z_amp = $self->{DITHER_Z_AMP} * 3600;
        if (defined $dither->{ampl_y}
                and defined $dither->{ampl_p}
                    and (abs($y_amp - $dither->{ampl_y}) > 0.1
                             or abs($z_amp - $dither->{ampl_p}) > 0.1)){
            my $warn = sprintf("$alarm Dither amp. mismatch - OR: (Y %.1f, Z %.1f) "
                                   . "!= Backstop: (Y %.1f, Z %.1f)\n",
                               $y_amp, $z_amp,
                               $dither->{ampl_y}, $dither->{ampl_p});
            push @{$self->{warn}}, $warn;
        }
    }
    # Check for standard and large dither based solely on backstop/history values
    if (($bs_val eq 'ENAB') and (defined $dither->{ampl_y} and defined $dither->{ampl_p})){
        $self->{cmd_dither_y_amp} = $dither->{ampl_y};
        $self->{cmd_dither_z_amp} = $dither->{ampl_p};
        if (not standard_dither($dither)){
            push @{$self->{yellow_warn}}, "$alarm Non-standard dither\n";
            if ($dither->{ampl_y} > $large_dith_thresh or $dither->{ampl_p} > $large_dith_thresh){
                $self->large_dither_checks($dither, $dthr);
                # If this is a large dither, set a larger pad at the end, as we expect
                # standard dither parameters to be commanded at 5 minutes before end,
                # which is greater than the 3 minutes used in the "no dither changes
                # during observation check below
                $obs_end_pad = 5.5 * 60;
            }
        }
    }

    # Loop again to check for dither changes during the observation
    # ACA-003
    if (not defined $obs_tstop ){
        push @{$self->{warn}},
            "$alarm Unable to determine obs tstop; could not check for dither changes during obs\n";
    }
    else{
        foreach my $dither (reverse @{$dthr}) {
            if ($dither->{time} > ($obs_tstart + $obs_beg_pad)
                    && $dither->{time} <= $obs_tstop - $obs_end_pad) {
                push @{$self->{warn}}, "$alarm Dither commanding at $dither->{time}.  During observation.\n";
            }
            if ($dither->{time} < $obs_tstart){
                last;
            }
        }
    }
}



#############################################################################################
sub standard_dither{
#############################################################################################
    my $dthr = shift;
    my %standard_y_dither = (20 => 1087.0,
                             8 => 1000.0);
    my %standard_z_dither = (20 => 768.6,
                             8 => 707.1);

    # If the rounded amplitude is not in the standard set, return 0
    if (not (grep $_ eq int($dthr->{ampl_p} + .5), (keys %standard_z_dither))){
        return 0;
    }
    if (not (grep $_ eq int($dthr->{ampl_y} + .5), (keys %standard_y_dither))){
        return 0;
    }
    # If the period is not standard for the standard amplitudes return 0
    if (abs($dthr->{period_p} - $standard_z_dither{int($dthr->{ampl_p} + .5)}) > 10){
        return 0;
    }
    if (abs($dthr->{period_y} - $standard_y_dither{int($dthr->{ampl_y} + .5)}) > 10){
        return 0;
    }

    # If those tests passed, the dither is standard
    return 1;
}


#############################################################################################
sub large_dither_checks {
#############################################################################################
    # Check the subset of monitor-window-style commanding that should be used on
    # observations with large dither.

    my $self = shift;
    my $dither_state = shift;
    my $all_dither = shift;
    my $time_tol = 11;         # Commands must be within $time_tol of expectation

    # Save the number of warnings when starting this method
    my $n_warn = scalar(@{$self->{warn}});

    my $obs_tstart = $self->{obs_tstart};
    my $obs_tstop = $self->{obs_tstop};

    # Now check in backstop commands for :
    #  Dither is disabled (AODSDITH) 1 min prior to the end of the maneuver (EOM)
    #    to the target attitude.
    #  Dither is enabled (AOENDITH) 5 min after EOM
    #  Dither parameters are commanded 5 min before end of observation
    # ACA-040
    # obs_tstart is defined as the tstop of the maneuver to this observation in set_npm_times
    # obs_tstop is defined as the time of the maneuver away or the end of the schedule

    # Is the large dither command enabled 5 minutes after EOM?
    if (abs($dither_state->{time} - $obs_tstart - 300) > $time_tol){
        push @{$self->{warn}},
            sprintf("$alarm Large Dither not enabled 5 min after EOM (%s)\n",
                    time2date($obs_tstart));
    }
    # What's the dither state at EOM?
    my $obs_start_dither;
    foreach my $dither (reverse @{$all_dither}) {
	if ($obs_tstart >= $dither->{time}) {
            $obs_start_dither = $dither;
            last;
        }
    }
    # Is dither disabled at EOM and one minute before?
    if ((abs($obs_tstart - $obs_start_dither->{time} - 60) > $time_tol)
            or ($obs_start_dither->{state} ne 'DISA')){
        push @{$self->{warn}},
            sprintf("$alarm Dither should be disabled 1 min before obs start for Large Dither\n");
    }


    # Find the dither state at the end of the observation
    my $obs_stop_dither;
    foreach my $dither (reverse @{$all_dither}) {
	if ($obs_tstop >= $dither->{time}) {
            $obs_stop_dither = $dither;
            last;
        }
    }
    # Check that the dither state at the end of the observation started 5 minutes before
    # the end (within time_tol) .  obs_tstop appears not corrected by 10s so use 310 instead of 300
    if ((abs($obs_tstop - $obs_stop_dither->{time} - 310) > $time_tol)){
        push @{$self->{warn}},
            sprintf("$alarm Last dither state for Large Dither should start 5 minutes before obs end.\n");
    }
    # Check that the dither state at the end of the observation is standard
    if (not standard_dither($obs_stop_dither)){
        push @{$self->{warn}},
            sprintf("$alarm Dither parameters not set to standard values before obs end\n");
    }

    # If the number of warnings has not changed during this routine, it passed all checks
    if (scalar(@{$self->{warn}}) == $n_warn){
        push @{$self->{fyi}},
            sprintf("$info Observation passes 'big dither' checks\n");
    }
}





#############################################################################################
sub check_bright_perigee{
#############################################################################################
    my $self = shift;
    my $radmon = shift;
    my $min_mag = 9.0;
    my $min_n_stars = 3;

    # if this is an OR, just return
    return if (($self->{obsid} =~ /^\d+$/ && $self->{obsid} < $ER_MIN_OBSID));

    # if radmon is undefined, warn and return
    if (not defined $radmon){
      push @{$self->{warn}}, "$alarm Perigee bright stars not being checked, no rad zone info available\n";
	return;
    }

    # set the observation start as the end of the maneuver
    my $obs_tstart = $self->{obs_tstart};
    my $obs_tstop = $self->{obs_tstop};

    # if observation stop time is undefined, warn and return
    if (not defined $obs_tstop){
        push @{$self->{warn}}, "$alarm Perigee bright stars not being checked, no obs tstop available\n";
	return;
    }

    # is this obsid in perigee?  assume no to start
    my $in_perigee = 0;

    for my $rad (reverse @{$radmon}){
      next if ($rad->{time} > $obs_tstop);
      if ($rad->{state} eq 'DISA'){
        $in_perigee = 1;
        last;
      }
      last if ($rad->{time} < $obs_tstart);
    }

    # nothing to do if not in perigee
    return if (not $in_perigee);

    my $c = find_command($self, 'MP_STARCAT');
    return if (not defined $c);

    # check for at least N bright stars
    my @bright_stars = grep { (defined $c->{"TYPE$_"})
                              and ($c->{"TYPE$_"} =~ /BOT|GUI/)
                              and ($c->{"GS_MAG$_"} < $min_mag) } (0 .. 16);
    my $bright_count = scalar(@bright_stars);
    if ($bright_count < $min_n_stars){
        if ($self->{special_case_er} == 1){
            push @{$self->{fyi}}, "$info Only $bright_count star(s) brighter than $min_mag mag. "
                . "Acceptable for Special Case ER\n";
        }
        else{
            push @{$self->{warn}}, "$alarm $bright_count star(s) brighter than $min_mag mag. "
                . "Perigee requires at least $min_n_stars\n";
        }

    }
}


#############################################################################################
sub check_momentum_unload{
#############################################################################################
    my $self = shift;
    my $backstop = shift;
    my $obs_tstart = $self->{obs_tstart};
    my $obs_tstop = $self->{obs_tstop};
    
    if (not defined $obs_tstart or not defined $obs_tstop){
        push @{$self->{warn}}, "$alarm Momentum Unloads not checked.\n";
        return;
    }
    for my $entry (@{$backstop}){
        if ((defined $entry->{command}) and (defined $entry->{command}->{TLMSID})){
            if ($entry->{command}->{TLMSID} =~ /AOMUNLGR/){
                if (($entry->{time} >= $obs_tstart) and ($entry->{time} <= $obs_tstop )){
                    push @{$self->{fyi}}, "$info Momentum Unload (AOMUNLGR) in NPM at " . $entry->{date} . "\n";
                }
            }
        }
    }
}

#############################################################################################
sub check_for_special_case_er{
#############################################################################################
    my $self = shift;
    # if the previous obsid is an OR and the current one is an ER
    # and the obsid is < 10 minutes in duration (we've got a <10 min NPM criterion)
    # and there is a star catalog to check
    # and the last obsid had a star catalog
    # and the pointings are the same
    # it is a special case ER
    $self->{special_case_er} = 0;
    if ($self->{obsid} =~ /^\d+$/
        and $self->{obsid} >= $ER_MIN_OBSID
        and $self->find_command("MP_STARCAT")
        and $self->{prev}
        and $self->{prev}->{obsid} =~ /^\d+$/
        and $self->{prev}->{obsid} < $ER_MIN_OBSID
        and $self->{prev}->find_command("MP_STARCAT")
        and abs($self->{ra} - $self->{prev}->{ra}) < 0.001
        and abs($self->{dec} - $self->{prev}->{dec}) < 0.001
        and abs($self->{roll} - $self->{prev}->{roll}) < 0.001){
        if (($self->{obs_tstop} - $self->{obs_tstart}) < 10*60){
            $self->{special_case_er} = 1;
            push @{$self->{fyi}}, "$info Special Case ER\n";
        }
        else{
            push @{$self->{fyi}},
            sprintf("$info Same attitude as last obsid but too long (%.1f min) for Special Case ER\n", ($self->{obs_tstop} - $self->{obs_tstart})/60.);
        }
    }
}

#############################################################################################
sub check_sim_position {
#############################################################################################
    my $self = shift;
    my @sim_trans = @_;		# Remaining values are SIMTRANS backstop cmds
    my $manvr;
    
    return unless (exists $self->{SIM_OFFSET_Z});
    unless ($manvr = find_command($self, "MP_TARGQUAT", -1)) {
	push @{$self->{warn}}, "$alarm Missing MP_TARGQUAT cmd\n";
	return;
    }

    # Set the expected SIM Z position (steps)
    my $sim_z = $Default_SIM_Z{$self->{SI}} + $self->{SIM_OFFSET_Z};

    foreach my $st (reverse @sim_trans) {
	if (not defined $manvr->{tstop}){
	    push @{$self->{warn}}, "Maneuver times not defined; SIM checking failed!\n";
	}
	else{
	    if ($manvr->{tstop} >= $st->{time}) {
		my %par = Ska::Parse_CM_File::parse_params($st->{params});
		if (abs($par{POS} - $sim_z) > 4) {
#		print STDERR "Yikes, SIM mismatch!  \n";
#		print STDERR " self->{obsid} = $self->{obsid}\n";
#		print STDERR " sim_offset_z = $self->{SIM_OFFSET_Z}   SI = $self->{SI}\n";
#		print STDERR " st->{POS} = $par{POS}   sim_z = $sim_z   delta = ", $par{POS}-$sim_z,"\n";
                    # ACA-001
		    push @{$self->{warn}}, "$alarm SIM position mismatch:  OR=$sim_z  BACKSTOP=$par{POS}\n";
		}
		last;
	    }
	}
    }	
}
    
#############################################################################################
sub set_ok_no_starcat{
#############################################################################################
    my $self = shift;
    my $oflsid = $self->{dot_obsid};
    # Is this an obsid that is allowed to not have a star catalog, 
    # if so, what oflsid string does it match:
    my $ok_no_starcat;
    if (defined $config{no_starcat_oflsid}){
        my @no_starcats = @{$config{no_starcat_oflsid}};
        for my $ofls_string (@no_starcats){
            if ( $oflsid =~ /$ofls_string/){
                $ok_no_starcat = $ofls_string;
            }
        }
    }
    $self->{ok_no_starcat} = $ok_no_starcat;
}



#############################################################################################
sub check_star_catalog {
#############################################################################################
    my $self = shift;
    my $or = shift;
    my $vehicle = shift;
    my $c;
    
    
    ########################################################################
    # Constants used in star catalog checks
    my $y_ang_min    =-2410;	# CCD boundaries in arcsec
    my $y_ang_max    = 2473;
    my $z_ang_min    =-2504;
    my $z_ang_max    = 2450;

    # For boundary checks in pixel coordinates
    # see /proj/sot/ska/acaflt/quad_limits_sausage.* for more info
    my $ccd_row_min = -512.5;
    my $ccd_row_max =  511.5;
    my $ccd_col_min = -512.5;
    my $ccd_col_max =  511.5;

    my $pix_window_pad = 7; # half image size + point uncertainty + ? + 1 pixel of margin
    my $pix_row_pad = 8; # min pad at row limits (pixels) [ACA requirement]
    my $pix_col_pad = 1; # min pad at col limits (pixels) [because outer col is not full-sized]

    my $row_min = $ccd_row_min + ($pix_row_pad + $pix_window_pad);
    my $row_max = $ccd_row_max - ($pix_row_pad + $pix_window_pad);
    my $col_min = $ccd_col_min + ($pix_col_pad + $pix_window_pad);
    my $col_max = $ccd_col_max - ($pix_col_pad + $pix_window_pad);

    # Rough angle / pixel scale for dither
    my $ang_per_pix = 5;

    # If guessing if a BOT or GUI star in slot 7 with an 8x8 box is also a MON
    # we expect MON stars to be within 480 arc seconds of the center, Y or Z
    my $mon_expected_ymax = 480;
    my $mon_expected_zmax = 480;

    my $min_y_side = 2500; # Minimum rectangle size for all acquisition stars
    my $min_z_side = 2500;

    my $col_sep_dist = 50;	# Common column pixel separation
    my $col_sep_mag  = 4.5;	# Common column mag separation (from ODB_MIN_COL_MAG_G)

    my $mag_faint_slot_diff = 1.4; # used in slot test like:
                                   # $c->{"MAXMAG$i"} - $c->{"GS_MAG$i"} >= $mag_faint_slot_diff

    my $fid_faint = 7.2;
    my $fid_bright = 6.8;

    my $spoil_dist   = 140;	# Min separation of star from other star within $sep_mag mags
    my $spoil_mag    = 5.0;	# Don't flag if mag diff is more than this
   
    my $qb_dist      = 20;	# QB separation arcsec (3 pixels + 1 pixel of ambiguity)
   
    my $y0           = 33;	# CCD QB coordinates (arcsec)
    my $z0           = -27;
   
    my $is_science = ($self->{obsid} =~ /^\d+$/ && $self->{obsid} < $ER_MIN_OBSID);
    my $is_er      = ($self->{obsid} =~ /^\d+$/ && $self->{obsid} >= $ER_MIN_OBSID);
    my $min_guide    = $is_science ? 5 : 6; # Minimum number of each object type
    my $min_acq      = $is_science ? 4 : 5;
    my $min_fid      = 3;
    ########################################################################

    # Set smallest maximums and largest minimums for rectangle edges
    my $max_y = $y_ang_min;
    my $min_y = $y_ang_max;
    my $max_z = $z_ang_min;
    my $min_z = $z_ang_max;

    my $dither;			# Global dither for observation
    if (defined $self->{cmd_dither_y_amp} and defined $self->{cmd_dither_z_amp}) {
	$dither = max($self->{cmd_dither_y_amp}, $self->{cmd_dither_z_amp});
    } else {
	$dither = 20.0;
    }

    my @warn = ();
    my @orange_warn = ();
    my @yellow_warn = ();

    my $oflsid = $self->{dot_obsid};
    my $obsid = $self->{obsid};
    my $ok_no_starcat = $self->{ok_no_starcat};

   # Set slew error (arcsec) for this obsid, or 120 if not available 
    my $slew_err;
    my $targquat;
    if ($targquat = find_command($self, "MP_TARGQUAT", -1)){
	$slew_err = $targquat->{man_err};
    }
    else{
	# if no target quaternion, warn and continue
	if (defined $ok_no_starcat){
	  push @{$self->{fyi}}, "$info No target/maneuver for obsid $obsid ($oflsid). OK for '$ok_no_starcat' ER. \n";
	}
	else{
	  push @{$self->{warn}}, "$alarm No target/maneuver for obsid $obsid ($oflsid). \n";		    
	}
    }
    $slew_err = 120 if not defined $slew_err;

    # ACA-004
    # if no starcat, warn and quit this subroutine
    unless ($c = find_command($self, "MP_STARCAT")) {
	if (defined $ok_no_starcat){
	    push @{$self->{fyi}}, "$info No star catalog for obsid $obsid ($oflsid). OK for '$ok_no_starcat' ER. \n";
	    return;
	}
	push @{$self->{warn}}, "$alarm No star catalog for obsid $obsid ($oflsid). \n";		    
	return;
    }
    # Decrement minimum number of guide stars on ORs if a monitor window is commanded
    $min_guide -= @{$self->{mon}} if $is_science;

    print STDERR "Checking star catalog for obsid $self->{obsid}\n";
    
    # Global checks on star/fid numbers
    # ACA-005 ACA-006 ACA-007 ACA-008 ACA-044
    
    push @warn,"$alarm Too Few Fid Lights\n" if (@{$self->{fid}} < $min_fid && $is_science);
    push @warn,"$alarm Too Many Fid Lights\n" if ( (@{$self->{fid}} > 0 && $is_er) ||
						   (@{$self->{fid}} > $min_fid && $is_science) ) ;
    push @warn,"$alarm Too Few Acquisition Stars\n" if (@{$self->{acq}} < $min_acq);
    # Red warn if fewer than the minimum number of guide stars
    my $n_gui = @{$self->{gui}};
    push @warn,"$alarm Only $n_gui Guide Stars ($min_guide required)\n" if ($n_gui < $min_guide);
    push @warn,"$alarm Too Many GUIDE + FID\n" if (@{$self->{gui}} + @{$self->{fid}} + @{$self->{mon}} > 8);
    push @warn,"$alarm Too Many Acquisition Stars\n" if (@{$self->{acq}} > 8);
    push @warn,"$alarm Too many MON\n" if ((@{$self->{mon}} > 1 && $is_science) ||
                                               (@{$self->{mon}} > 2 && $is_er));
    
    # Match positions of fids in star catalog with expected, and verify a one to one 
    # correspondance between FIDSEL command and star catalog.  
    # Skip this for vehicle-only loads since fids will be turned off.
    check_fids($self, $c, \@warn) unless $vehicle;

    # store a list of the fid positions
    my @fid_positions = map {{'y' => $c->{"YANG$_"}, 'z' => $c->{"ZANG$_"}}} @{$self->{fid}};

    foreach my $i (1..16) {
	(my $sid  = $c->{"GS_ID$i"}) =~ s/[\s\*]//g;
	my $type = $c->{"TYPE$i"};
	my $yag  = $c->{"YANG$i"};
	my $zag  = $c->{"ZANG$i"};
	my $mag  = $c->{"GS_MAG$i"};
	my $maxmag = $c->{"MAXMAG$i"};
	my $halfw= $c->{"HALFW$i"};
	my $db_stats = $c->{"GS_USEDBEFORE${i}"};

	# Search error for ACQ is the slew error, for fid, guide or mon it is about 4 arcsec
	my $search_err = ( (defined $type) and ($type =~ /BOT|ACQ/)) ? $slew_err : 4.0;
	
	# Find position extrema for smallest rectangle check
	if ( $type =~ /BOT|GUI/ ) {
	    $max_y = ($max_y > $yag ) ? $max_y : $yag;
	    $min_y = ($min_y < $yag ) ? $min_y : $yag;
	    $max_z = ($max_z > $zag ) ? $max_z : $zag;
	    $min_z = ($min_z < $zag ) ? $min_z : $zag;
	}
	next if ($type eq 'NUL');
	my $slot_dither = ($type =~ /FID/ ? 5.0 : $dither); # Pseudo-dither, depending on star or fid
	my $pix_slot_dither = $slot_dither / $ang_per_pix;

       # Warn if star not identified ACA-042
	if ( $type =~ /BOT|GUI|ACQ/ and not defined $c->{"GS_IDENTIFIED$i"}) {
	    push @warn, sprintf("$alarm [%2d] Missing Star. No AGASC star near search center \n", $i);
	}

	# Warn if acquisition star has non-zero aspq1
	push @yellow_warn, sprintf "$alarm [%2d] Centroid Perturbation Warning.  %s: ASPQ1 = %2d\n", 
	$i, $sid, $c->{"GS_ASPQ$i"} 
	if ($type =~ /BOT|ACQ|GUI/ && defined $c->{"GS_ASPQ$i"} && $c->{"GS_ASPQ$i"} != 0);

	my $obs_min_cnt = 2;
	my $obs_bad_frac = 0.3;
	# Bad Acquisition Star
	if ($type =~ /BOT|ACQ|GUI/){
	my $n_obs = $bad_acqs{$sid}{n_obs};
	    my $n_noids = $bad_acqs{$sid}{n_noids};
	    if (defined $db_stats->{acq}){
	        $n_obs = $db_stats->{acq};
	        $n_noids = $db_stats->{acq_noid};
	    }
	    if ($n_noids && $n_obs > $obs_min_cnt && $n_noids/$n_obs > $obs_bad_frac){
	        push @yellow_warn, sprintf 
		"$alarm [%2d] Bad Acquisition Star. %s has %2d failed out of %2d attempts\n",
		$i, $sid, $n_noids, $n_obs;
	    }
	}
	 
	# Bad Guide Star
	if ($type =~ /BOT|GUI/){
	    my $n_obs = $bad_gui{$sid}{n_obs};
	    my $n_nbad = $bad_gui{$sid}{n_nbad};
	    if (defined $db_stats->{gui}){
	        $n_obs = $db_stats->{gui};
	        $n_nbad = $db_stats->{gui_bad};
	    }
	    if ($n_nbad && $n_obs > $obs_min_cnt && $n_nbad/$n_obs > $obs_bad_frac){
	        push @warn, sprintf
		"$alarm [%2d] Bad Guide Star. %s has bad data %2d of %2d attempts\n",
		$i, $sid, $n_nbad, $n_obs;
	    }
	}
	    
	# Bad AGASC ID ACA-031
	push @yellow_warn,sprintf "$alarm [%2d] Non-numeric AGASC ID.  %s\n",$i,$sid if ($sid ne '---' && $sid =~ /\D/);
	push @warn,sprintf "$alarm [%2d] Bad AGASC ID.  %s\n",$i,$sid if ($bad_id{$sid});
	
	# Set NOTES variable for marginal or bad star based on AGASC info
	$c->{"GS_NOTES$i"} = '';
	my $note = '';
	my $marginal_note = '';
	if (defined $c->{"GS_CLASS$i"}) {
	    $c->{"GS_NOTES$i"} .= 'b' if ($c->{"GS_CLASS$i"} != 0);
	    # ignore precision errors in color
	    my $color = sprintf('%.7f', $c->{"GS_BV$i"});
	    $c->{"GS_NOTES$i"} .= 'c' if ($color eq '0.7000000'); # ACA-033
            $c->{"GS_NOTES$i"} .= 'C' if ($color eq '1.5000000');
	    $c->{"GS_NOTES$i"} .= 'm' if ($c->{"GS_MAGERR$i"} > 99);
	    $c->{"GS_NOTES$i"} .= 'p' if ($c->{"GS_POSERR$i"} > 399);
            # If 0.7 color or bad mag err or bad pos err, format a warning for the star.
            # Color 1.5 stars do not get a text warning and bad class stars are handled
            # separately a few lines lower.
            if ($c->{"GS_NOTES$i"} =~ /[cmp]/){
                $note = sprintf("B-V = %.3f, Mag_Err = %.2f, Pos_Err = %.2f",
                                $c->{"GS_BV$i"}, ($c->{"GS_MAGERR$i"})/100, ($c->{"GS_POSERR$i"})/1000);
                $marginal_note = sprintf("$alarm [%2d] Marginal star. %s\n",$i,$note);
            }
            # Assign orange warnings to catalog stars with B-V = 0.7 .
            # Assign yellow warnings to catalog stars with other issues (example B-V = 1.5).
            if (($marginal_note) && ($type =~ /BOT|GUI|ACQ/)) {
                if ($color eq '0.7000000'){
                    push @orange_warn, $marginal_note;
                }
                else{
                    push @yellow_warn, $marginal_note;
                }
            }
            # Print bad star warning on catalog stars with bad class.
            if ($c->{"GS_CLASS$i"} != 0){
                if ($type =~ /BOT|GUI|ACQ/ ){
                    push @warn, sprintf("$alarm [%2d] Bad star.  Class = %s %s\n", $i,$c->{"GS_CLASS$i"},$note);
                }
                elsif ($type eq 'MON'){
                    push @{$self->{fyi}}, sprintf("$info [%2d] MON class= %s %s (do not convert to GUI)\n", $i,$c->{"GS_CLASS$i"},$note);
                }
            }
	}

	# Star/fid outside of CCD boundaries
        # ACA-019 ACA-020 ACA-021
	my ($pixel_row, $pixel_col);
	eval{
		($pixel_row, $pixel_col) = toPixels( $yag, $zag);
	    };
	
	# toPixels throws exception if angle off the CCD altogether
	# respond to that one and warn on all others
	if ($@) {
	    if ($@ =~ /.*Coordinate off of CCD.*/ ){
		push @warn, sprintf "$alarm [%2d] Angle Off CCD.\n",$i;
	    }
	    else {
		push @warn, sprintf "$alarm [%2d] Boundary Checks failed. toPixels() said: $@ \n",$i,$i;
	    }
	}
	else{
	    if (   $pixel_row > $row_max - $pix_slot_dither || $pixel_row < $row_min + $pix_slot_dither
		   || $pixel_col > $col_max - $pix_slot_dither || $pixel_col < $col_min + $pix_slot_dither) {
    		push @warn,sprintf "$alarm [%2d] Angle Too Large.\n",$i;
	    }
	}

	# Faint and bright limits ~ACA-009 ACA-010
	if ($mag ne '---') {
            if ($type eq 'GUI' or $type eq 'BOT'){
                my $guide_mag_warn = sprintf "$alarm [%2d] Magnitude. Guide star %6.3f\n", $i, $mag;
                if (($mag > 10.3) or ($mag < 6.0)){
                    push @warn, $guide_mag_warn;
                }
            }
            if ($type eq 'BOT' or $type eq 'ACQ'){
                my $acq_mag_warn = sprintf "$alarm [%2d] Magnitude. Acq star %6.3f\n", $i, $mag;
                if ($mag < 5.8){
                    push @warn, $acq_mag_warn;
                }
                elsif ($mag > $self->{mag_faint_red}){
                    push @orange_warn, $acq_mag_warn;
                }
                elsif ($mag > $self->{mag_faint_yellow}){
                    push @yellow_warn, $acq_mag_warn;
                }
            }
	}

	# FID magnitude limits ACA-011
	if ($type eq 'FID') {
	    if ($mag =~ /---/ or $mag < $fid_bright or $mag > $fid_faint) {
		push @warn, sprintf "$alarm [%2d] Magnitude.  %6.3f\n",$i, $mag =~ /---/ ? 0 : $mag;
	    } 
	}

        # Check for situation that occurred for obsid 14577 with a fid light
        # inside the search box (PR #50).
        if ($type =~ /BOT|ACQ/){
            for my $fpos (@fid_positions){
                if (abs($fpos->{y} - $yag) < $halfw and abs($fpos->{z} - $zag) < $halfw){
                    if ($type =~ /ACQ/){
                        push @yellow_warn, sprintf "$alarm [%2d] Fid light in search box\n", $i;
                    }
                    else{
                        push @warn, sprintf "$alarm [%2d] Fid light in search box\n", $i;
                    }
                }
            }
        }

        # ACA-041
	if ($type =~ /BOT|GUI|ACQ/){
	    if (( $maxmag =~ /---/) or ($mag =~ /---/)){
		push @warn, sprintf "$alarm [%2d] Magnitude.  MAG or MAGMAX not defined \n",$i;		
	    }
	    else{
		if (($maxmag - $mag) < $mag_faint_slot_diff){
		    my $slot_diff = $maxmag - $mag;
		    push @warn, sprintf "$alarm [%2d] Magnitude.  MAXMAG - MAG = %1.2f < $mag_faint_slot_diff \n",$i,$slot_diff;
		}
	    }
	}
	

	# Search box too large ACA-018
	if ($type ne 'MON' and $c->{"HALFW$i"} > 200) {
	    push @warn, sprintf "$alarm [%2d] Search Box Size. Search Box Too Large. \n",$i;
	}

	# ACQ/BOTH search box smaller than slew error ACA-015
	if (($type =~ /BOT|ACQ/) and $c->{"HALFW$i"} < $slew_err) {
	    push @warn, sprintf "$alarm [%2d] Search Box Size. Search Box smaller than slew error \n",$i;
	}

        # Double check that 180 and 160 boxes are only applied to bright stars
        if (($type =~ /BOT|ACQ/) and ($c->{"HALFW$i"} > 160)
            and (($mag + $c->{"GS_MAGERR$i"} * 3 / 100) > 9.2)){
            push @warn, sprintf "$alarm [%2d] Search Box Size. Star too faint for > 160 box. \n",$i;
        }
        if (($type =~ /BOT|ACQ/) and ($c->{"HALFW$i"} > 120)
            and (($mag + $c->{"GS_MAGERR$i"} * 1 / 100) > 10.2)){
            push @warn, sprintf "$alarm [%2d] Search Box Size. Star too faint for > 120 box. \n",$i;
        }

	# Check that readout sizes are all 6x6 for science observations ACA-027
	if ($is_science && $type =~ /BOT|GUI|ACQ/  && $c->{"SIZE$i"} ne "6x6"){
	  if (($c->{"SIZE$i"} eq "8x8") and ($or->{HAS_MON}) and ($c->{"IMNUM$i"} == 7 )){
	    push @{$self->{fyi}}, sprintf("$info [%2d] Readout Size. 8x8 Stealth MON?", $i);
	  }
	  else{
	    push @warn, sprintf("$alarm [%2d] Readout Size. %s Should be 6x6\n", $i, $c->{"SIZE$i"});
	  }
	}

	# Check that readout sizes are all 8x8 for engineering observations ACA-028
	if ($is_er && $type =~ /BOT|GUI|ACQ/  && $c->{"SIZE$i"} ne "8x8"){
	    push @warn, sprintf("$alarm [%2d] Readout Size.  %s Should be 8x8\n", $i, $c->{"SIZE$i"});
	}
	
	# Check that readout sizes are all 8x8 for FID lights ACA-029
	push @warn, sprintf("$alarm [%2d] Readout Size.  %s Should be 8x8\n", $i, $c->{"SIZE$i"})
	    if ($type =~ /FID/  && $c->{"SIZE$i"} ne "8x8");

	# Check that readout size is 8x8 for monitor windows ACA-030
	push @warn, sprintf("$alarm [%2d] Readout Size. %s Should be 8x8\n", $i, $c->{"SIZE$i"})
	    if ($type =~ /MON/  && $c->{"SIZE$i"} ne "8x8");
	

	# Bad Pixels ACA-025
        my @close_pixels;
        my @dr;
        if ($type =~ /GUI|BOT/){
	    foreach my $pixel (@bad_pixels) {
		my $dy = abs($yag-$pixel->{yag});
		my $dz = abs($zag-$pixel->{zag});
		my $dr = sqrt($dy**2 + $dz**2);
		next unless ( $dz < $dither+25 and $dy < $dither+25 );
		push @close_pixels, sprintf("%3d, %3d, %3d\n", $dy, $dz, $dr);
		push @dr, $dr;
	    }   
	    if ( @close_pixels > 0 ) {
		my ($closest) = sort { $dr[$a] <=> $dr[$b] } (0 .. $#dr);
		my $warn = sprintf("$alarm [%2d] Nearby ACA bad pixel. " .
				   "Y,Z,Radial seps: " . $close_pixels[$closest],
				   $i); #Only warn for the closest pixel
		push @warn, $warn;
	    }
	}
	
	# Spoiler star (for search) and common column
	
	foreach my $star (values %{$self->{agasc_hash}}) {
            # Skip tests if $star is the same as the catalog star
	    next if (  $star->{id} eq $sid || 	
		       ( abs($star->{yag} - $yag) < $ID_DIST_LIMIT 
			 && abs($star->{zag} - $zag) < $ID_DIST_LIMIT 
			 && abs($star->{mag_aca} - $mag) < 0.1 ) );
	    my $dy = abs($yag-$star->{yag});
	    my $dz = abs($zag-$star->{zag});
	    my $dr = sqrt($dz**2 + $dy**2);
	    my $dm = $mag ne '---' ? $mag - $star->{mag_aca} : 0.0;
	    my $dm_string = $mag ne '---' ? sprintf("%4.1f", $mag - $star->{mag_aca}) : '?';
	    
	    # Fid within $dither + 25 arcsec of a star (yellow) and within 4 mags (red) ACA-024
	    if ($type eq 'FID'
		and $dz < $dither+25 and $dy < $dither+25
		and $dm > -5.0) {
		my $warn = sprintf("$alarm [%2d] Fid spoiler.  %10d: " .
				   "Y,Z,Radial,Mag seps: %3d %3d %3d %4s\n",$i,$star->{id},$dy,$dz,$dr,$dm_string);
		if ($dm > -4.0)  { push @warn, $warn } 
		else { push @yellow_warn, $warn }
	    }

	    # Star within search box + search error and within 1.0 mags 
	    if ($type ne 'MON' and $dz < $halfw + $search_err and $dy < $halfw + $search_err and $dm > -1.0) {
		my $warn = sprintf("$alarm [%2d] Search spoiler. %10d: " .
				   "Y,Z,Radial,Mag seps: %3d %3d %3d %4s\n",$i,$star->{id},$dy,$dz,$dr,$dm_string);
		if ($dm > -0.2)  { push @warn, $warn } # ACA-022 ACA-023
		else { push @yellow_warn, $warn }
	    }
	    # Common column: dz within limit, spoiler is $col_sep_mag brighter than star,
	    # and spoiler is located between star and readout ACA-026
	    if ($type ne 'MON'
		and $dz < $col_sep_dist
		and $dm > $col_sep_mag
		and ($star->{yag}/$yag) > 1.0 
		and abs($star->{yag}) < 2500) {
		push @warn,sprintf("$alarm [%2d] Common Column. %10d " .
				   "at Y,Z,Mag: %5d %5d %5.2f\n",$i,$star->{id},$star->{yag},$star->{zag},$star->{mag_aca});
	    }
	}
    }



# Find the smallest rectangle size that all acq stars fit in
    my $y_side = sprintf( "%.0f", $max_y - $min_y );
    my $z_side = sprintf( "%.0f", $max_z - $min_z );
    push @yellow_warn, "$alarm Guide stars fit in $y_side x $z_side square arc-second box\n"
	if $y_side < $min_y_side && $z_side < $min_z_side;

    # Collect warnings
    push @{$self->{warn}}, @warn;
    push @{$self->{orange_warn}}, @orange_warn;
    push @{$self->{yellow_warn}}, @yellow_warn;
}

#############################################################################################
sub check_flick_pix_mon {
#############################################################################################
    my $self = shift;

    # this only applies to ERs (and they should have numeric obsids)
    return unless ( $self->{obsid} =~ /^\d+$/ and $self->{obsid} >= $ER_MIN_OBSID );

    my $c;
    # Check for existence of a star catalog
    return unless ($c = find_command($self, "MP_STARCAT"));
    
    # See if there are any monitor stars.  Return if not.
    my @mon_stars = grep { $c->{"TYPE$_"} eq 'MON' } (1..16);
    return unless (@mon_stars);

    for my $mon_star (@mon_stars){

	push @{$self->{fyi}}, sprintf("$info Obsid contains flickering pixel MON\n");


	push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Size is not 8x8\n", $mon_star)
	    unless $c->{"SIZE${mon_star}"} eq "8x8";
	
	push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Monitor Window RESTRK should be 0\n", $mon_star) 
	    unless $c->{"RESTRK${mon_star}"} == 0;
	
        # Verify the DTS is set to self
	push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. DTS should be set to self\n", $mon_star)
	    unless $c->{"DIMDTS${mon_star}"} == $c->{"IMNUM${mon_star}"};

    }	
    

}


#############################################################################################
sub check_monitor_commanding {
#############################################################################################
    my $self = shift;
    my $backstop = shift;	# Reference to array of backstop commands
    my $or = shift;             # Reference to OR list hash
    my $time_tol = 10;		# Commands must be within $time_tol of expectation
    my $c;
    my $bs;
    my $cmd;

    my $r2a = 180./3.14159265*3600;

    # Save the number of warnings when starting this method
    my $n_warn = scalar(@{$self->{warn}});

    # if this is a real numeric obsid
    if ( $self->{obsid} =~ /^\d*$/ ){

	# Don't worry about monitor commanding for non-science observations
	return if ($self->{obsid} >= $ER_MIN_OBSID);
    }

    # Check for existence of a star catalog
    return unless ($c = find_command($self, "MP_STARCAT"));
    

    # See if there are any monitor stars requested in the OR
    my $or_has_mon = ( defined $or->{HAS_MON} ) ? 1 : 0;

    my @mon_stars = grep { $c->{"TYPE$_"} eq 'MON' } (1..16);

    # if there are no requests in the OR and there are no MON stars, exit
    return unless $or_has_mon or scalar(@mon_stars);


    my $found_mon = scalar(@mon_stars);
    my $stealth_mon = 0;

    if (($found_mon) and (not $or_has_mon)){ 
      push @{$self->{warn}}, sprintf("$alarm MON not in OR, but in catalog. Position not checked.\n");    
    }
    
    # Where is the requested OR?
    my $q_aca = Quat->new($self->{ra}, $self->{dec}, $self->{roll});
    my ($or_yang, $or_zang);
    if ($or_has_mon){
      ($or_yang, $or_zang) = Quat::radec2yagzag($or->{MON_RA}, $or->{MON_DEC}, $q_aca) if ($or_has_mon) ;   
    }

    # Check all indices
  IDX:
    for my $idx ( 1 ... 16 ){
	my %idx_hash = (idx => $idx );
	($idx_hash{type}, 
	 $idx_hash{imnum}, 
	 $idx_hash{restrk}, 
	 $idx_hash{yang}, 
	 $idx_hash{zang}, 
	 $idx_hash{dimdts}, 
	 $idx_hash{size}) 
	    = map { $c->{"$_${idx}"} } qw( 
					   TYPE 
					   IMNUM 
					   RESTRK 
					   YANG 
					   ZANG 
					   DIMDTS 
					   SIZE);
	my $y_sep = $or_yang*$r2a - $idx_hash{yang};
	my $z_sep = $or_zang*$r2a - $idx_hash{zang};
	$idx_hash{sep} = sqrt($y_sep**2 + $z_sep**2);
	
	# if this is a plain commanded MON
	if ($idx_hash{type} =~ /MON/ ){
	  # if it doesn't match the requested location ACA-037
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Monitor Window is %6.2f arc-seconds off of OR specification\n"
					 , $idx_hash{idx}, $idx_hash{sep}) 
	    if $idx_hash{sep} > 2.5;
	# if it isn't 8x8
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Size is not 8x8\n", $idx_hash{idx})
	    unless $idx_hash{size} eq "8x8";

	# if it isn't in slot 7 ACA-036
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Monitor Window is in slot %2d and should be in slot 7.\n"
					 , $idx_hash{idx}, $idx_hash{imnum}) 
	    if $idx_hash{imnum} != 7;
	# ACA-038
	push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Monitor Window is set to Convert-to-Track\n", $idx_hash{idx}) 
	  if $idx_hash{restrk} == 1;
	  

	# Verify the the designated track star is indeed a guide star. ACA-039
	  my $dts_slot = $idx_hash{dimdts};
	  my $dts_type = "NULL";
	  foreach my $dts_index (1..16) {
	    next unless $c->{"IMNUM$dts_index"} == $dts_slot and $c->{"TYPE$dts_index"} =~ /GUI|BOT/;
	    $dts_type = $c->{"TYPE$dts_index"};
	    last;
	  }
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. DTS for [%2d] is set to slot %2d which does not contain a guide star.\n", 
					 $idx_hash{idx}, $idx_hash{idx}, $dts_slot) 
	    if $dts_type =~ /NULL/;
	  next IDX;
	}
	
	if (($idx_hash{type} =~ /GUI|BOT/) and ($idx_hash{size} eq '8x8') and ($idx_hash{imnum} == 7)){
	  $stealth_mon = 1;
	  push @{$self->{fyi}}, sprintf("$info [%2d] Appears to be MON used as GUI/BOT.  Has Magnitude been checked?\n",
					$idx);
	  # if it doesn't match the requested location
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Guide star as MON %6.2f arc-seconds off OR specification\n"
					 , $idx_hash{idx}, $idx_hash{sep}) 
	    if $idx_hash{sep} > 2.5;
	  
	  next IDX;
	}
	if ((not $found_mon) and ($idx_hash{sep} < 2.5)){
	  # if there *should* be one there...
	  push @{$self->{fyi}}, sprintf("$info [%2d] Commanded at intended OR MON position; but not configured for MON\n",
					$idx);
	}
	
      }


    # if I don't have a plain MON or a "stealth" MON, throw a warning
    push @{$self->{warn}}, sprintf("$alarm MON requested in OR, but none found in catalog\n")
      unless ( $found_mon or $stealth_mon );

    # if we're using a guide star, we don't need the rest of the dither setup
    if ($stealth_mon and not $found_mon){
      return;
    }

    # Find the associated maneuver command for this obsid.  Need this to get the
    # exact time of the end of maneuver
    my $manv;
    unless ($manv = find_command($self, "MP_TARGQUAT", -1)) {
      push @{$self->{warn}}, sprintf("$alarm Cannot find maneuver for checking monitor commanding\n");
      return;
    }


    # Now check in backstop commands for :
    #  Dither is disabled (AODSDITH) 1 min prior to the end of the maneuver (EOM)
    #    to the target attitude.
    #  The OFP Aspect Camera Process is restarted (AOACRSET) 3 minutes after EOM.
    #  Dither is enabled (AOENDITH) 5 min after EOM
    # ACA-040

    my $t_manv = $manv->{tstop};
    my %dt = (AODSDITH => -60, AOACRSET => 180, AOENDITH => 300);
    my %cnt = map { $_ => 0 } keys %dt;
    foreach $bs (grep { $_->{cmd} eq 'COMMAND_SW' } @{$backstop}) {
	my %param = Ska::Parse_CM_File::parse_params($bs->{params});
	next unless ($param{TLMSID} =~ /^AO/);
	foreach $cmd (keys %dt) {
	    if ($cmd =~ /$param{TLMSID}/){
		if ( abs($bs->{time} - ($t_manv+$dt{$cmd})) < $time_tol){
		    $cnt{$cmd}++;
		}
	    }
	}
    }

    # Add warning messages unless exactly one of each command was found at the right time
    foreach $cmd (qw (AODSDITH AOACRSET AOENDITH)) {
	next if ($cnt{$cmd} == 1);
	$cnt{$cmd} = 'no' if ($cnt{$cmd} == 0);
	push @{$self->{warn}}, "$alarm Found $cnt{$cmd} $cmd commands near " . time2date($t_manv+$dt{$cmd}) . "\n";
    }

    # If the number of warnings has not changed during this routine, it passed all checks
    if (scalar(@{$self->{warn}}) == $n_warn){
        push @{$self->{fyi}},
            sprintf("$info Monitor window special commanding meets requirements\n");
    }
}

#############################################################################################
sub check_fids {
#############################################################################################
    my $self = shift;
    my $c = shift;		# Star catalog command 
    my $warn = shift;		# Array ref to warnings for this obsid

    my (@fid_ok, @fidsel_ok);
    my ($i, $i_fid);
    
    # If no star cat fids and no commanded fids, then return
    my $fid_number = @{$self->{fid}};
    return if ($fid_number == 0 && @{$self->{fidsel}} == 0);

    # Make sure we have SI and SIM_OFFSET_Z to be able to calculate fid yang and zang
    unless (defined $self->{SI}) {
	push @{$warn}, "$alarm Unable to check fids because SI undefined\n";
	return;
    }
    unless (defined $self->{SIM_OFFSET_Z}){
	push @{$warn}, "$alarm Unable to check fids because SIM_OFFSET_Z undefined\n";
	return;
    }

    @fid_ok = map { 0 } @{$self->{fid}};

    # Calculate yang and zang for each commanded fid, then cross-correlate with
    # all commanded fids. 
    foreach my $fid (@{$self->{fidsel}}) {

	my ($yag, $zag, $error) = calc_fid_ang($fid, $self->{SI}, $self->{SIM_OFFSET_Z}, $self->{obsid});

	if ($error) {
	    push @{$warn}, "$alarm $error\n";
	    next;
	}
	my $fidsel_ok = 0;

	# Cross-correlate with all star cat fids
	for  $i_fid (0 .. $#fid_ok) {
	    $i = $self->{fid}[$i_fid]; # Index into star catalog entries

	    # Check if starcat fid matches fidsel fid position to within 10 arcsec
	    if (abs($yag - $c->{"YANG$i"}) < 10.0 && abs($zag - $c->{"ZANG$i"}) < 10.0) {
		$fidsel_ok = 1;
		$fid_ok[$i_fid] = 1;
		last;
	    }
	}

        # ACA-034
	push @{$warn}, sprintf("$alarm Fid $self->{SI} FIDSEL $fid not found within 10 arcsec of (%.1f, %.1f)\n",
			       $yag, $zag)
	    unless ($fidsel_ok);
    }
    # ACA-035
    for $i_fid (0 .. $#fid_ok) {
	push @{$warn}, "$alarm Fid with IDX=\[$self->{fid}[$i_fid]\] is in star catalog but is not turned on via FIDSEL\n"
	    unless ($fid_ok[$i_fid]);
    }
}

##############################################################################
sub calc_fid_ang {
#   From OFLS SDS:
#   Y_ang = fid position angle measured about the ACA z-axis as shown in 
#           Fig. 4.3-5.  In that figure, Y_ang corresponds to the ACA 
#           y angle, or "yag".
#   Y_S   = Y coordinate of fid light
#   R_H   = distance from SI fid light point of origin to HRMA nodal point
#   X_f   = Offset from nominal FA position
#   
#   Y_ang = -Y_s / (R_H - X_f)
#   Z_ang = -(Z_s + Z_f) / (R_H - X_f)
##############################################################################
    my ($fid, $si, $sim_z_offset, $obsid) = @_;
    my $r2a = 180./3.14159265*3600;

    # Make some variables for accessing ODB elements
    $si =~ tr/a-z/A-Z/;
    $si =~ s/[-_]//;
    
    my ($si2hrma) = ($si =~ /(ACIS|HRCI|HRCS)/);

    # Define allowed range for $fid for each detector
    my %range = (ACIS => [1,6],
		 HRCI => [7,10],
		 HRCS => [11,14]);

    # Check that the fid light (from fidsel history) is appropriate for the detector
    unless ($fid >= $range{$si2hrma}[0] and $fid <= $range{$si2hrma}[1]) {
	return (undef, undef, "Commanded fid light $fid does not correspond to detector $si2hrma");
    }
    
    # Generate index into ODB tables.  This goes from 0..5 (ACIS) or 0..3 (HRC)
    my $fid_id = $fid - $range{$si2hrma}[0]; 
    
    # Calculate fid angles using formula in OFLS
    my $y_s = $odb{"ODB_${si}_FIDPOS"}[$fid_id*2];
    my $z_s = $odb{"ODB_${si}_FIDPOS"}[$fid_id*2+1];
    my $r_h = $odb{"ODB_${si2hrma}_TO_HRMA"}[$fid_id];
    my $z_f = -$sim_z_offset * $odb{"ODB_TSC_STEPS"}[0];
    my $x_f = 0;

    if (not $y_s) {
	print "yagzag $obsid '$si' '$si2hrma' '$y_s' '$z_s' '$r_h' '$x_f'\n";
    }
    my $yag = -$y_s / ($r_h - $x_f) * $r2a;
    my $zag = -($z_s + $z_f) / ($r_h - $x_f) * $r2a;
    
    return ($yag, $zag);
}



#############################################################################################
sub print_report {
#############################################################################################
    my $self = shift;
    my $c;
    my $o = '';			# Output

    my $target_name = ( $self->{TARGET_NAME}) ? $self->{TARGET_NAME} : $self->{SS_OBJECT};

    $o .= sprintf( "<TABLE WIDTH=853 CELLPADDING=0><TD VALIGN=TOP WIDTH=810><PRE><A NAME=\"obsid%s\"></A>", $self->{obsid});
    $o .= sprintf ("${blue_font_start}OBSID: %-5s  ", $self->{obsid});
    $o .= sprintf ("%-22s %-6s SIM Z offset:%-5d (%-.2fmm) Grating: %-5s", $target_name, $self->{SI}, 
		   $self->{SIM_OFFSET_Z},  ($self->{SIM_OFFSET_Z})*1000*($odb{"ODB_TSC_STEPS"}[0]), $self->{GRATING}) if ($target_name);
    $o .= sprintf "${font_stop}\n";
    if ( ( defined $self->{ra} ) and (defined $self->{dec}) and (defined $self->{roll})){
	$o .= sprintf "RA, Dec, Roll (deg): %12.6f %12.6f %12.6f\n", $self->{ra}, $self->{dec}, $self->{roll};
    }
    if ( defined $self->{DITHER_ON} && $self->{obsid} < $ER_MIN_OBSID ) {
	$o .= sprintf "Dither: %-3s ",$self->{DITHER_ON};
	$o .= sprintf ("Y_amp=%4.1f  Z_amp=%4.1f  Y_period=%6.1f  Z_period=%6.1f",
		       $self->{DITHER_Y_AMP}*3600., $self->{DITHER_Z_AMP}*3600.,
		       360./$self->{DITHER_Y_FREQ}, 360./$self->{DITHER_Z_FREQ})
	    if ($self->{DITHER_ON} eq 'ON' && $self->{DITHER_Y_FREQ} && $self->{DITHER_Z_FREQ});
	$o .= "\n";
    }

    $o .= sprintf("<A HREF=\"%s/%s.html#%s\">BACKSTOP</A> ", $self->{STARCHECK}, basename($self->{backstop}), $self->{obsid});
    $o .= sprintf("<A HREF=\"%s/%s.html#%s\">GUIDE_SUMM</A> ", $self->{STARCHECK}, basename($self->{guide_summ}), $self->{obsid});
    $o .= sprintf("<A HREF=\"%s/%s.html#%s\">OR</A> ", $self->{STARCHECK}, basename($self->{or_file}), $self->{obsid}) 
	if ($self->{or_file});
    $o .= sprintf("<A HREF=\"%s/%s.html#%s\">MANVR</A> ", $self->{STARCHECK}, basename($self->{mm_file}), $self->{dot_obsid});
    $o .= sprintf("<A HREF=\"%s/%s.html#%s\">DOT</A> ", $self->{STARCHECK}, basename($self->{dot_file}), $self->{obsid});
    $o .= sprintf("<A HREF=\"%s/%s.html#%s\">MAKE_STARS</A> ", $self->{STARCHECK}, "make_stars.txt" , $self->{obsid});
    $o .= sprintf("<A HREF=\"%s/%s.html#%s\">TLR</A> ", $self->{STARCHECK}, basename($self->{tlr_file}) , $self->{obsid});
    $o .= sprintf "\n\n";
    for my $n (1 .. 10) {		# Allow for multiple TARGQUAT cmds, though 2 is the typical limit
	if ($c = find_command($self, "MP_TARGQUAT", $n)) {
	    $o .= sprintf "MP_TARGQUAT at $c->{date} (VCDU count = $c->{vcdu})\n";
	    $o .= sprintf("  Q1,Q2,Q3,Q4: %.8f  %.8f  %.8f  %.8f\n", $c->{Q1}, $c->{Q2}, $c->{Q3}, $c->{Q4});
	    if (exists $c->{man_err} and exists $c->{dur} and exists $c->{angle}){
		$o .= sprintf("  MANVR: Angle= %6.2f deg  Duration= %.0f sec  Slew err= %.1f arcsec  End= %s\n",
			      $c->{angle}, $c->{dur}, $c->{man_err}, substr(time2date($c->{tstop}), 0, 17));
		}
	    $o .= "\n";
	}
    }

    my $acq_stat_lookup = "$config{paths}->{acq_stat_query}?id=";


    my $table;
    if ($c = find_command($self, "MP_STARCAT")) {


	my @fid_fields = qw (TYPE  SIZE P_ACQ GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW GS_PASS GS_NOTES);
	my @fid_format = ( '%6s',   '%5s',  '%8.3f',    '%8s',  '%8.3f',  '%7d',  '%7d',    '%4d',    '%4d',   '%5d',     '%6s',  '%4s');
	my @star_fields = qw (   TYPE  SIZE P_ACQ GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW GS_PASS GS_NOTES);
	my @star_format = ( '%6s',   '%5s',  '%8.3f',    '%8s',  '%8.3f',  '%7d',  '%7d',    '%4d',    '%4d',   '%5d',     '%6s',  '%4s');

	$table.= sprintf "MP_STARCAT at $c->{date} (VCDU count = $c->{vcdu})\n";
	$table.= sprintf "---------------------------------------------------------------------------------------------\n";
	$table.= sprintf " IDX SLOT        ID  TYPE   SZ   P_ACQ    MAG   MAXMAG   YANG   ZANG DIM RES HALFW PASS NOTES\n";
#                      [ 4]  3   971113176   GUI  6x6   1.000   7.314   8.844  -2329  -2242   1   1   25  bcmp
	$table.= sprintf "---------------------------------------------------------------------------------------------\n";
	
	
	foreach my $i (1..16) {
	    my @fields = @star_fields;
	    my @format = @star_format;
	    next if ($c->{"TYPE$i"} eq 'NUL');
	    if ($c->{"TYPE$i"} eq 'FID'){
		@fields = @fid_fields;
		@format = @fid_format;
	    }
	    # Define the color of output star catalog line based on NOTES:
	    #   Yellow if NOTES is non-trivial. 
	    #   Red if NOTES has a 'b' for bad class or if a guide star has bad color.
	    my $color = ($c->{"GS_NOTES$i"} =~ /\S/) ? 'yellow' : '';
	    $color = 'red' if ($c->{"GS_NOTES$i"} =~ /b/ || ($c->{"GS_NOTES$i"} =~ /c/ && $c->{"TYPE$i"} =~ /GUI|BOT/));

	    if ($color){
		$table .= ( $color eq 'red') ? $red_font_start :
		    ( $color eq 'yellow') ? $yellow_font_start : qq{};
	    }
	    $table.= sprintf "[%2d]",$i;
	    # change from a map to a loop to get some conditional control, since PoorTextFormat can't seem to 
	    # take nested \link_target when the line is colored green or red
	    $table .= sprintf('%3d', $c->{"IMNUM${i}"});
	    my $db_stats = $c->{"GS_USEDBEFORE${i}"};
	    my $idlength = length($c->{"GS_ID${i}"});
	    my $idpad_n = 12 - $idlength;
	    my $idpad;
	    while ($idpad_n > 0 ){
		$idpad .= " ";
		$idpad_n --;
	    }


            my $acq_prob = "";
            if ($c->{"TYPE$i"} =~ /BOT|ACQ/){
                my $prob = $self->{acq_probs}->{$c->{"IMNUM${i}"}};
                $acq_prob = sprintf("Prob Acq Success %5.3f", $prob);

            }
            # Make the id a URL if there is star history or if star history could
            # not be checked (no db_handle)
            my $star_link;
            if ((not defined $db_handle) or (($db_stats->{acq} or $db_stats->{gui}))){
                $star_link = sprintf("HREF=\"%s%s\"",$acq_stat_lookup, $c->{"GS_ID${i}"});
            }
            else{
                $star_link = sprintf("A=\"star\"");
            }
            # If there is database history, add it to the blurb
            my $history_blurb = "";
	    if ($db_stats->{acq} or $db_stats->{gui}){
                $history_blurb = sprintf("ACQ total:%d noid:%d <BR />"
			       . "GUI total:%d bad:%d fail:%d obc_bad:%d <BR />"
			       . "Avg Mag %4.2f <BR />",
                                         $db_stats->{acq}, $db_stats->{acq_noid},
                                         $db_stats->{gui}, $db_stats->{gui_bad},
                                         $db_stats->{gui_fail}, $db_stats->{gui_obc_bad},
                                         $db_stats->{avg_mag})
            }
            # If the object has catalog information, add it to the blurb
            # for the hoverover
            my $cat_blurb = "";
            if (defined $c->{"GS_MAGERR$i"}){
                $cat_blurb = sprintf("mac_aca_err=%4.2f pos_err=%4.2f color1=%4.2f <BR />",
                                     $c->{"GS_MAGERR$i"}/100., $c->{"GS_POSERR$i"}/1000., $c->{"GS_BV$i"});
            }

            # If the line is a fid or "---" don't make a hoverover
            if (($c->{"TYPE$i"} eq 'FID') or ($c->{"GS_ID$i"} eq '---')){
                $table .= sprintf("${idpad}%s", $c->{"GS_ID${i}"});
            }
            # Otherwise, construct a hoverover and a url as needed, using the blurbs made above
            else{
                $table .= sprintf("${idpad}<A $star_link STYLE=\"text-decoration: none;\" "
                                      . "ONMOUSEOVER=\"return overlib ('"
                                      . "$cat_blurb"
                                      . "$history_blurb"
                                      . "$acq_prob"
                                      . "', WIDTH, 300);\" ONMOUSEOUT=\"return nd();\">%s</A>",
                                  $c->{"GS_ID${i}"});
            }
	    for my $field_idx (0 .. $#fields){
		my $curr_format = $format[$field_idx];
                my $field_color = 'black';
                # override mag formatting if it lost its 3
                # decimal places during JSONifying
                if (($fields[$field_idx] eq 'GS_MAG')
                    and ($c->{"$fields[$field_idx]$i"} ne '---')){
                    $curr_format = "%8.3f";
                }

                # For P_ACQ fields, if it is a string, use that format
                # If it is defined, and probability is less than .50, print red
                # If it is defined, and probability is less than .75, print "yellow"
                if (($fields[$field_idx] eq 'P_ACQ')
                    and ($c->{"P_ACQ$i"} eq '---')){
                    $curr_format = "%8s";
                }
                elsif (($fields[$field_idx] eq 'P_ACQ')
                           and ($c->{"P_ACQ$i"} < .50)){
                    $field_color = 'red';
                }
                elsif (($fields[$field_idx] eq 'P_ACQ')
                        and ($c->{"P_ACQ$i"} < .75)){
                    $field_color = 'yellow';
                }

                # For MAG fields, if the P_ACQ probability is defined and has a color,
                # share that color.  Otherwise, if the MAG violates the yellow/red warning
                # limit, colorize.
                if ($fields[$field_idx] eq 'GS_MAG'){
                    if (($c->{"P_ACQ$i"} ne '---') and ($c->{"P_ACQ$i"} < .50)){
                        $field_color = 'red';
                    }
                    elsif (($c->{"P_ACQ$i"} ne '---') and ($c->{"P_ACQ$i"} < .75)){
                        $field_color = 'yellow';
                    }
                    elsif (($c->{"P_ACQ$i"} eq '---') and ($c->{"GS_MAG$i"} ne '---')
                               and ($c->{"GS_MAG$i"} > $self->{mag_faint_red})){
                        $field_color = 'red';
                    }
                    elsif (($c->{"P_ACQ$i"} eq '---') and ($c->{"GS_MAG$i"} ne '---')
                               and ($c->{"GS_MAG$i"} > $self->{mag_faint_yellow})){
                        $field_color = 'yellow';
                    }
                }

                # Use colors if required
                if ($field_color eq 'red'){
                    $curr_format = $red_font_start . $curr_format . $font_stop;
                }
                if ($field_color eq 'yellow'){
                    $curr_format = $yellow_font_start . $curr_format . $font_stop;
                }
                $table .= sprintf($curr_format, $c->{"$fields[$field_idx]$i"});


	    }
	    $table.= $font_stop if ($color);
	    $table.= sprintf "\n";
	}


    }
    else{
        $table = sprintf(" " x 93 . "\n");
    }

    $o .= $table;
    
    $o .= "\n" if (@{$self->{warn}} || @{$self->{yellow_warn}} || @{$self->{fyi}} || @{$self->{orange_warn}});



    if (@{$self->{warn}}) {
	$o .= "${red_font_start}";
	foreach (@{$self->{warn}}) {
	    $o .= $_;
	}
	$o .= "${font_stop}";
    }
    if (@{$self->{orange_warn}}) {
	$o .= "${orange_font_start}";
	foreach (@{$self->{orange_warn}}) {
	    $o .= $_;
	}
	$o .= "${font_stop}";
    }
    if (@{$self->{yellow_warn}}) {
	$o .= "${yellow_font_start}";
	foreach (@{$self->{yellow_warn}}) {
	    $o .= $_;
	}
	$o .= "${font_stop}";
    }
    if (@{$self->{fyi}}) {
	$o .= "${blue_font_start}";
	foreach (@{$self->{fyi}}) {
	    $o .= $_;
	}
	$o .= "${font_stop}";
    }
    $o .= "\n";

    if (exists $self->{figure_of_merit}) {
	my @probs = @{ $self->{figure_of_merit}->{cum_prob}};
	my $bad_FOM = $self->{figure_of_merit}->{cum_prob_bad};
	$o .= "$red_font_start" if $bad_FOM;
	$o .= "Probability of acquiring 2,3, and 4 or fewer stars (10^x):\t";
        # override formatting to match pre-JSON strings
        foreach (2..4) {
            $o .= substr(sprintf("%.4f", "$probs[$_]"), 0, 6) . "\t";
        }
	$o .= "$font_stop" if $bad_FOM;
	$o .= "\n";
	$o .= sprintf("Acquisition Stars Expected  : %.2f\n",
                      $self->{figure_of_merit}->{expected});
    }


    # Don't print CCD temperature and dynamic limits if there is no catalog
    if ($c = find_command($self, "MP_STARCAT")){
        $o .= sprintf("Predicted Max CCD temperature: %.1f C ", $self->{ccd_temp});
        if (defined $self->{n100_warm_frac}){
            $o .= sprintf("\t N100 Warm Pix Frac %.3f", $self->{n100_warm_frac});
        }
        $o .= "\n";
        $o .= sprintf("Dynamic Mag Limits: Yellow %.2f \t Red %.2f\n",
                      $self->{mag_faint_yellow}, $self->{mag_faint_red});
    }

    # cute little table for buttons for previous and next obsid
    $o .= "</PRE></TD><TD VALIGN=TOP>\n";
    if (defined $self->{prev}->{obsid} or defined $self->{next}->{obsid}){
	$o .= " <TABLE WIDTH=43><TR>";
	if (defined $self->{prev}->{obsid}){
	    $o .= sprintf("<TD><A HREF=\"#obsid%s\"><img align=\"top\" src=\"%s/up.gif\" ></A></TD>", 
			  $self->{prev}->{obsid},
			  $self->{STARCHECK} );
	    $o .= sprintf("<TD><A HREF=\"#obsid%s\">PREV</A> </TD>", $self->{prev}->{obsid});
	}
	else{
	    $o .= sprintf("<TD><img align=\"top\" src=\"%s/up.gif\" ></TD>", 
			  $self->{STARCHECK} );
	    $o .= sprintf("<TD>PREV</TD>");
	}
	$o .= sprintf("<TD>&nbsp; &nbsp;</TD>");
	if (defined $self->{next}->{obsid}){
	    $o .= sprintf("<TD><A HREF=\"#obsid%s\"><img align=\"top\" src=\"%s/down.gif\" ></A></TD>", 
			  $self->{next}->{obsid},
			  $self->{STARCHECK} );
	    $o .= sprintf("<TD><A HREF=\"#obsid%s\">NEXT</A> </TD>", $self->{next}->{obsid});
	}
	$o .= " </TR></TABLE>";

    }
 
    # end of whole obsid table
    $o .= " </TD></TABLE>";



    return $o;
}

#############################################################################################
sub add_guide_summ {
#############################################################################################
# Receives $obsid and a reference to the guide star summary hash
# parses the relevant info from the guide star summary and sticks it into
# the obsid object where it belongs
    my $self = shift;
    my ($obsid, $guide_ref) = @_;
    my $c;

    return unless ($c = find_command($self, 'MP_STARCAT'));

    # target ra, dec, and roll don't seem to be used, but they aren't causing 
    # any harm ...
    $c->{target_ra} = $guide_ref->{$obsid}{ra};
    $c->{target_dec} = $guide_ref->{$obsid}{dec};
    $c->{target_roll} = $guide_ref->{$obsid}{roll};

    my @f;
    my $bad_idx_match = 0;

    # For each idx of the star catalog (starts at 1)
    for my $j (1 .. (1 + $#{ $guide_ref->{$obsid}{info}}) ) {

	@f = split ' ', $guide_ref->{$obsid}{info}[$j-1];

	if (abs( $f[5]*$r2a - $c->{"YANG$j"}) < 10
	    && abs( $f[6]*$r2a - $c->{"ZANG$j"}) < 10)	{
	    $c->{"GS_TYPE$j"} = $f[0];
	    $c->{"GS_ID$j"} = $f[1];
	    $c->{"GS_RA$j"} = $f[2];
	    $c->{"GS_DEC$j"} = $f[3];
	    if ($f[4] eq '---'){
		$c->{"GS_MAG$j"} = $f[4];
	    }
	    else{
		$c->{"GS_MAG$j"} = sprintf "%8.3f", $f[4];
	    }
	    $c->{"GS_YANG$j"} = $f[5] * $r2a;
	    $c->{"GS_ZANG$j"} = $f[6] * $r2a;
	    # Parse the SAUSAGE star selection pass number
	    $c->{"GS_PASS$j"} = defined $f[7] ? ($f[7] =~ /\*+/ ? length $f[7] : $f[7]) : ' ';
	    $c->{"GS_PASS$j"} =~ s/[agf]1//g;
	}
	else {
	    # if the position of the line item in the guide summary doesn't match
	    # set the variable once (so we don't have a warning for all the remaining lines
	    # if there is one missing...)
	    $bad_idx_match = 1;
	}
       
    }

    # if the position of an item didn't match, warn that the guide summary does not match
    # the backstop commanded catalog
    if ($bad_idx_match == 1){
	push @{$self->{warn}}, ">> WARNING: Guide summary does not match commanded catalog.\n";
    }
}

#############################################################################################
sub get_agasc_stars {
#############################################################################################

    my $self = shift;
    my $agasc_file = shift;
    my $c;
    return unless ($c = find_command($self, "MP_TARGQUAT"));

    # Use Python agasc to fetch the stars into a hash
    $self->{agasc_hash} = _get_agasc_stars($self->{ra},
                                           $self->{dec},
                                           $self->{roll},
                                           1.3,
                                           $self->{date},
                                           $agasc_file);

    foreach my $star (values %{$self->{agasc_hash}}) {
	if ($star->{'mag_aca'} < -10 or $star->{'mag_aca_err'} < -10) {
	    push @{$self->{warn}}, sprintf(
                "$alarm Star with bad mag %.1f or magerr %.1f at (yag,zag)=%.1f,%.1f\n",
                $star->{'mag_aca'}, $star->{'mag_aca_err'}, $star->{'yag'}, $star->{'zag'});
	}
    }

}

#############################################################################################
sub identify_stars {
#############################################################################################
    my $self = shift;

    return unless (my $c = find_command($self, 'MP_STARCAT'));

    my $manvr = find_command($self, "MP_TARGQUAT" );

    my $obs_time = $c->{time};

    for my $i (1 .. 16) {
	my $type = $c->{"TYPE$i"};
	next if ($type eq 'NUL');
	next if ($type eq 'FID');

	my $yag = $c->{"YANG$i"};
	my $zag = $c->{"ZANG$i"};
	my $gs_id = $c->{"GS_ID$i"};
	my $gs_ra = $c->{"GS_RA$i"};
	my $gs_dec = $c->{"GS_DEC$i"};

	# strip * off gs_id if present
	$gs_id =~ s/^\*/^/;
	
	# if the star is defined in the guide summary but doesn't seem to be present in the
	# agasc hash for this ra and dec, throw a warning
	unless ((defined $self->{agasc_hash}{$gs_id}) or ($gs_id eq '---')){
	    push @{$self->{warn}}, 
	          sprintf("$alarm [%2d] Star $gs_id is not in retrieved AGASC region by RA and DEC! \n", $i);
	}


	# if the star is defined in the agasc hash, copy
	# the information from the agasc to the catalog

	if (defined $self->{agasc_hash}{$gs_id}){
	    my $star = $self->{agasc_hash}{$gs_id};

            # Confirm that the agasc magnitude matches the guide star summary magnitude
            my $gs_mag = $c->{"GS_MAG$i"};
            my $dmag = abs($star->{mag_aca} - $gs_mag);
            if ($dmag > 0.01){
                push @{$self->{warn}},
                    sprintf("$alarm [%d] Guide sum mag diff from agasc mag %9.5f\n", $i, $dmag);
            }
	    # let's still confirm that the backstop yag zag is what we expect
	    # from agasc and ra,dec,roll ACA-043

	    if (abs($star->{yag} - $yag) > ($ID_DIST_LIMIT)
		|| abs($star->{zag} - $zag) > ($ID_DIST_LIMIT)){
		my $dyag = abs($star->{yag} - $yag);
		my $dzag = abs($star->{zag} - $zag);
		
		if (abs($star->{yag} - $yag) > (2 * $ID_DIST_LIMIT) ||
		    abs($star->{zag} - $zag) > (2 * $ID_DIST_LIMIT)){
		    push @{$self->{warn}}, 
		         sprintf("$alarm [%2d] Backstop YAG,ZAG differs from AGASC by > 3 arcsec: dyag = %2.2f dzag = %2.2f \n", $i, $dyag, $dzag);
		}
		else{
		    push @{$self->{yellow_warn}}, 
		         sprintf("$alarm [%2d] Backstop YAG,ZAG differs from AGASC by > 1.5 arcsec: dyag = %2.2f dzag = %2.2f \n", $i, $dyag, $dzag);
		}
	    }
	    
	    # should I put this in an else statement, or let it stand alone?

	    $c->{"GS_IDENTIFIED$i"} = 1;
	    $c->{"GS_BV$i"} = $star->{bv};
	    $c->{"GS_MAGERR$i"} = $star->{mag_aca_err};
	    $c->{"GS_POSERR$i"} = $star->{poserr};
	    $c->{"GS_CLASS$i"} = $star->{class};
	    $c->{"GS_ASPQ$i"} = $star->{aspq};
	    my $db_hist = star_dbhist( "$gs_id", $obs_time );
	    $c->{"GS_USEDBEFORE$i"} =  $db_hist;

	}
	else{
	    # This loop should just get the $gs_id eq '---' cases
	    foreach my $star (values %{$self->{agasc_hash}}) {
		if (abs($star->{yag} - $yag) < $ID_DIST_LIMIT
		    && abs($star->{zag} - $zag) < $ID_DIST_LIMIT) {
		    $c->{"GS_IDENTIFIED$i"} = 1;
		    $c->{"GS_BV$i"} = $star->{bv};
		    $c->{"GS_MAGERR$i"} = $star->{mag_aca_err};
		    $c->{"GS_POSERR$i"} = $star->{poserr};
		    $c->{"GS_CLASS$i"} = $star->{class};
		    $c->{"GS_ASPQ$i"} = $star->{aspq};
		    $c->{"GS_ID$i"} = "*$star->{id}";	      
		    $c->{"GS_RA$i"} = $star->{ra};
		    $c->{"GS_DEC$i"} = $star->{dec};
		    $c->{"GS_MAG$i"} = sprintf "%8.3f", $star->{mag_aca};
		    $c->{"GS_YANG$i"} = $star->{yag};
		    $c->{"GS_ZANG$i"} = $star->{zag};
		    $c->{"GS_USEDBEFORE$i"} =  star_dbhist( $star->{id}, $obs_time );
		    last;
		}
	    }
	
	    
	}
    }
}

#############################################################################################
sub star_dbhist {
#############################################################################################

    my $star_id = shift;
    my $obs_tstart = shift;

    my $obs_tstart_minus_day = $obs_tstart - 86400;

    return undef if (not defined $db_handle);

    my %stats  =  ( 
		   'agasc_id' => $star_id,
		   'acq' => 0,
		   'acq_noid' => 0,
		   'gui' => 0,
		   'gui_bad' => 0,
		   'gui_fail' => 0,
		   'gui_obc_bad' => 0,
		   'avg_mag' => 13.9375,
		  );
    


    eval{
	# acq_stats_data
	my $sql = SQL::Abstract->new();
	my %acq_where =  ( 'agasc_id' => $star_id,
                           'type' =>  { '!=' => 'FID'},
                           'tstart' => { '<' => $obs_tstart_minus_day }
			   );

	my ($acq_all_stmt, @acq_all_bind ) = $sql->select('acq_stats_data', 
							  '*',
							  \%acq_where );

	my @acq_all = sql_fetchall_array_of_hashref( $db_handle, $acq_all_stmt, @acq_all_bind );
	my @mags;

	if (scalar(@acq_all)){
	    my $noid = 0;
	    for my $attempt (@acq_all){
		if ($attempt->{'obc_id'} =~ 'NOID'){
		    $noid++;
		}
		else{
		  push @mags, $attempt->{'mag_obs'};
		}
	    }
	    $stats{'acq'} = scalar(@acq_all);
	    $stats{'acq_noid'} = $noid;
	}

	# guide_stats_view
	$sql = SQL::Abstract->new();
	my %gui_where = ( 'id' => $star_id,
			  'type' => { '!=' => 'FID' },
			  'kalman_tstart' => { '<' => $obs_tstart_minus_day });

	my ($gui_all_stmt, @gui_all_bind ) = $sql->select('guide_stats_view', 
							  '*',
							  \%gui_where );

	my @gui_all = sql_fetchall_array_of_hashref( $db_handle, $gui_all_stmt, @gui_all_bind );


	if (scalar(@gui_all)){
	    my $bad = 0;
	    my $fail = 0;
	    my $obc_bad = 0;
	    for my $attempt (@gui_all){
		if ($attempt->{'percent_not_tracking'} >= 5){
		    $bad++;
		}
		if ($attempt->{'percent_not_tracking'} == 100){
		    $fail++;
		}
		else{
		  if ((defined $attempt->{'mag_obs_mean'}) and ($attempt->{'mag_obs_mean'} < 13.9 )){
		    push @mags, $attempt->{'mag_obs_mean'};
		  }
		}
		if ($attempt->{'percent_obc_bad_status'} >= 5){
		    $obc_bad++;
		}
	    }
	    $stats{'gui'} = scalar(@gui_all);
	    $stats{'gui_bad'} = $bad;
	    $stats{'gui_fail'} = $fail;
	    $stats{'gui_obc_bad'} = $obc_bad;
	}

	my $mag_sum = 0;
	if (scalar(@mags)){
	  map { $mag_sum += $_ } @mags;
	  $stats{'avg_mag'} = $mag_sum / scalar(@mags);
	}
    };
    if ($@){
      # if we get db errors, just print and move on
      print STDERR $@;

    }

    return \%stats;


}

#############################################################################################
sub star_image_map {
#############################################################################################
	my $self = shift;
	my $c;
    return unless ($c = find_command($self, 'MP_STARCAT'));
    return unless ((defined $self->{ra}) and (defined $self->{dec}) and (defined $self->{roll}));	my $obsid = $self->{obsid};

	# a hash of the agasc ids we want to plot
	my %plot_ids;
	# first the catalog ones
	for my $i (1 .. 16){
		next if ($c->{"TYPE$i"} eq 'NUL');
		next if ($c->{"TYPE$i"} eq 'FID');
		if (defined $self->{agasc_hash}->{$c->{"GS_ID${i}"}}){
			$plot_ids{$c->{"GS_ID${i}"}} = 1;
		}
	}
	# then up to 100 of the stars in the field brighter than
	# the faint plot limit
	my $star_count_limit = 100;
	my $star_count = 0;
    foreach my $star (values %{$self->{agasc_hash}}) {
		next if ($star->{mag_aca} > $faint_plot_mag);
		$plot_ids{$star->{id}} = 1;
		last if $star_count > $star_count_limit;
		$star_count++;
	}

	# notes for pixel scaling.
	# these will need to change if we resize the images.
        # top right +384+39
        # top left +54+39
	# 2900x2900
	my $pix_scale = 330 / (2900. * 2);
	my $map = "<map name=\"starmap_${obsid}\" id=\"starmap_${obsid}\"> \n";
	for my $star_id (keys %plot_ids){
		my $cat_star = $self->{agasc_hash}->{$star_id};
		my $sid = $cat_star->{id};
		my $yag = $cat_star->{yag};
		my $zag = $cat_star->{zag};
		my ($pix_row, $pix_col) = ('None', 'None');
		eval{
			($pix_row, $pix_col) = toPixels($yag, $zag);		
		};
		my $image_x = 54 + ((2900 - $yag) * $pix_scale);
		my $image_y = 39 + ((2900 - $zag) * $pix_scale);
		my $star = '<area href="javascript:void(0);"' . "\n"
			. 'ONMOUSEOVER="return overlib (' 
			. "'id=$sid <br/>" 
			. sprintf("yag,zag=%.2f,%.2f <br />", $yag, $zag)
			. "row,col=$pix_row,$pix_col <br/>" 
			. sprintf("mag_aca=%.2f <br />", $cat_star->{mag_aca})
			. sprintf("mag_aca_err=%.2f <br />", $cat_star->{mag_aca_err} / 100.0)
			. sprintf("class=%s <br />", $cat_star->{class})
			. sprintf("color=%.3f <br />", $cat_star->{bv})
			. sprintf("aspq1=%.1f <br />", $cat_star->{aspq})
			. '\', WIDTH, 220);"' . "\n"
			. 'ONMOUSEOUT="return nd();"' . "\n"
			. 'SHAPE="circle"' . "\n"
			. 'ALT=""' . "\n"
			. "COORDS=\"$image_x,$image_y,2\">" . "\n";
		$map .= $star;
	}	
	$map .= "</map> \n";          
	return $map;
}


#############################################################################################
sub quat2radecroll {
#############################################################################################
    my $r2d = 180./3.14159265;

    my ($q1, $q2, $q3, $q4) = @_;

    my $q12 = $q1**2;
    my $q22 = $q2**2;
    my $q32 = $q3**2;
    my $q42 = $q4**2;

    my $xa = $q12 - $q22 - $q32 + $q42;
    my $xb = 2 * ($q1 * $q2 + $q3 * $q4);
    my $xn = 2 * ($q1 * $q3 - $q2 * $q4);
    my $yn = 2 * ($q2 * $q3 + $q1 * $q4);
    my $zn = $q32 + $q42 - $q12 - $q22;

    my $ra   = atan2($xb, $xa) * $r2d;
    my $dec  = atan2($xn, sqrt(1 - $xn**2)) * $r2d;
    my $roll = atan2($yn, $zn) * $r2d;
    $ra += 360 if ($ra < 0);
    $roll += 360 if ($roll < 0);

    return ($ra, $dec, $roll);
}


###################################################################################
sub count_guide_stars{
###################################################################################
    my $self=shift;
    my $c;

    return 0.0 unless ($c = find_command($self, 'MP_STARCAT'));
    my @mags = ();
    for my $i (1 .. 16){
	if ($c->{"TYPE$i"} =~ /GUI|BOT/){
            my $mag = $c->{"GS_MAG$i"};
            push @mags, $mag;
	}
    }
    return _guide_count(\@mags, $self->{ccd_temp});
}

###################################################################################
sub check_big_box_stars{
###################################################################################
    my $self = shift;
    my $c;
    my $big_box_count = 0;
    return unless ($c = find_command($self, 'MP_STARCAT'));
    for my $i (1 .. 16){
        my $type = $c->{"TYPE$i"};
        my $hw = $c->{"HALFW$i"};
        if ($type =~ /ACQ|BOT/){
            if ($hw >= 160){
                $big_box_count++;
            }
        }
    }
    if ($big_box_count < 3){
        push @{$self->{warn}}, "$alarm Fewer than 3 ACQ stars with boxes >= 160 arcsec\n";
    }
}


###################################################################################
sub set_ccd_temps{
###################################################################################
    my $self = shift;
    my $obsid_temps = shift;
    # if no temperature data, just return
    if ((not defined $obsid_temps->{$self->{obsid}})
        or (not defined $obsid_temps->{$self->{obsid}}->{ccd_temp})){
        push @{$self->{warn}}, "$alarm No CCD temperature prediction for obsid\n";
        push @{$self->{warn}}, sprintf("$alarm Using %s (planning limit) for t_ccd for mag limits\n",
                                       $config{ccd_temp_red_limit});
        $self->{ccd_temp} = $config{ccd_temp_red_limit};
        return;
    }
    # set the temperature to the value for the current obsid
    $self->{ccd_temp} = $obsid_temps->{$self->{obsid}}->{ccd_temp};
    $self->{n100_warm_frac} = $obsid_temps->{$self->{obsid}}->{n100_warm_frac};
    # add warnings for limit violations
    if ($self->{ccd_temp} > $config{ccd_temp_red_limit}){
        push @{$self->{fyi}}, sprintf("$info CCD temperature exceeds %.1f C\n",
                                       $config{ccd_temp_red_limit});
    }
    if (($self->{ccd_temp} > -1.0) or ($self->{ccd_temp} < -16.0)){
        push @{$self->{yellow_warn}}, sprintf(
            ">> WARNING: t_ccd %.2f outside range -16.0 to -1.0. Clipped.",
            $self->{ccd_temp});
        $self->{ccd_temp} = $self->{ccd_temp}  >  -1.0  ? -1.0
                          : $self->{ccd_temp} < -16.0  ? -16.0
                          : $self->{ccd_temp};
    }
}
