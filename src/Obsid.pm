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

#use lib '/proj/sot/ska/lib/site_perl';
use Quat;
use Ska::ACACoordConvert;
use File::Basename;
use POSIX qw(floor);
use English;
use IO::All;
use Ska::Convert qw(date2time);

use Ska::Starcheck::FigureOfMerit qw( make_figure_of_merit );
use RDB;

use Ska::AGASC;
use SQL::Abstract;
use Ska::DatabaseUtil qw( sql_fetchall_array_of_hashref );
use Carp;


# use FigureOfMerit;

# Constants

my $VERSION = '$Id$';  # '
my $ACA_MANERR_PAD = 20;		# Maneuver error pad for ACA effects (arcsec)
my $r2a = 3600. * 180. / 3.14159265;
my $faint_plot_mag = 11.0;
my $alarm = ">> WARNING:";
my $info  = ">> INFO   :";
my %Default_SIM_Z = ('ACIS-I' => 92905,
		     'ACIS-S' => 75620,
		     'HRC-I'  => -50505,
		     'HRC-S'  => -99612);
my %pg_colors = (white   => 1,
		 red     => 2,
		 green   => 3,
		 blue    => 4,
		 cyan    => 5,
		 yellow  => 7,
		 orange  => 8,
		 purple  => 12,
		 magenta => 6);


my $font_stop = qq{</font>};
my ($red_font_start, $blue_font_start, $yellow_font_start);

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
    @{$self->{yellow_warn}} = ();
    @{$self->{fyi}} = ();
    $self->{n_guide_summ} = 0;
    @{$self->{commands}} = ();
    %{$self->{agasc_hash}} = ();
#    @{$self->{agasc_stars}} = ();
    %{$self->{count_nowarn_stars}} = ();
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
##################################################################################
    my $self = shift;
    my $c = find_command($self, "MP_OBSID");
    $self->{obsid} = $c->{ID} if ($c);
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
#	print "Looking for match for maneuver to $c->{Q1} $c->{Q2} $c->{Q3} for obsid $self->{obsid} AKA $self->{dot_obsid}\n";
	$found = 0;
	foreach my $m (values %mm) {
	    my $manvr_obsid = $m->{manvr_dest};
	    # where manvr_dest is either the final_obsid of a maneuver or the eventual destination obsid
	    # of a segmented maneuver 
	    if ( ($manvr_obsid eq $self->{dot_obsid})
		 && abs($m->{q1} - $c->{Q1}) < 1e-7
		 && abs($m->{q2} - $c->{Q2}) < 1e-7
		 && abs($m->{q3} - $c->{Q3}) < 1e-7) {
#		print "Maneuver: $m->{obsid} $m->{tstop}  TARGQUAT: $self->{obsid} $self->{dot_obsid} $c->{time}\n";
#		print "  $m->{ra} $m->{dec} $m->{roll}\n";
		
		$found = 1;
		foreach (keys %{$m}) {
		    
		    $c->{$_} = $m->{$_};
		}
		
		# Set the default maneuver error (based on WS Davis data) and cap at 85 arcsec
		$c->{man_err} = (exists $c->{angle}) ? 35 + $c->{angle}/2. : 85;
		$c->{man_err} = 85 if ($c->{man_err} > 85);
		# Now check for consistency between quaternion from MANUEVER summary
		# file and the quat from backstop (MP_TARGQUAT cmd)
		
		# Get quat from MP_TARGQUAT (backstop) command.  This might have errors
		my $q4_obc = sqrt(1.0 - $c->{Q1}**2 - $c->{Q2}**2 - $c->{Q3}**2);

		# Get quat from MANEUVER summary file.  This is correct to high precision
		my $q_man = Quat->new($m->{ra}, $m->{dec}, $m->{roll});
		my $q_obc = Quat->new($c->{Q1}, $c->{Q2}, $c->{Q3}, $q4_obc);
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
#		print "$obsid found in $ms_line";
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

    $self->{or_er_start} = date2time($or_er_start);
    $self->{or_er_stop} = date2time($or_er_stop);



}


##################################################################################
sub set_fids {
#
# Find the commanded fids (if any) for this observation.
# always match those in DOT, etc
#
##################################################################################
    my $self = shift;
    my @fidsel = @_;
    my $tstart;
    my $manvr;
    $self->{fidsel} = [];  # Init to know that fids have been set and should be checked

    # Return unless there is a maneuver command and associated tstop value (from manv summ)

    return unless ($manvr = find_command($self, "MP_TARGQUAT", -1));

    return unless ($tstart = $manvr->{tstop});	# "Start" of observation = end of manuever
    
    # Loop through fidsel commands for each fid light and find any intervals
    # where fid is on at time $tstart

    for my $fid (1 .. 14) {
	foreach my $fid_interval (@{$fidsel[$fid]}) {
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

    my $obs_beg_pad = 8*60;       # Check dither status at obs start + 8 minutes to allow 
                                  # for disabled dither because of mon star commanding
    my $obs_end_pad = 3*60;
    my $manvr;

    if ( $self->{obsid} =~ /^\d*$/){
	return if ($self->{obsid} > 50000); # For eng obs, don't have OR to specify dither
    }
    unless ($manvr = find_command($self, "MP_TARGQUAT", -1) and defined $self->{DITHER_ON} and defined $manvr->{tstart}) {
	push @{$self->{warn}}, "$alarm Dither status not checked\n";
	return;
    }

    # set the observation start as the end of the maneuver
    my $obs_tstart = $manvr->{tstop};
    my $obs_tstop;

    # set the observation stop as the beginning of the next maneuever
    # or, if last obsid in load, use the processing summary or/er observation
    # stop time
    if (defined $self->{next}){
	my $next_manvr = find_command($self->{next}, "MP_TARGQUAT", -1);
	if (defined $next_manvr){
	    $obs_tstop  = $next_manvr->{tstart};
	}
	else{
	    # if the next obsid doesn't have a maneuver (ACIS undercover or whatever)
	    # just use next obsid start time
	    my $next_cmd_obsid = find_command($self->{next}, "MP_OBSID", -1);
	    if ( (defined $next_cmd_obsid) and ( $self->{obsid} != $next_cmd_obsid->{ID}) ){
		push @{$self->{warn}}, "$alarm Next obsid has no manvr; checking dither until next obsid start time \n";
		$obs_tstop = $next_cmd_obsid->{time};
	    }
	}

    }
    else{
	$obs_tstop = $self->{or_er_stop};
    }
    

    # Determine current dither status by finding the last dither commanding before 
    # the start of observation (+ 8 minutes)

    foreach my $dither (reverse @{$dthr}) {
	if ($obs_tstart + $obs_beg_pad >= $dither->{time}) {
	    my ($or_val, $bs_val) = ($dthr_cmd{$self->{DITHER_ON}}, $dither->{state});
	    push @{$self->{warn}}, "$alarm Dither mismatch - OR: $or_val != Backstop: $bs_val\n"
		if ($or_val ne $bs_val);
	    last;
	}
	elsif ( not defined $obs_tstop ){
	    push @{$self->{warn}}, "$alarm Unable to determine obs tstop; could not check for dither changes during obs\n";
	}
	elsif ( $dither->{time} > ( $obs_tstart + $obs_beg_pad ) && $dither->{time} <= $obs_tstop - $obs_end_pad ) {
	    push @{$self->{warn}}, "$alarm Dither commanding at $dither->{time}.  During observation.\n";
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
    my $mag_faint_red   = 10.6;	# Faint mag limit (red)
    my $mag_faint_yellow= 10.3;	# Faint mag limit (yellow)
    my $mag_bright      = 6.0;	# Bright mag limit 

    my $spoil_dist   = 140;	# Min separation of star from other star within $sep_mag mags
    my $spoil_mag    = 5.0;	# Don't flag if mag diff is more than this
   
    my $qb_dist      = 20;	# QB separation arcsec (3 pixels + 1 pixel of ambiguity)
   
    my $y0           = 33;	# CCD QB coordinates (arcsec)
    my $z0           = -27;
   
    my $is_science = ($self->{obsid} =~ /^\d+$/ && $self->{obsid} < 50000);
    my $is_er      = ($self->{obsid} =~ /^\d+$/ && $self->{obsid} >= 50000);
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
    if (defined $self->{DITHER_Y_AMP} and defined $self->{DITHER_Z_AMP}) {
	$dither = ($self->{DITHER_Y_AMP} > $self->{DITHER_Z_AMP} ?
		   $self->{DITHER_Y_AMP} : $self->{DITHER_Z_AMP}) * 3600.0;
    } else {
	$dither = 20.0;
    }

    my @warn = ();
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

    # if no starcat, warn and quit this subroutine
    unless ($c = find_command($self, "MP_STARCAT")) {
	if (defined $ok_no_starcat){
	    push @{$self->{fyi}}, "$info No star catalog for obsid $obsid ($oflsid). OK for '$ok_no_starcat' ER. \n";
	    return;
	}
	push @{$self->{warn}}, "$alarm No star catalog for obsid $obsid ($oflsid). \n";		    
	return;
    }

    # Reset the minimum number of guide stars if a monitor window is commanded
    $min_guide -= scalar grep { $c->{"TYPE$_"} eq 'MON' } (1..16);

    print STDERR "Checking star catalog for obsid $self->{obsid}\n";
    
    # Global checks on star/fid numbers
    
    push @warn,"$alarm Too Few Fid Lights\n" if (@{$self->{fid}} < $min_fid && $is_science);
    push @warn,"$alarm Too Many Fid Lights\n" if ( (@{$self->{fid}} > 0 && $is_er) ||
						   (@{$self->{fid}} > $min_fid && $is_science) ) ;
    push @warn,"$alarm Too Few Acquisition Stars\n" if (@{$self->{acq}} < $min_acq);
    push @warn,"$alarm Too Few Guide Stars\n" if (@{$self->{gui}} < $min_guide);
    push @warn,"$alarm Too Many GUIDE + FID\n" if (@{$self->{gui}} + @{$self->{fid}} + @{$self->{mon}} > 8);
    push @warn,"$alarm Too Many Acquisition Stars\n" if (@{$self->{acq}} > 8);
    
    # Match positions of fids in star catalog with expected, and verify a one to one 
    # correspondance between FIDSEL command and star catalog.  
    # Skip this for vehicle-only loads since fids will be turned off.
    check_fids($self, $c, \@warn) unless $vehicle;

    foreach my $i (1..16) {
	(my $sid  = $c->{"GS_ID$i"}) =~ s/[\s\*]//g;
	my $type = $c->{"TYPE$i"};
	my $yag  = $c->{"YANG$i"};
	my $zag  = $c->{"ZANG$i"};
	my $mag  = $c->{"GS_MAG$i"};
	my $maxmag = $c->{"MAXMAG$i"};
	my $halfw= $c->{"HALFW$i"};

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

       # Warn if star not identified
	if ( $type =~ /BOT|GUI|ACQ/ and not defined $c->{"GS_IDENTIFIED$i"}) {
	    push @warn, sprintf("$alarm [%2d] Missing Star. No AGASC star near search center \n", $i);
	}

	# Warn if acquisition star has non-zero aspq1
	push @yellow_warn, sprintf "$alarm [%2d] Centroid Perturbation Warning.  %s: ASPQ1 = %2d\n", 
	$i, $sid, $c->{"GS_ASPQ$i"} 
	if ($type =~ /BOT|ACQ|GUI/ && defined $c->{"GS_ASPQ$i"} && $c->{"GS_ASPQ$i"} != 0);
	
	# Bad Acquisition Star
	if ( ($type =~ /BOT|ACQ|GUI/)
	     && ($bad_acqs{$sid}{'n_noids'} && $bad_acqs{$sid}{'n_obs'} > 2  
		 && $bad_acqs{$sid}{'n_noids'}/$bad_acqs{$sid}{'n_obs'} > 0.3)){	
	    push @yellow_warn, sprintf 
		"$alarm [%2d] Bad Acquisition Star. %s has %2d failed out of %2d attempts\n",
		$i, $sid, $bad_acqs{$sid}{'n_noids'}, $bad_acqs{$sid}{'n_obs'};
	}
	 
	# Bad Guide Star
	if ( ($type =~ /BOT|GUI/)
	     && ( $bad_gui{$sid}{'n_nbad'} && $bad_gui{$sid}{'n_obs'} > 2  
		  && $bad_gui{$sid}{'n_nbad'}/$bad_gui{$sid}{'n_obs'} > 0.3)){	
	    push @yellow_warn, sprintf 
		"$alarm [%2d] Bad Guide Star. %s has bad data %2d of %2d attempts\n",
		$i, $sid, $bad_gui{$sid}{'n_nbad'}, $bad_gui{$sid}{'n_obs'};
	}
	    
	# Bad AGASC ID
	push @yellow_warn,sprintf "$alarm [%2d] Non-numeric AGASC ID.  %s\n",$i,$sid if ($sid ne '---' && $sid =~ /\D/);
	push @warn,sprintf "$alarm [%2d] Bad AGASC ID.  %s\n",$i,$sid if ($bad_id{$sid});
	
	# Set NOTES variable for marginal or bad star based on AGASC info
	$c->{"GS_NOTES$i"} = '';
	my $note = '';
	my $marginal_note = '';
	if (defined $c->{"GS_CLASS$i"}) {
	    $c->{"GS_NOTES$i"} .= 'b' if ($c->{"GS_CLASS$i"} != 0);
#	    $c->{"GS_NOTES$i"} .= 'c' if ($c->{"GS_BV$i"} == 0.700);
	    # ignore precision errors in color
	    my $color = sprintf('%.7f', $c->{"GS_BV$i"});
	    $c->{"GS_NOTES$i"} .= 'c' if ($color eq '0.7000000');
	    $c->{"GS_NOTES$i"} .= 'm' if ($c->{"GS_MAGERR$i"} > 99);
	    $c->{"GS_NOTES$i"} .= 'p' if ($c->{"GS_POSERR$i"} > 399);
	    $note = sprintf("B-V = %.3f, Mag_Err = %.2f, Pos_Err = %.2f",$c->{"GS_BV$i"},($c->{"GS_MAGERR$i"})/100,($c->{"GS_POSERR$i"})/1000) if ($c->{"GS_NOTES$i"} =~ /[cmp]/);
	    $marginal_note = sprintf("$alarm [%2d] Marginal star. %s\n",$i,$note) if ($c->{"GS_NOTES$i"} =~ /[^b]/);
	    if ( $c->{"GS_NOTES$i"} =~ /c/ && $type =~ /BOT|GUI/ ) { push @warn, $marginal_note }
	    elsif ($marginal_note) { push @yellow_warn, $marginal_note }
	    push @warn, sprintf("$alarm [%2d] Bad star.  Class = %s %s\n", $i,$c->{"GS_CLASS$i"},$note) if ($c->{"GS_NOTES$i"} =~ /b/);
	}

	# Star/fid outside of CCD boundaries

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
		
# Quandrant boundary interference
	push @yellow_warn, sprintf "$alarm [%2d] Quadrant Boundary. \n",$i 
	    unless ($type eq 'ACQ' or $type eq 'MON' or 
		    (abs($yag-$y0) > $qb_dist + $slot_dither and abs($zag-$z0) > $qb_dist + $slot_dither ));
	
	# Faint and bright limits
	if ($type ne 'MON' and $mag ne '---') {

	    if ($mag < $mag_bright or $mag > $mag_faint_red) {
		push @warn, sprintf "$alarm [%2d] Magnitude.  %6.3f\n",$i,$mag;
	    } 
	    elsif ($mag > $mag_faint_yellow) {
		push @yellow_warn, sprintf "$alarm [%2d] Magnitude.  %6.3f\n",$i,$mag;
	    }
	
	}


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
	

	# Search box too large
	if ($type ne 'MON' and $c->{"HALFW$i"} > 200) {
	    push @warn, sprintf "$alarm [%2d] Search Box Size. Search Box Too Large. \n",$i;
	}

	# ACQ/BOTH search box smaller than slew error
	if (($type =~ /BOT|ACQ/) and $c->{"HALFW$i"} < $slew_err) {
	    push @warn, sprintf "$alarm [%2d] Search Box Size. Search Box smaller than slew error \n",$i;
	}


	# Check that readout sizes are all 6x6 for science observations
	if ($is_science && $type =~ /BOT|GUI|ACQ/  && $c->{"SIZE$i"} ne "6x6"){
	  if (($c->{"SIZE$i"} eq "8x8") and ($or->{HAS_MON}) and ($c->{"IMNUM$i"} == 7 )){
	    push @{$self->{fyi}}, sprintf("$info [%2d] Readout Size. 8x8 Stealth MON?", $i);
	  }
	  else{
	    push @warn, sprintf("$alarm [%2d] Readout Size. %s Should be 6x6\n", $i, $c->{"SIZE$i"});
	  }
	}

	# Check that readout sizes are all 8x8 for engineering observations
	if ($is_er && $type =~ /BOT|GUI|ACQ/  && $c->{"SIZE$i"} ne "8x8"){
	    push @warn, sprintf("$alarm [%2d] Readout Size.  %s Should be 8x8\n", $i, $c->{"SIZE$i"});
	}
	
	# Check that readout sizes are all 8x8 for FID lights
	push @warn, sprintf("$alarm [%2d] Readout Size.  %s Should be 8x8\n", $i, $c->{"SIZE$i"})
	    if ($type =~ /FID/  && $c->{"SIZE$i"} ne "8x8");

	# Check that readout size is 8x8 for monitor windows
	push @warn, sprintf("$alarm [%2d] Readout Size. %s Should be 8x8\n", $i, $c->{"SIZE$i"})
	    if ($type =~ /MON/  && $c->{"SIZE$i"} ne "8x8");
	

	# Bad Pixels
        my @close_pixels;
        my @dr;
	if ($type ne 'ACQ' and $c->{"GS_PASS$i"} =~ /^1|\s+|g[1-2]/) {
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
	    # print STDERR "SID = $sid \n";
	    next if (  $star->{id} eq $sid || 	
		       ( abs($star->{yag} - $yag) < $ID_DIST_LIMIT 
			 && abs($star->{zag} - $zag) < $ID_DIST_LIMIT 
			 && abs($star->{mag} - $mag) < 0.1 ) );	
	    my $dy = abs($yag-$star->{yag});
	    my $dz = abs($zag-$star->{zag});
	    my $dr = sqrt($dz**2 + $dy**2);
	    my $dm = $mag ne '---' ? $mag - $star->{mag} : 0.0;
	    my $dm_string = $mag ne '---' ? sprintf("%4.1f", $mag - $star->{mag}) : '?';
	    
	    # Fid within $dither + 25 arcsec of a star (yellow) and within 4 mags (red)
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
		if ($dm > -0.2)  { push @warn, $warn }
		else { push @yellow_warn, $warn }
	    }
	    # Common column: dz within limit, spoiler is $col_sep_mag brighter than star,
	    # and spoiler is located between star and readout
	    if ($type ne 'MON'
		and $dz < $col_sep_dist
		and $dm > $col_sep_mag
		and ($star->{yag}/$yag) > 1.0 
		and abs($star->{yag}) < 2500) {
		push @warn,sprintf("$alarm [%2d] Common Column. %10d " .
				   "at Y,Z,Mag: %5d %5d %5.2f\n",$i,$star->{id},$star->{yag},$star->{zag},$star->{mag});
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
    push @{$self->{yellow_warn}}, @yellow_warn;
}

#############################################################################################
sub check_flick_pix_mon {
#############################################################################################
    my $self = shift;

    # only check ERs for these MONS
    return if ( $self->{obsid} < 50000 );

    my $c;
    # Check for existence of a star catalog
    return unless ($c = find_command($self, "MP_STARCAT"));
    
    # See if there are any monitor stars.  Return if not.
    my @mon_stars = grep { $c->{"TYPE$_"} eq 'MON' } (1..16);
    return unless (@mon_stars);

    for my $mon_star (@mon_stars){

#	map { print "$_ : ", $c->{"$_${mon_star}"}, "\n" } qw( IMNUM TYPE YANG ZANG SIZE RESTRK DIMDTS);

	push @{$self->{fyi}}, sprintf("$info Obsid contains flickering pixel MON\n", $mon_star);


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


    # if this is a real numeric obsid
    if ( $self->{obsid} =~ /^\d*$/ ){

	# Don't worry about monitor commanding for non-science observations
	return if ($self->{obsid} > 50000);
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
	  # if it doesn't match the requested location
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Monitor Window is %6.2f arc-seconds off of OR specification\n"
					 , $idx_hash{idx}, $idx_hash{sep}) 
	    if $idx_hash{sep} > 2.5;
	# if it isn't 8x8
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Size is not 8x8\n", $idx_hash{idx})
	    unless $idx_hash{size} eq "8x8";

	# if it isn't in slot 7
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Monitor Window is in slot %2d and should be in slot 7.\n"
					 , $idx_hash{idx}, $idx_hash{imnum}) 
	    if $idx_hash{imnum} != 7;
	
	push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Monitor Window is set to Convert-to-Track\n", $idx_hash{idx}) 
	  if $idx_hash{restrk} == 1;
	  

	# Verify the the designated track star is indeed a guide star.
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
	  push @{$self->{warn}}, sprintf("$alarm [%2d] Monitor Commanding. Monitor Window is %6.2f arc-seconds off of OR specification\n"
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

       
	push @{$warn}, sprintf("$alarm Fid $self->{SI} FIDSEL $fid not found within 10 arcsec of (%.1f, %.1f)\n",
			       $yag, $zag)
	    unless ($fidsel_ok);
    }
    
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
    if ( defined $self->{DITHER_ON} && $self->{obsid} < 50000 ) {
	$o .= sprintf "Dither: %-3s ",$self->{DITHER_ON};
	$o .= sprintf ("Y_amp=%4.1f  Z_amp=%4.1f  Y_period=%6.1f  Z_period=%6.1f",
		       $self->{DITHER_Y_AMP}*3600., $self->{DITHER_Z_AMP}*3600.,
		       360./$self->{DITHER_Y_FREQ}, 360./$self->{DITHER_Z_FREQ})
	    if ($self->{DITHER_ON} eq 'ON' && $self->{DITHER_Y_FREQ} && $self->{DITHER_Z_FREQ});
	$o .= "\n";
    }
    else {
#	$o .= "\n";
    }

#$file_out = "$STARCHECK/" . basename($file_in) . ".html"
#    ($self->{backstop}, $self->{guide_summ}, $self->{or_file},
#     $self->{mm_file}, $self->{dot_file}) = @_;

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
		$o .= sprintf("  MANVR: Angle= %6.2f deg  Duration= %.0f sec  Slew err= %.1f arcsec\n",
			      $c->{angle}, $c->{dur}, $c->{man_err})
		}
	    $o .= "\n";
	}
    }

    my $acq_stat_lookup = "$config{paths}->{acq_stat_query}?id=";


    if ($c = find_command($self, "MP_STARCAT")) {



	my $table;

#	my @fid_fields = qw (IMNUM GS_ID   TYPE  SIZE MINMAG GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW GS_PASS GS_NOTES);
#	my @fid_format = ( '%3d', '%12s',     '%6s',   '%5s',  '%8.3f',    '%8s',  '%8.3f',  '%7d',  '%7d',    '%4d',    '%4d',   '%5d',     '%6s',  '%4s');
	my @fid_fields = qw (TYPE  SIZE MINMAG GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW GS_PASS GS_NOTES);
	my @fid_format = ( '%6s',   '%5s',  '%8.3f',    '%8s',  '%8.3f',  '%7d',  '%7d',    '%4d',    '%4d',   '%5d',     '%6s',  '%4s');
#	my @star_fields = qw (IMNUM GS_ID GS_ID   TYPE  SIZE MINMAG GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW GS_PASS GS_NOTES);
#	my @star_format = ( '%3d', "\\link_target{${acq_stat_lookup}%s,", '%12s}',     '%6s',   '%5s',  '%8.3f',    '%8s',  '%8.3f',  '%7d',  '%7d',    '%4d',    '%4d',   '%5d',     '%6s',  '%4s');
	my @star_fields = qw (   TYPE  SIZE MINMAG GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW GS_PASS GS_NOTES);
	my @star_format = ( '%6s',   '%5s',  '%8.3f',    '%8s',  '%8.3f',  '%7d',  '%7d',    '%4d',    '%4d',   '%5d',     '%6s',  '%4s');

	$table.= sprintf "MP_STARCAT at $c->{date} (VCDU count = $c->{vcdu})\n";
	$table.= sprintf "---------------------------------------------------------------------------------------------\n";
	$table.= sprintf " IDX SLOT        ID  TYPE   SZ  MINMAG    MAG   MAXMAG   YANG   ZANG DIM RES HALFW PASS NOTES\n";
#                      [ 4]  3   971113176   GUI  6x6   5.797   7.314   8.844  -2329  -2242   1   1   25  bcmp
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
#	    $table.= "\\${color}_start " if ($color);
	    $table.= sprintf "[%2d]",$i;
#	    map { $table.= sprintf "$format[$_]", $c->{"$fields[$_]$i"} } (0 .. $#fields);
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
	    if ($db_stats->{acq} or $db_stats->{gui}){
	    $table .= sprintf("${idpad}<A HREF=\"%s%s\" STYLE=\"text-decoration: none;\" "
			      . "ONMOUSEOVER=\"return overlib ('"
			      . "ACQ total:%d noid:%d <BR />"
			      . "GUI total:%d bad:%d fail:%d obc_bad:%d <BR />"
			      . "Avg Mag %4.2f"
			      . "', WIDTH, 220);\" ONMOUSEOUT=\"return nd();\">%s</A>", 
			      $acq_stat_lookup, $c->{"GS_ID${i}"}, 
			      $db_stats->{acq}, $db_stats->{acq_noid},
			      $db_stats->{gui}, $db_stats->{gui_bad}, $db_stats->{gui_fail}, $db_stats->{gui_obc_bad},
			      $db_stats->{avg_mag},
			      $c->{"GS_ID${i}"});
	  }
	    else{
	      $table .= sprintf("${idpad}%s", $c->{"GS_ID${i}"});
	    }
	    for my $field_idx (0 .. $#fields){
		my $curr_format = $format[$field_idx];
#		if (($curr_format =~ /link_target/) and ($color)){
#		    # turn off the color before the link
#		    $curr_format = " \\${color}_end " . $curr_format;
#		}
#		if (($curr_format eq '%12s}') and ($color)){
		    # turn the color back on after the link
#		    $curr_format = $curr_format . "\\${color}_start ";
#		}
		$table .= sprintf($curr_format, $c->{"$fields[$field_idx]$i"});
	    }
	    $table.= $font_stop if ($color);
	    $table.= sprintf "\n";
	}


    $o .= $table;

    }


    
    $o .= "\n" if (@{$self->{warn}} || @{$self->{yellow_warn}} || @{$self->{fyi}} );



    if (@{$self->{warn}}) {
	$o .= "${red_font_start}";
	foreach (@{$self->{warn}}) {
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
	foreach (2..4) { $o .= "$probs[$_]\t" }
	$o .= "$font_stop" if $bad_FOM;
	$o .= "\n";
	$o .= "Acquisition Stars Expected  : $self->{figure_of_merit}->{expected}\n";
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
	else{
	    $o .= sprintf("<TD><img align=\"top\" src=\"%s/down.gif\" ></TD>", 
			  $self->{STARCHECK} );
	    $o .= sprintf("<TD>NEXT </TD>", $self->{next}->{obsid});
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
    
#    unless ($c = find_command($self, 'MP_STARCAT')) {
#	if ($self->{n_guide_summ}++ == 0) {
#	    push @{$self->{warn}}, ">> WARNING: " .
#		"Star catalog for $self->{obsid} in guide star summary, but not backstop\n";
#	}
#	return; # Bail out, since there is no starcat cmd to update
#    }

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
    my $AGASC_DIR = shift;
    my $c;
    return unless ($c = find_command($self, "MP_TARGQUAT"));
    
    my $agasc_region;
    my $agasc_method;

    eval{
	$agasc_region = Ska::AGASC->new({
	    agasc_dir => $AGASC_DIR,
	    ra => $self->{ra},
	    dec => $self->{dec},
	    radius => 1.3,
	    datetime => $self->{date},
	});
	$agasc_method = $Ska::AGASC::access_method;
    };
    if( $@ ){
	croak("Could not use AGASC: $@");
    }

    if ($agasc_method =~ /cfitsio/){
	push @{$self->{warn}}, 
	sprintf("$alarm mp_get_agasc failed! starcat not flight approved! \n");
    }

    my $q_aca = Quat->new($self->{ra}, $self->{dec}, $self->{roll});

    for my $id ($agasc_region->list_ids() )  {

	my $star = $agasc_region->get_star($id);
	
	my ($yag, $zag) = Quat::radec2yagzag(
					     $star->ra_pmcorrected(), 
					     $star->dec_pmcorrected(), 
					     $q_aca);
	$yag *= $r2a;
	$zag *= $r2a;
	if ($star->mag_aca() < -10 or $star->mag_aca_err() < -10) {
	    push @{$self->{warn}}, sprintf("$alarm Star with bad mag %.1f or magerr %.1f at (yag,zag)=%.1f,%.1f\n",
					   $star->mag_aca(), $star->mag_aca_err(), $yag, $zag);
	}
	$self->{agasc_hash}{$id} = { 
	    id=> $id, 
	    class => $star->class(),
	    ra  => $star->ra_pmcorrected(),
	    dec => $star->dec_pmcorrected(),
	    mag => $star->mag_aca(), 
	    bv  => $star->color1(),
	    magerr => $star->mag_aca_err(), 
	    poserr  => $star->pos_err(),
	    yag => $yag, 
	    zag => $zag, 
	    aspq => $star->aspq1() 
	    } ;
	
#	push @{$self->{agasc_stars}} , { id=> $id, class => $class,
#					ra  => $ra,  dec => $dec,
#					mag => $mag, bv  => $bv,
#					magerr => $magerr, poserr  => $poserr,
#					yag => $yag, zag => $zag, aspq => $aspq } ;
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

	    # let's still confirm that the backstop yag zag is what we expect
	    # from agasc and ra,dec,roll

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
	    $c->{"GS_MAGERR$i"} = $star->{magerr};
	    $c->{"GS_POSERR$i"} = $star->{poserr};
	    $c->{"GS_CLASS$i"} = $star->{class};
	    $c->{"GS_ASPQ$i"} = $star->{aspq};
	    my $db_hist = star_dbhist( "$gs_id", $obs_time );
	    $c->{"GS_USEDBEFORE$i"} =  $db_hist;
#	    print "$gs_id has used_before = $used_before \n";

	}
	else{
	    # This loop should just get the $gs_id eq '---' cases
	    foreach my $star (values %{$self->{agasc_hash}}) {
		if (abs($star->{yag} - $yag) < $ID_DIST_LIMIT
		    && abs($star->{zag} - $zag) < $ID_DIST_LIMIT) {
		    $c->{"GS_IDENTIFIED$i"} = 1;
		    $c->{"GS_BV$i"} = $star->{bv};
		    $c->{"GS_MAGERR$i"} = $star->{magerr};
		    $c->{"GS_POSERR$i"} = $star->{poserr};
		    $c->{"GS_CLASS$i"} = $star->{class};
		    $c->{"GS_ASPQ$i"} = $star->{aspq};
		    $c->{"GS_ID$i"} = "*$star->{id}";	      
		    $c->{"GS_RA$i"} = $star->{ra};
		    $c->{"GS_DEC$i"} = $star->{dec};
		    $c->{"GS_MAG$i"} = sprintf "%8.3f", $star->{mag};
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
sub plot_stars {
##  Make a plot of the field
#############################################################################################
    
    eval 'use PGPLOT';
    if ($@){
        croak(__PACKAGE__ .": !$@");
    }
    # it is OK to croak, because I catch the exception in starcheck.pl

    my $self = shift;
    my $c;
    return unless ($c = find_command($self, 'MP_STARCAT'));
    return unless ((defined $self->{ra}) and (defined $self->{dec}) and (defined $self->{roll}));
    $self->{plot_file} = shift;
    
    my %sym_type = (FID => 8,
		 BOT => 17,
		 ACQ => 17,
		 GUI => 17,
		 MON => 17,
		 field_star => 17,
		 bad_mag => 12);

    my %sym_color = (FID => 2,
		  BOT => 4,
		  ACQ => 4,
		  GUI => 3,
		  MON => 8,
		  field_star => 1);

    # Setup pgplot
    my $dev = "/vgif"; # unless defined $dev;  # "?" will prompt for device
    pgbegin(0,$dev,1,1);  # Open plot device 
    pgpap(5.0, 1.0);
    pgscf(1);             # Set character font
    pgscr(0, 1.0, 1.0, 1.0);
    pgscr(1, 0.0, 0.0, 0.0);
#    pgslw(2);
    
    # Define data limits and plot axes
    pgpage();
    pgsch(1.2);
    pgvsiz (0.5, 4.5, 0.5, 4.5);
    pgswin (2900,-2900,-2900,2900);
    pgbox  ('BCNST', 0.0, 0, 'BCNST', 0.0, 0);
    pglabel("Yag (arcsec)","Zag (arcsec)","Stars at RA=$self->{ra} Dec=$self->{dec} Roll=$self->{roll}");	# Labels
    pgtext(1900, 2975, "Yag Axis now matches SAUSAGE/SKY");
    box(0,0,2560,2560);
    box(0,0,2600,2560);

    # Plot field stars from AGASC
    foreach my $star (values %{$self->{agasc_hash}}) {
	next if ($star->{mag} > $faint_plot_mag);

	# First set defaults
	my $color = $pg_colors{red}; # By default, assume star is bad
	my $symbol = $sym_type{field_star};
	my $size = sym_size($star->{mag});

	$color = $pg_colors{magenta} if ($star->{class} == 0 and $star->{mag} >= 10.7);  # faint
	$color = $pg_colors{white}   if ($star->{class} == 0 and $star->{mag} < 10.7);   # OK
	if ($star->{mag} < -10) {                                                        # Bad mag
	    $color=$pg_colors{red};
	    $size=3.0;
	    $symbol = $sym_type{bad_mag};
	}
	    
	pgsci($color);
	pgsch($size); # Set character height
	pgpoint(1, $star->{yag}, $star->{zag}, $symbol);
    }

    # Plot fids/stars in star catalog
    for my $i (1 .. 16) {	
	next if ($c->{"TYPE$i"} eq 'NUL');
	my $mag = $c->{"GS_MAG$i"} eq '---' ? $c->{"MAXMAG$i"} - 1.5 : $c->{"GS_MAG$i"};
	pgsch(sym_size($mag)); # Set character height
	my $x = $c->{"YANG$i"};
	my $y = $c->{"ZANG$i"};
	pgsci($sym_color{$c->{"TYPE$i"}});             # Change colour
	if ($c->{"TYPE$i"} eq 'FID'){ # Make open (fid)
	    pgpoint(1, $x, $y, $sym_type{$c->{"TYPE$i"}});
	}
       	if ($c->{"TYPE$i"} =~ /(BOT|ACQ)/) {           # Plot search box
	    box($x, $y, $c->{"HALFW$i"}, $c->{"HALFW$i"});
	}
	if ($c->{"TYPE$i"} =~ /MON/) {             # Plot monitor windows double size for visibility
	    box($x, $y, $c->{"HALFW$i"}*2, $c->{"HALFW$i"}*2);
	}
	if ($c->{"TYPE$i"} =~ /(BOT|GUI)/) {           # Larger open circle for guide stars
	    pgpoint(1, $x, $y, 24);
	}
	pgsch(1.2);
	pgsci(2);
	pgtext($x-150, $y, "$i");
    }

    pgsci(8);			# Orange for size key
    my @x = (-2700, -2700, -2700, -2700, -2700);
    my @y = (2400, 2100, 1800, 1500, 1200);
    my @mag = (10, 9, 8, 7, 6);
    foreach (0..$#x) {
	pgsch(sym_size($mag[$_])); # Set character height
	pgpoint(1, $x[$_], $y[$_], $sym_type{field_star});
    }
    pgend();				# Close plot
    
    rename "pgplot.gif", $self->{plot_file};
#    print STDERR "Created star chart $self->{plot_file}\n";
}



#############################################################################################
sub plot_star_field {
##  Make a plot of the field 
##  for quick examination
#############################################################################################

    
    eval 'use PGPLOT';
    if ($@){
        croak(__PACKAGE__ .": !$@");
    }
    # it is OK to croak, because I catch the exception in starcheck.pl

    my $self = shift;
    my $c;
    return unless ($c = find_command($self, 'MP_STARCAT'));
    $self->{plot_field_file} = shift;

    my %sym_type = (
		    very_faint => -1,
		    field_star => 17,
		    bad_mag => 12);

    # Setup pgplot
    my $dev = "/vgif"; # unless defined $dev;  # "?" will prompt for device
    pgbegin(0,$dev,1,1);  # Open plot device 
    pgpap(2.7, 1.0);
    pgscf(1);             # Set character font
    pgscr(0, 1.0, 1.0, 1.0);
    pgscr(1, 0.0, 0.0, 0.0);
#   pgslw(2);
    
    # Define data limits and plot axes
    pgpage();
    pgsch(1.2);
    pgvsiz (0.2, 2.5, 0.2, 2.5);
    pgswin (2900,-2900,-2900,2900);
    pgbox  ('BCNST', 0.0, 0, 'BCNST', 0.0, 0);
#    pglabel("Yag (arcsec)","Zag (arcsec)","Stars at RA=$self->{ra} Dec=$self->{dec} Roll=$self->{roll}");	# Labels
#    box(0,0,2560,2560);
#    box(0,0,2600,2560);

    # Plot field stars from AGASC
    foreach my $star (values %{$self->{agasc_hash}}) {
	
	# First set defaults
	my $color = $pg_colors{white};
	my $symbol = $sym_type{field_star};
	my $size = sym_size($star->{mag});

	pgsci($color);
	pgsch($size); # Set character height

	if ( $star->{mag} > $faint_plot_mag ){
	    $symbol = $sym_type{very_faint};
	}
#	pgpoint(1, $star->{yag}, $star->{zag}, $symbol);
	
	pgpoint(1, $star->{yag}, $star->{zag}, $symbol);
    }

    pgend();				# Close plot
    
    rename "pgplot.gif", $self->{plot_field_file};
#    print STDERR "Created star chart $self->{plot_file}\n";
}

#############################################################################################
sub plot_compass{
#############################################################################################

    eval 'use PGPLOT';
    if ($@){
        croak(__PACKAGE__ .": !$@");
    }

    my $self = shift;
    my $c;
    return unless ($c = find_command($self, 'MP_STARCAT'));
    return unless ( (defined $self->{ra}) and (defined $self->{dec}) and (defined $self->{roll}));
    $self->{compass_file} = shift;
    
    # Setup pgplot
    my $dev = "/vgif"; # unless defined $dev;  # "?" will prompt for device
    pgbegin(0,$dev,1,1);  # Open plot device 
    pgpap(1.8, 1.0);
    pgscf(1);             # Set character font
    pgscr(0, 1.0, 1.0, 1.0);
    pgscr(1, 0.0, 0.0, 0.0);
#   pgslw(2);


    # Define data limits and plot axes
    pgpage();
    pgsch(1.2);
    pgvsiz (0.1, 1.7, 0.1, 1.7);
    pgswin (2900,-2900,-2900,2900);
    pgbox  ('BCNST', 0.0, 0, 'BCNST', 0.0, 0);



    my $q_aca = Quat->new($self->{ra}, $self->{dec}, $self->{roll});
#    use Data::Dumper;
#    print Dumper $q_aca;

    my $plotrad = 1750/3600.;
    my $testrad = 1/3600;

    my ($ra_angle, $dec_angle);
    my ($ra_diff, $dec_diff);

    # Let's walk around a circle and find the points that have the biggest decrease in
    # RA and Dec from the focus of the circle
    for my $point ( 0 ... 360){
	my $rad = ($point/360) * (2* 3.14159);
	$ra_angle = $rad if not defined $ra_angle;
	$dec_angle = $rad if not defined $dec_angle;
	my $yag = $testrad * -1 * sin($rad);
	my $zag = $testrad * cos($rad);
#	print "(yag= $yag,zag= $zag ) \n";
	my ($point_ra, $point_dec) = Quat::yagzag2radec( $yag, $zag, $q_aca);
#	print "(ra=$point_ra, dec=$point_dec) \n";
	my $point_ra_diff = $point_ra - $self->{ra};
	my $point_dec_diff = $point_dec - $self->{dec};
	$ra_diff = $point_ra_diff if not defined $ra_diff;
	$dec_diff = $point_dec_diff if not defined $dec_diff;
	if ( $point_ra_diff > $ra_diff ){
	    $ra_diff = $point_ra_diff;
	    $ra_angle = $rad;
	}
	if ($point_dec_diff > $dec_diff ){
	    $dec_diff = $point_dec_diff;
	    $dec_angle = $rad;
	}
    }

#    print "$ra_angle $dec_angle \n";
    pgarro( 0, 0, $plotrad * 3600 * -1 * sin($ra_angle), $plotrad * 3600 * cos($ra_angle) );
    pgarro( 0, 0, $plotrad * 3600 * -1 * sin($dec_angle),  $plotrad * 3600 * cos($dec_angle) );

    # pgptxt has angle increasing counter-clockwise, so let's convert to deg and flip it around
    my $text_angle = ( 360 - (( $dec_angle / (2 * 3.14159)) * 360))  ;
    my $text_offset = 200/3600.;

    pgsch(3);             # Set character font

    pgptxt( ($plotrad + $text_offset ) * 3600 * -1 * sin($ra_angle), 
	    ($plotrad + $text_offset ) * 3600 * cos($ra_angle), $text_angle, 0.5, 
	    'E' );
    pgptxt( ($plotrad + $text_offset ) * 3600 * -1 * sin($dec_angle), 
	    ($plotrad + $text_offset ) * 3600 * cos($dec_angle), $text_angle, 0.5, 
	    'N' );

#    pgline( 2, [@Nx], [@Ny] );
#    pgline( 2, @Ex, @Ey );

#    use Data::Dumper;
#    print Dumper @Nx;
#    print Dumper @Ex;




    pgend();				# Close plot
    
    rename "pgplot.gif", $self->{compass_file};


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

#############################################################################################
sub box {
#############################################################################################
    my ($x, $y, $xs, $ys) = @_;
    my @x = ($x-$xs, $x-$xs, $x+$xs, $x+$xs, $x-$xs);
    my @y = ($y-$ys, $y+$ys, $y+$ys, $y-$ys, $y-$ys);
    pgline(5, \@x, \@y);
}

#############################################################################################
sub sym_size {
#############################################################################################
    my $mag = shift;
    $mag = 10 if ($mag < -10);
    my $size = ( (0.5 - 3.0) * ($mag - 6.0) / (12.0 - 6.0) + 2.5);
    return ($size > 0.8) ? $size : 0.8;
}

###################################################################################
sub time2date {
###################################################################################
# Date format:  1999:260:03:30:01.542
    my $time = shift;
    my $t1998 = @_ ? 0.0 : 883612736.816; # 2nd argument implies Unix time not CXC time
    my $floor_time = POSIX::floor($time+$t1998);
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($floor_time);

    return sprintf ("%04d:%03d:%02d:%02d:%06.3f",
		    $year+1900, $yday+1, $hour, $min, $sec + ($time+$t1998-$floor_time));
}

###################################################################################
sub count_good_stars{
###################################################################################
    my $self=shift;
    my $c;
    my $clean_acq_count = 0;
    my $clean_gui_count = 0;
    $self->{count_nowarn_stars}{ACQ} = $clean_acq_count;
    $self->{count_nowarn_stars}{GUI} = $clean_gui_count;

    return unless ($c = find_command($self, 'MP_STARCAT'));
    for my $i (1 .. 16){
        my $type = $c->{"TYPE$i"};
        next if ($type eq 'NUL');
        next if ($type eq 'FID');
	if ($type =~ /ACQ|BOT/){
	    unless ($self->check_idx_warn($i)){
		$clean_acq_count++;
	    }
	}
	if ($type =~ /GUI|BOT/){
	    unless ($self->check_idx_warn($i)){
		$clean_gui_count++;
	    }
	}
	
    }
    $self->{count_nowarn_stars}{ACQ} = $clean_acq_count;
    $self->{count_nowarn_stars}{GUI} = $clean_gui_count;

}



###################################################################################
sub check_idx_warn{
###################################################################################

    my $self = shift;
    my $i = shift;
    my $warn_boolean = 0;

    for my $red_warn (@{$self->{warn}}){
	if ( $red_warn =~ /\[\s*$i\]/){
#	    print "match $i on $red_warn";
	    $warn_boolean = 1;
	    last;
	}
    }
    
    # and why do the next loop if we match on the first one?
    
    if ($warn_boolean){
	return $warn_boolean;
    }

    for my $yellow_warn (@{$self->{yellow_warn}}){
	if ($yellow_warn =~ /\[\s*$i\]/){
#	    print "match $i on $yellow_warn";
	    $warn_boolean = 1;
	    last;
	}
    }

    return $warn_boolean;
}
