package Obsid;

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
##################################################################################

# Library dependencies

use strict;
use warnings;
use diagnostics;
#use lib '/proj/sot/ska/lib/site_perl';
use Quat;
use Ska::ACACoordConvert;
use File::Basename;
use POSIX qw(floor);
use English;

# Set some global vars with directory locations
my $SKA = $ENV{SKA} || '/proj/sot/ska';
my $Starcheck_Share = "$ENV{SKA_SHARE}/starcheck" || "$SKA/share/starcheck";
require  "${Starcheck_Share}/figure_of_merit.pl";

# use FigureOfMerit;

# Constants

my $VERSION = '$Id$';  # '
my $ACA_MANERR_PAD = 20;		# Maneuver error pad for ACA effects (arcsec)
my $r2a = 3600. * 180. / 3.14159265;
my $faint_plot_mag = 11.0;
my $alarm = ">> WARNING:";
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

my $ID_DIST_LIMIT = 1.5;		# 1.5 arcsec box for ID'ing a star


# Actual science global structures.
my @bad_pixels;
my %odb;
my %bad_acqs;
my %bad_id;

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
    $self->{n_guide_summ} = 0;
    @{$self->{commands}} = ();
    @{$self->{agasc_stars}} = ();
    return $self;
}

##################################################################################
sub add_command {
##################################################################################
    my $self = shift;
    push @{$self->{commands}}, $_[0];
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
    open my $BP, '<', $pixel_file or return 0;
    my @tmp = <$BP>;
    my @lines = grep { /^\s+(\d|-)/ } @tmp;
    splice(@lines, 0, 2); # the first two lines are quadrant boundaries
    foreach (@lines) {
	my @line = split /;|,/, $_;
	#cut out the quadrant boundaries
	foreach my $i ($line[0]..$line[1]) {
	    foreach my $j ($line[2]..$line[3]) {
		my $pixel = {};
		my ($yag,$zag) = toAngle($i,$j);
		$pixel->{yag} = $yag;
		$pixel->{zag} = $zag;
		push @bad_pixels, $pixel;
	    }
	}
    }
    close $BP;
    print STDERR "Read ", ($#bad_pixels+1), " ACA bad pixels from $pixel_file\n";
}

##################################################################################
sub set_bad_acqs {
##################################################################################
    use RDB;
    my $rdb_file = shift;
    my $rdb = new RDB $rdb_file or warn "$rdb_file\n";
    
    my %data;
    while($rdb && $rdb->read( \%data )) { 
	$bad_acqs{ $data{'agasc_id'} }{'n_noids'} = $data{'n_noids'};
	$bad_acqs{ $data{'agasc_id'} }{'n_obs'} = $data{'n_obs'};
    }

    undef $rdb;
    return 1;

}

##################################################################################
sub set_bad_agasc {
# Read bad AGASC ID file
# one object per line: numeric id followed by commentary.
##################################################################################

    my $bad_file = shift;
    open my $BS, '<', $bad_file or return 0;
    while (<$BS>) {
	$bad_id{$1} = 1 if (/^ \s* (\d+)/x);
    }
    close $BS;

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
     $self->{mm_file}, $self->{dot_file}) = @_;
}

##################################################################################
sub set_target {
#
# Set the ra, dec, roll attributes based on target
# quaternion parameters in the target_md
#
##################################################################################
    my $self = shift;
    
    my $c = find_command($self, "MP_TARGQUAT", -1); # Find LAST TARGQUAT cmd
    ($self->{ra}, $self->{dec}, $self->{roll}) = 
	$c ? quat2radecroll($c->{Q1}, $c->{Q2}, $c->{Q3}, $c->{Q4})
	    : (0.0, 0.0, 0.0);	   

    $self->{ra} = sprintf("%.6f", $self->{ra});
    $self->{dec} = sprintf("%.6f", $self->{dec});
    $self->{roll} = sprintf("%.6f", $self->{roll});

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
#	print "Looking for match for maneuver to $c->{Q1} $c->{Q2} $c->{Q3} for obsid $self->{obsid}\n";
	$found = 0;
	foreach my $m (values %mm) {
	    (my $manvr_obsid = $m->{obsid}) =~ s/!//g;  # Manvr obsid can have some '!'s attached for uniqness
	    if ($manvr_obsid eq $self->{dot_obsid}
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
sub set_fids {
#
# Find the commanded fids (if any) for this observation.
# always match those in DOT, etc
#
##################################################################################
    my $self = shift;
    my @fidsel = @_;
    my $tstart;
    my $c;
    $self->{fidsel} = [];  # Init to know that fids have been set and should be checked

    # Return unless there is a maneuver command and associated tstop value (from manv summ)

    return unless ($c = find_command($self, "MP_TARGQUAT", -1));
    return unless ($tstart = $c->{tstop});	# "Start" of observation = end of manuever
    
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
    my $c;

    return if ($self->{obsid} > 50000); # For eng obs, don't have OR to specify dither
    unless ($c = find_command($self, "MP_TARGQUAT", -1) and defined $self->{DITHER_ON}) {
	push @{$self->{warn}}, "$alarm Dither status not checked\n";
	return;
    }
        
    my $obs_tstart = $c->{tstop};
    my $obs_tstop  = $c->{tstop} + $c->{dur};

    # Determine current dither status by finding the last dither commanding before 
    # the start of observation (+ 8 minutes)
    
    foreach my $dither (reverse @{$dthr}) {
	if ($obs_tstart + $obs_beg_pad >= $dither->{time}) {
	    my ($or_val, $bs_val) = ($dthr_cmd{$self->{DITHER_ON}}, $dither->{state});
	    push @{$self->{warn}}, "$alarm Dither mismatch - OR: $or_val != Backstop: $bs_val\n"
	      if ($or_val ne $bs_val);
	    last;
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
    my $c;
    
    return unless (exists $self->{SIM_OFFSET_Z});
    unless ($c = find_command($self, "MP_TARGQUAT", -1)) {
	push @{$self->{warn}}, "$alarm Missing MP_TARGQUAT cmd\n";
	return;
    }

    # Set the expected SIM Z position (steps)
    my $sim_z = $Default_SIM_Z{$self->{SI}} + $self->{SIM_OFFSET_Z};

    foreach my $st (reverse @sim_trans) {
	if ($c->{tstop} >= $st->{time}) {
	    my %par = Parse_CM_File::parse_params($st->{params});
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

#############################################################################################
sub check_star_catalog {
#############################################################################################
    my $self = shift;
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

    # Set slew error (arcsec) for this obsid, or 120 if not available
    my $targquat = find_command($self, "MP_TARGQUAT", -1);
    my $slew_err = $targquat->{man_err} || 120;

    my @warn = ();
    my @yellow_warn = ();
    
    unless ($c = find_command($self, "MP_STARCAT")) {
	push @{$self->{warn}}, "$alarm No star catalog\n";
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
    # correspondance between FIDSEL command and star catalog
    check_fids($self, $c, \@warn);
    


    foreach my $i (1..16) {
	(my $sid  = $c->{"GS_ID$i"}) =~ s/[\s\*]//g;
	my $type = $c->{"TYPE$i"};
	my $yag  = $c->{"YANG$i"};
	my $zag  = $c->{"ZANG$i"};
	my $mag  = $c->{"GS_MAG$i"};
	my $maxmag = $c->{"MAXMAG$i"};
	my $halfw= $c->{"HALFW$i"};
	# Search error for ACQ is the slew error, for fid, guide or mon it is about 4 arcsec
	my $search_err = ($type =~ /BOT|ACQ/) ? $slew_err : 4.0;
	
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

	# Warn if acquisition star has non-zero aspq1
	push @yellow_warn, sprintf "$alarm Centroid Perturbation Warning. [%2d]- %s: ASPQ1 = %2d\n", 
	$i, $sid, $c->{"GS_ASPQ$i"} 
	if ($type =~ /BOT|ACQ|GUI/ && defined $c->{"GS_ASPQ$i"} && $c->{"GS_ASPQ$i"} != 0);
	
	# Bad Acquisition Star
	push @yellow_warn, sprintf 
	    "$alarm Bad Acquisition Star. [%2d]: %s has %2d failed out of %2d attempts\n",
	    $i, $sid, $bad_acqs{$sid}{'n_noids'}, $bad_acqs{$sid}{'n_obs'} 
	if ($bad_acqs{$sid}{'n_noids'} && $bad_acqs{$sid}{'n_obs'} > 2  
	    && $bad_acqs{$sid}{'n_noids'}/$bad_acqs{$sid}{'n_obs'} > 0.3);	
	
	# Bad AGASC ID
	push @yellow_warn,sprintf "$alarm Non-numeric AGASC ID. [%2d]: %s\n",$i,$sid if ($sid ne '---' && $sid =~ /\D/);
	push @warn,sprintf "$alarm Bad AGASC ID. [%2d]: %s\n",$i,$sid if ($bad_id{$sid});
	
	# Set NOTES variable for marginal or bad star based on AGASC info
	$c->{"GS_NOTES$i"} = '';
	my $note = '';
	my $marginal_note = '';
	if (defined $c->{"GS_CLASS$i"}) {
	    $c->{"GS_NOTES$i"} .= 'b' if ($c->{"GS_CLASS$i"} != 0);
	    $c->{"GS_NOTES$i"} .= 'c' if ($c->{"GS_BV$i"} == 0.700);
	    $c->{"GS_NOTES$i"} .= 'm' if ($c->{"GS_MAGERR$i"} > 99);
	    $c->{"GS_NOTES$i"} .= 'p' if ($c->{"GS_POSERR$i"} > 399);
	    $note = sprintf("B-V = %.3f, Mag_Err = %.2f, Pos_Err = %.2f",$c->{"GS_BV$i"},($c->{"GS_MAGERR$i"})/100,($c->{"GS_POSERR$i"})/1000) if ($c->{"GS_NOTES$i"} =~ /[cmp]/);
	    $marginal_note = sprintf("$alarm Marginal star. [%2d]: %s\n",$i,$note) if ($c->{"GS_NOTES$i"} =~ /[^b]/);
	    if ( $c->{"GS_NOTES$i"} =~ /c/ && $type =~ /BOT|GUI/ ) { push @warn, $marginal_note }
	    elsif ($marginal_note) { push @yellow_warn, $marginal_note }
	    push @warn, sprintf("$alarm Bad star. [%2d]: Class = %s %s\n", $i,$c->{"GS_CLASS$i"},$note) if ($c->{"GS_NOTES$i"} =~ /b/);
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
		push @warn, sprintf "$alarm Angle Off CCD. [%2d]\n",$i;
	    }
	    else {
		push @warn, sprintf "$alarm Boundary Checks failed on [%2d]! toPixels() said: $@ \n";
	    }
	}
	else{
	    if (   $pixel_row > $row_max - $pix_slot_dither || $pixel_row < $row_min + $pix_slot_dither
		   || $pixel_col > $col_max - $pix_slot_dither || $pixel_col < $col_min + $pix_slot_dither) {
    		push @warn,sprintf "$alarm Angle Too Large. [%2d]\n",$i;
	    }
	}	
	
	# Quandrant boundary interference
	push @yellow_warn, sprintf "$alarm Quadrant Boundary. [%2d]\n",$i 
	    unless ($type eq 'ACQ' or $type eq 'MON' or 
		    (abs($yag-$y0) > $qb_dist + $slot_dither and abs($zag-$z0) > $qb_dist + $slot_dither ));
	
	# Faint and bright limits
	if ($type ne 'MON' and $mag ne '---') {

	    if ($mag < $mag_bright or $mag > $mag_faint_red) {
		push @warn, sprintf "$alarm Magnitude. [%2d]: %6.3f\n",$i,$mag;
	    } 
	    elsif ($mag > $mag_faint_yellow) {
		push @yellow_warn, sprintf "$alarm Magnitude. [%2d]: %6.3f\n",$i,$mag;
	    }
	
	}


	if ($type =~ /BOT|GUI|ACQ/){
	    if (($maxmag - $mag) < $mag_faint_slot_diff){
		my $slot_diff = $maxmag - $mag;
		push @warn, sprintf "$alarm Magnitude. [%2d] MAXMAG - MAG = %1.2f < $mag_faint_slot_diff \n",$i,$slot_diff;
	    }
	}
	

	# Search box too large
	if ($type ne 'MON' and $c->{"HALFW$i"} > 200) {
	    push @warn, sprintf "$alarm Search Box Too Large. [%2d]\n",$i;
	}

	# ACQ/BOTH search box smaller than slew error
	if (($type =~ /BOT|ACQ/) and $c->{"HALFW$i"} < $slew_err) {
	    push @warn, sprintf "$alarm Search Box smaller than slew error [%2d]\n",$i;
	}

	# Check that readout sizes are all 6x6 for science observations
	
	if ($is_science && $type =~ /BOT|GUI|ACQ/  && $c->{"SIZE$i"} ne "6x6"){
	    # if BOT or GUI, in slot 7, with 8x8 box,  and close to center of CCD 
	    if ( ($type =~ /BOT|GUI/) && ($c->{"IMNUM$i"} == 7) && ($c->{"SIZE$i"} eq "8x8")
		      && (abs($c->{"YANG$i"}) < $mon_expected_ymax) 
              && (abs($c->{"ZANG$i"}) < $mon_expected_zmax)){
 	    	push @warn, sprintf("$alarm Readout Size. [%2d]: %s Should be 6x6.  Slot 7, Near Center... is this also a MON?\n", $i, $c->{"SIZE$i"});
	        push @warn, sprintf("$alarm (Continued)   [%2d]: If so, has Magnitude been checked?\n", $i);
	    }
	    else{
		push @warn, sprintf("$alarm Readout Size. [%2d]: %s Should be 6x6\n", $i, $c->{"SIZE$i"});
	    }
	}

	# Check that readout sizes are all 8x8 for engineering observations
	if ($is_er && $type =~ /BOT|GUI|ACQ/  && $c->{"SIZE$i"} ne "8x8"){
	    push @warn, sprintf("$alarm Readout Size. [%2d]: %s Should be 8x8\n", $i, $c->{"SIZE$i"});
	}
	
	# Check that readout sizes are all 8x8 for FID lights
	push @warn, sprintf("$alarm Readout Size. [%2d]: %s Should be 8x8\n", $i, $c->{"SIZE$i"})
	    if ($type =~ /FID/  && $c->{"SIZE$i"} ne "8x8");

	# Check that readout size is 8x8 for monitor windows
	push @warn, sprintf("$alarm Readout Size. [%2d]: %s Should be 8x8\n", $i, $c->{"SIZE$i"})
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
		my $warn = sprintf("$alarm Nearby ACA bad pixel. [%2d] - " .
				   "Y,Z,Radial seps: " . $close_pixels[$closest],
				   $i); #Only warn for the closest pixel
		push @warn, $warn;
	    }
	}
	
	# Spoiler star (for search) and common column
	
	foreach my $star (@{$self->{agasc_stars}}) {
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
		my $warn = sprintf("$alarm Fid spoiler. [%2d]- %10d: " .
				   "Y,Z,Radial,Mag seps: %3d %3d %3d %4s\n",$i,$star->{id},$dy,$dz,$dr,$dm_string);
		if ($dm > -4.0)  { push @warn, $warn } 
		else { push @yellow_warn, $warn }
	    }
	    
	    # Star within search box + search error and within 1.0 mags
	    if ($type ne 'MON' and $dz < $halfw + $search_err and $dy < $halfw + $search_err and $dm > -1.0) {
		my $warn = sprintf("$alarm Search spoiler. [%2d]- %10d: " .
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
		push @warn,sprintf("$alarm Common Column. [%2d] - %10d " .
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

    # Don't worry about monitor commanding for non-science observations
    return if ($self->{obsid} > 50000);

    # Check for existence of a star catalog
    return unless ($c = find_command($self, "MP_STARCAT"));

    # See if there are any monitor stars.  Return if not.
    my @mon_stars = grep { $c->{"TYPE$_"} eq 'MON' } (1..16);
    return unless (@mon_stars);

    # Check that the commanded monitor stars agree in position with the OR specification
    my $q_aca = Quat->new($self->{ra}, $self->{dec}, $self->{roll});
    my ($yag, $zag) = Quat::radec2yagzag($or->{MON_RA}, $or->{MON_DEC}, $q_aca);
    foreach (@mon_stars) {
	push @{$self->{warn}}, sprintf("$alarm Monitor Window [%2d] is in slot %2d and should be in slot 7.\n"
				       , $_, $c->{"IMNUM$_"}) if $c->{"IMNUM$_"} != 7;
	my $y_sep = $yag*$r2a - $c->{"YANG$_"};
	my $z_sep = $zag*$r2a - $c->{"ZANG$_"};
	my $sep = sqrt($y_sep**2 + $z_sep**2);
	push @{$self->{warn}}, sprintf("$alarm Monitor Window [%2d] is %6.2f arc-seconds off of OR specification\n"
				       , $_, $sep) if $sep > 2.5;
	my $track = $c->{"RESTRK$_"};
	push @{$self->{warn}}, sprintf("$alarm Monitor Window [%2d] is set to Convert-to-Track\n"
				       , $_) if $track == 1;
	# Verify the the designated track star is indeed a guide star.
	my $dts_slot =  $c->{"DIMDTS$_"};
	my $dts_type = "NULL";
	foreach my $dts_index (1..16) {
	    next unless $c->{"IMNUM$dts_index"} == $dts_slot and $c->{"TYPE$dts_index"} =~ /GUI|BOT/;
	    $dts_type = $c->{"TYPE$dts_index"};
	    last;
	}
	push @{$self->{warn}}, sprintf("$alarm DTS for [%2d] is set to slot %2d which does not contain a guide star.\n", 
				       $_, $dts_slot) if $dts_type =~ /NULL/;
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
	my %param = Parse_CM_File::parse_params($bs->{params});
	next unless ($param{TLMSID} =~ /^AO/);
	foreach $cmd (keys %dt) {
	    $cnt{$cmd}++ if ($param{TLMSID} eq $cmd and
			     abs($bs->{time} - ($t_manv+$dt{$cmd})) < $time_tol);
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

	push @{$warn}, "$alarm Fid $self->{SI} $fid is turned on with FIDSEL but not found in star catalog\n"
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
#    @sizes = qw (4x4 6x6 8x8);
#    @types = qw (ACQ GUI BOT FID MON);


    $o .= sprintf "\\target{obsid$self->{obsid}}";
    $o .= sprintf ("\\blue_start OBSID: %-5s  ", $self->{obsid});
    $o .= sprintf ("%-22s %-6s SIM Z offset:%-5d (%-.2fmm) Grating: %-5s", $target_name, $self->{SI}, 
		   $self->{SIM_OFFSET_Z},  ($self->{SIM_OFFSET_Z})*1000*($odb{"ODB_TSC_STEPS"}[0]), $self->{GRATING}) if ($target_name);
    $o .= sprintf "\\blue_end     \n";
    $o .= sprintf "RA, Dec, Roll (deg): %12.6f %12.6f %12.6f\n", $self->{ra}, $self->{dec}, $self->{roll};
    if ( defined $self->{DITHER_ON} && $self->{obsid} < 50000 ) {
	$o .= sprintf "Dither: %-3s ",$self->{DITHER_ON};
	$o .= sprintf ("Y_amp=%4.1f  Z_amp=%4.1f  Y_period=%6.1f  Z_period=%6.1f",
		       $self->{DITHER_Y_AMP}*3600., $self->{DITHER_Z_AMP}*3600.,
		       360./$self->{DITHER_Y_FREQ}, 360./$self->{DITHER_Z_FREQ})
	    if ($self->{DITHER_ON} eq 'ON' && $self->{DITHER_Y_FREQ} && $self->{DITHER_Z_FREQ});
	$o .= sprintf "\n";
    }

#$file_out = "$STARCHECK/" . basename($file_in) . ".html"
#    ($self->{backstop}, $self->{guide_summ}, $self->{or_file},
#     $self->{mm_file}, $self->{dot_file}) = @_;

    $o .= "\\link_target{$self->{STARCHECK}/" . basename($self->{backstop}) . ".html#$self->{obsid},BACKSTOP} ";
    $o .= "\\link_target{$self->{STARCHECK}/" . basename($self->{guide_summ}) . ".html#$self->{obsid},GUIDE_SUMM} ";
    $o .= "\\link_target{$self->{STARCHECK}/" . basename($self->{or_file}) . ".html#$self->{obsid},OR} " 
	if ($self->{or_file});
    $o .= "\\link_target{$self->{STARCHECK}/" . basename($self->{mm_file}) . ".html#$self->{dot_obsid},MANVR} ";
    $o .= "\\link_target{$self->{STARCHECK}/" . basename($self->{dot_file}) . ".html#$self->{obsid},DOT} ";
    $o .= "\\link_target{$self->{STARCHECK}/" . "make_stars.txt"            . ".html#$self->{obsid},MAKE_STARS} ";
    $o .= sprintf "\n\n";
    for my $n (1 .. 10) {		# Allow for multiple TARGQUAT cmds, though 2 is the typical limit
	if ($c = find_command($self, "MP_TARGQUAT", $n)) {
	    $o .= sprintf "MP_TARGQUAT at $c->{date} (VCDU count = $c->{vcdu})\n";
	    $o .= sprintf "  Q1,Q2,Q3,Q4: %.8f  %.8f  %.8f  %.8f\n", $c->{Q1}, $c->{Q2}, $c->{Q3}, $c->{Q4};
	    $o .= sprintf("  MANVR: Angle= %6.2f deg  Duration= %.0f sec  Slew err= %.1f arcsec\n",
			  $c->{angle}, $c->{dur}, $c->{man_err})
		if (exists $c->{man_err} and exists $c->{dur} and exists $c->{angle});
	    $o .= "\n";
	}
    }
    if ($c = find_command($self, "MP_STARCAT")) {
	my @cat_fields = qw (IMNUM GS_ID    TYPE  SIZE MINMAG GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW GS_PASS GS_NOTES);
	my @cat_format = qw (  %3d  %12s     %6s   %5s  %8.3f    %8s  %8.3f  %7d  %7d    %4d    %4d   %5d     %6s  %4s);

	$o .= sprintf "MP_STARCAT at $c->{date} (VCDU count = $c->{vcdu})\n";
	$o .= sprintf "----------------------------------------------------------------------------------------\n";
	$o .= sprintf " IDX SLOT        ID  TYPE   SZ  MINMAG    MAG   MAXMAG   YANG   ZANG DIM RES HALFW NOTES\n";
#                      [ 4]  3   971113176   GUI  6x6   5.797   7.314   8.844  -2329  -2242   1   1   25  bcmp
	$o .= sprintf "----------------------------------------------------------------------------------------\n";
	
	
	foreach my $i (1..16) {
	    next if ($c->{"TYPE$i"} eq 'NUL');

	    # Define the color of output star catalog line based on NOTES:
	    #   Yellow if NOTES is non-trivial. 
	    #   Red if NOTES has a 'b' for bad class or if a guide star has bad color.
	    my $color = ($c->{"GS_NOTES$i"} =~ /\S/) ? 'yellow' : '';
	    $color = 'red' if ($c->{"GS_NOTES$i"} =~ /b/ || ($c->{"GS_NOTES$i"} =~ /c/ && $c->{"TYPE$i"} =~ /GUI|BOT/));
	    
	    $o .= "\\${color}_start " if ($color);
	    $o .= sprintf "[%2d]",$i;
	    map { $o .= sprintf "$cat_format[$_]", $c->{"$cat_fields[$_]$i"} } (0 .. $#cat_fields);
	    $o .= "\\${color}_end " if ($color);
	    $o .= sprintf "\n";
	}
    }
    $o .= "\n" if (@{$self->{warn}} || @{$self->{yellow_warn}});
    if (@{$self->{warn}}) {
	$o .= "\\red_start\n";
	foreach (@{$self->{warn}}) {
	    $o .= $_;
	}
	$o .= "\\red_end ";
    }
    if (@{$self->{yellow_warn}}) {
	$o .= "\\yellow_start ";
	foreach (@{$self->{yellow_warn}}) {
	    $o .= $_;
	}
	$o .= "\\yellow_end\n";
    }
    $o .= "\n";
    if (exists $self->{figure_of_merit}) {
	my @probs = @{ $self->{figure_of_merit}->{cum_prob}};
	my $bad_FOM = $self->{figure_of_merit}->{cum_prob_bad};
	$o .= "\\red_start " if $bad_FOM;
	$o .= "Probability of acquiring 2,3, and 4 or fewer stars (10^x):\t";
	foreach (2..4) { $o .= "$probs[$_]\t" };
	$o .= "\n";
	$o .= "\\red_end " if $bad_FOM;
	$o .= "Acquisition Stars Expected  : $self->{figure_of_merit}->{expected}\n";
    }
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

    $c = find_command($self, 'MP_STARCAT');
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
    # Run mp_get_agasc to get field stars
    my $self = shift;
    my $mp_agasc_version = shift;

    my $mp_get_agasc = "mp_get_agasc -r $self->{ra} -d $self->{dec} -w 1.0";
    my @stars = `$mp_get_agasc`;
    my $q_aca = Quat->new($self->{ra}, $self->{dec}, $self->{roll});

    foreach (@stars) {
	s/-/ -/g;
	my @flds = split;
	
	# AGASC 1.4 and 1.5 are related (one-to-one) with different versions of mp_get_agasc
	# which have different output formats.  Choose the right one based on AGASC version:
	my ($id, $ra, $dec, $poserr, $mag, $magerr, $bv, $class, $aspq) 
	    =($mp_agasc_version eq '1.4') ?
	    ( @flds[0..3,7..10], "0") : @flds[0..3,12,13,19,14,30];
	my ($yag, $zag) = Quat::radec2yagzag($ra, $dec, $q_aca);
	$yag *= $r2a;
	$zag *= $r2a;
	if ($mag < -10 or $magerr < -10) {
	    push @{$self->{warn}}, sprintf("$alarm Star with bad mag %.1f or magerr %.1f at (yag,zag)=%.1f,%.1f\n",
					   $mag, $magerr, $yag, $zag);
	}
	push @{$self->{agasc_stars}}, { id => $id, class => $class,
					ra  => $ra,  dec => $dec,
					mag => $mag, bv  => $bv,
					magerr => $magerr, poserr  => $poserr,
					yag => $yag, zag => $zag, aspq => $aspq } ;
    }
}

#############################################################################################
sub identify_stars {
#############################################################################################
    my $self = shift;
    return unless (my $c = find_command($self, 'MP_STARCAT'));

    for my $i (1 .. 16) {
	next if ($c->{"TYPE$i"} eq 'NUL');
	my $yag = $c->{"YANG$i"};
	my $zag = $c->{"ZANG$i"};
	
	foreach my $star (@{$self->{agasc_stars}}) {
	    if (abs($star->{yag} - $yag) < $ID_DIST_LIMIT
		&& abs($star->{zag} - $zag) < $ID_DIST_LIMIT) {
		$c->{"GS_BV$i"} = $star->{bv};
		$c->{"GS_MAGERR$i"} = $star->{magerr};
		$c->{"GS_POSERR$i"} = $star->{poserr};
		$c->{"GS_CLASS$i"} = $star->{class};
		$c->{"GS_ASPQ$i"} = $star->{aspq};
		last unless ($c->{"GS_ID$i"} eq '---');
		$c->{"GS_ID$i"} = "*$star->{id}";
		$c->{"GS_RA$i"} = $star->{ra};
		$c->{"GS_DEC$i"} = $star->{dec};
		$c->{"GS_MAG$i"} = sprintf "%8.3f", $star->{mag};
		$c->{"GS_YANG$i"} = $star->{yag};
		$c->{"GS_ZANG$i"} = $star->{zag};
		last;
	    }
	}
    }
}

#############################################################################################
sub plot_stars {
##  Make a plot of the field
#############################################################################################
    use PGPLOT;

    my $self = shift;
    my $c;
    return unless ($c = find_command($self, 'MP_STARCAT'));
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
    pgswin (-2900,2900,-2900,2900);
    pgbox  ('BCNST', 0.0, 0, 'BCNST', 0.0, 0);
    pglabel("Yag (arcsec)","Zag (arcsec)","Stars at RA=$self->{ra} Dec=$self->{dec} Roll=$self->{roll}");	# Labels
    box(0,0,2560,2560);
    box(0,0,2600,2560);

    # Plot field stars from AGASC
    foreach my $star (@{$self->{agasc_stars}}) {
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
	pgpoint(1, $x, $y, $sym_type{$c->{"TYPE$i"}}) if ($c->{"TYPE$i"} eq 'FID'); # Make open (fid)
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
	pgtext($x+150, $y, "$i");
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

    use PGPLOT;

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
    pgswin (-2900,2900,-2900,2900);
    pgbox  ('BCNST', 0.0, 0, 'BCNST', 0.0, 0);
#    pglabel("Yag (arcsec)","Zag (arcsec)","Stars at RA=$self->{ra} Dec=$self->{dec} Roll=$self->{roll}");	# Labels
#    box(0,0,2560,2560);
#    box(0,0,2600,2560);

    # Plot field stars from AGASC
    foreach my $star (@{$self->{agasc_stars}}) {
	
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
    my $floor_time = floor($time+$t1998);
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($floor_time);

    return sprintf ("%04d:%03d:%02d:%02d:%06.3f",
		    $year+1900, $yday+1, $hour, $min, $sec + ($time+$t1998-$floor_time));
}
