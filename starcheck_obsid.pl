package Obsid;

##***************************************************************************
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
# History:
#   9-May-00: Added catalog index label, changed plot order of catalog
#             and field stars
#  11-May-01: Added bad AGASCID check (RAC)
# 
##***************************************************************************

# Library dependencies

use lib '/proj/rad1/ska/lib/perl5/local';
use Quat;
use File::Basename;
use POSIX qw(floor);

# Constants

$VERSION = '$Id$';  # '
$r2a = 3600. * 180. / 3.14159265;
$faint_plot_mag = 11.0;
$alarm = ">> WARNING:";
%Default_SIM_Z = ('ACIS-I' => 92905,
		  'ACIS-S' => 75620,
		  'HRC-I'  => -50505,
		  'HRC-S'  => -99612);


1;

sub new {
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

sub add_command {
    my $self = shift;
    push @{$self->{commands}}, $_[0];
}

sub set_odb {
# Import %odb variable into starcheck_obsid package
    %odb = @_;
    $odb{"ODB_TSC_STEPS"}[0] =~ s/D/E/;
}


sub set_bad_agasc {
# Read bad AGASC ID file
# one object per line: numeric id followed by commentary.

    my $bad_file = shift;
    open BS, $bad_file or return 0;
    while (<BS>) {
	$bad_id{$1} = 1 if (/\s*(\d+)/);
    }
    close BS;

    print STDERR "Read ",(scalar keys %bad_id) ," bad AGASC IDs from $bad_file\n";
    return 1;
}


sub set_obsid {
    my $self = shift;
    my $c = find_command($self, "MP_OBSID");
    $self->{obsid} = $c->{ID} if ($c);
}

sub print_cmd_params {
    my $self = shift;
    foreach $cmd (@{$self->{commands}}) {
	print "  CMD = $cmd->{cmd}\n";
	foreach $param (keys %{$cmd}) {
	    print  "   $param = $cmd->{$param}\n";
	}
    }
}

sub set_files {
    my $self = shift;
    ($self->{STARCHECK}, $self->{backstop}, $self->{guide_summ}, $self->{or_file},
     $self->{mm_file}, $self->{dot_file}) = @_;
}

sub set_target {
#
# Set the ra, dec, roll attributes based on target
# quaternion parameters in the target_cmd
#
    my $self = shift;

    $c = find_command($self, "MP_TARGQUAT", -1); # Find LAST TARGQUAT cmd
    ($self->{ra}, $self->{dec}, $self->{roll}) = 
	$c ? quat2radecroll($c->{Q1}, $c->{Q2}, $c->{Q3}, $c->{Q4})
	    : (0.0, 0.0, 0.0);	   

    $self->{ra} = sprintf("%.6f", $self->{ra});
    $self->{dec} = sprintf("%.6f", $self->{dec});
    $self->{roll} = sprintf("%.6f", $self->{roll});
}

sub radecroll {
    my $self = shift;
    if (@_) {
	my $target = shift;
	($self->{ra}, $self->{dec}, $self->{roll}) =
	    quat2radecroll($target->{Q1}, $target->{Q2}, $target->{Q3}, $target->{Q4});
    }
    return ($self->{ra}, $self->{dec}, $self->{roll});
}

	    
sub find_command {
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

sub set_maneuver {
#
# Find the right obsid for each maneuver.  Note that obsids in mm_file don't
# always match those in DOT, etc
#
    my $self = shift;
    my %mm = @_;
    my $n = 1;
    while ($c = find_command($self, "MP_TARGQUAT", $n++)) {
#	print "Looking for match for maneuver to $c->{Q1} $c->{Q2} $c->{Q3} for obsid $self->{obsid}\n";
	$found = 0;
	foreach $m (values %mm) {
	    ($manvr_obsid = $m->{obsid}) =~ s/!//g;  # Manvr obsid can have some '!'s attached for uniqness
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

		# Now check for consistency between quaternion from MANUEVER summary
		# file and the quat from backstop (MP_TARGQUAT cmd)

		# Get quat from MP_TARGQUAT (backstop) command.  This might have errors
		$q4_obc = sqrt(1.0 - $c->{Q1}**2 - $c->{Q2}**2 - $c->{Q3}**2);

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
sub set_fids {
#
# Find the commanded fids (if any) for this observation.
# always match those in DOT, etc
#
##################################################################################
    my $self = shift;
    my @fidsel = @_;
    $self->{fidsel} = [];  # Init to know that fids have been set and should be checked

    return unless ($c = find_command($self, "MP_TARGQUAT", -1));
    
    my $tstart = $c->{tstop};	# "Start" of observation = end of manuever
    
    # Loop through fidsel commands for each fid light and find any intervals
    # where fid is on at time $tstart

    for $fid (1 .. 14) {
	foreach $fid_interval (@{$fidsel[$fid]}) {
	    if ($fid_interval->{tstart} <= $tstart &&
		(! exists $fid_interval->{tstop} || $tstart <= $fid_interval->{tstop}) ) {
		push @{$self->{fidsel}}, $fid;
		last;
	    }
	}
    }

}

sub set_star_catalog {
    my $self = shift;
    my @sizes = qw (4x4 6x6 8x8);
    my @types = qw (ACQ GUI BOT FID MON);
    my $r2a = 180. * 3600. / 3.14159265;
    my $c;

    return unless ($c = find_command($self, "MP_STARCAT"));
	
    @{$self->{fid}} = ();
    @{$self->{gui}} = ();
    @{$self->{acq}} = ();

    foreach $i (1..16) {
	$c->{"SIZE$i"} = $sizes[$c->{"IMGSZ$i"}];
	$c->{"MAG$i"} = ($c->{"MINMAG$i"} + $c->{"MAXMAG$i"})/2;
	$c->{"TYPE$i"} = ($c->{"TYPE$i"} or $c->{"MINMAG$i"} != 0 or $c->{"MAXMAG$i"} != 0)? 
	    $types[$c->{"TYPE$i"}] : 'NUL';
	push @{$self->{fid}},$i if ($c->{"TYPE$i"} eq 'FID');
	push @{$self->{acq}},$i if ($c->{"TYPE$i"} eq 'ACQ' or $c->{"TYPE$i"} eq 'BOT');
	push @{$self->{gui}},$i if ($c->{"TYPE$i"} eq 'GUI' or $c->{"TYPE$i"} eq 'BOT');
	$c->{"YANG$i"} *= $r2a;
	$c->{"ZANG$i"} *= $r2a;
	$c->{"HALFW$i"} = ($c->{"TYPE$i"} ne 'NUL')? 
	    ( 40 - 35*$c->{"RESTRK$i"} ) * $c->{"DIMDTS$i"} + 20 : 0;
	$c->{"YMAX$i"} = $c->{"YANG$i"} + $c->{"HALFW$i"};
	$c->{"YMIN$i"} = $c->{"YANG$i"} - $c->{"HALFW$i"};
	$c->{"ZMAX$i"} = $c->{"ZANG$i"} + $c->{"HALFW$i"};
	$c->{"ZMIN$i"} = $c->{"ZANG$i"} - $c->{"HALFW$i"};

	# Fudge in values for guide star summary, in case it isn't there
	$c->{"GS_ID$i"} = '---';	
	$c->{"GS_MAG$i"} = '---';
	$c->{"GS_YANG$i"} = 0;
	$c->{"GS_ZANG$i"} = 0;
    }
}

sub check_sim_position {
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

    foreach $st (reverse @sim_trans) {
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

sub check_star_catalog {
    my $self = shift;
    my $c;

    ########################################################################
    # Constants used in star catalog checks
    my $y_ang_min    =-2410;	# CCD boundaries in arcsec
    my $y_ang_max    = 2473;
    my $z_ang_min    =-2504;
    my $z_ang_max    = 2450;

    my $col_sep_dist = 50;	# Common column pixel separation
    my $col_sep_mag  = 4.5;	# Common column mag separation (from ODB_MIN_COL_MAG_G)

    my $mag_faint    = 10.2;	# Faint mag limit
    my $mag_bright   = 6.0;	# Bright mag limit 

    my $spoil_dist   = 140;	# Min separation of star from other star within $sep_mag mags
    my $spoil_mag    = 5.0;	# Don't flag if mag diff is more than this
   
    my $qb_dist      = 20;	# QB separation arcsec (3 pixels + 1 pixel of ambiguity)
   
    my $y0           = 33;	# CCD QB coordinates (arcsec)
    my $z0           = -27;
   
    my $min_guide    = 5;	# Minimum number of each object type
    my $min_acq      = 4;
    my $min_fid      = 3;
    ########################################################################

    my $dither;			# Global dither for observation
    if (exists $self->{DITHER_Y_AMP} and exists $self->{DITHER_Z_AMP}) {
	$dither = ($self->{DITHER_Y_AMP} > $self->{DITHER_Z_AMP} ?
		       $self->{DITHER_Y_AMP} : $self->{DITHER_Z_AMP}) * 3600.0;
    } else {
	$dither = 20.0;
    }

    # Set slew error (arcsec) for this obsid, or 135 if not available
    my $targquat = find_command($self, "MP_TARGQUAT", -1);
    my $slew_err = ($targquat && $targquat->{angle}) ? 45 + $targquat->{angle}/2. : 135.0;

    my @warn = ();
    my @yellow_warn = ();

    unless ($c = find_command($self, "MP_STARCAT")) {
	push @{$self->{warn}}, "$alarm No star catalog\n";
	return;
    }

    print STDERR "Checking star catalog for obsid $self->{obsid}\n";

    # Global checks on star/fid numbers

    push @warn,"$alarm Too Few Fid Lights\n" if (@{$self->{fid}} < $min_fid && $self->{obsid} =~ /^\d+$/
						 && $self->{obsid} < 60000);
    push @warn,"$alarm Too Few Acquisition Stars\n" if (@{$self->{acq}} < $min_acq);
    push @warn,"$alarm Too Few Guide Stars\n" if (@{$self->{gui}} < $min_guide);
    push @warn,"$alarm Too many GUIDE + FID\n" if (@{$self->{gui}} + @{$self->{fid}} > 8);

    # Match positions of fids in star catalog with expected, and verify a one to one 
    # correspondance between FIDSEL command and star catalog
    check_fids($self, $c, \@warn) if (exists $self->{fidsel});

    foreach $i (1..16) {
	($sid  = $c->{"GS_ID$i"}) =~ s/[\s\*]//g;
	$type = $c->{"TYPE$i"};
	$yag  = $c->{"YANG$i"};
	$zag  = $c->{"ZANG$i"};
	$mag  = $c->{"GS_MAG$i"};
	$halfw= $c->{"HALFW$i"};
	# Search error for ACQ is the slew error, for fid, guide or mon it is about 4 arcsec
	$search_err = ($type =~ /BOT|ACQ/) ? $slew_err : 4.0;

	next if ($type eq 'NUL');
	my $slot_dither = ($type =~ /FID/ ? 5.0 : $dither); # Pseudo-dither, depending on star or fid

	# Bad AGASC ID
	push @yellow_warn,sprintf "$alarm Non-numeric AGASC ID. [%2d]: %s\n",$i,$sid if ($sid ne '---' && $sid =~ /\D/);
	push @warn,sprintf "$alarm Bad AGASC ID. [%2d]: %s\n",$i,$sid if ($bad_id{$sid});

	# Star/fid outside of CCD boundaries
	if (   $yag > $y_ang_max - $slot_dither || $yag < $y_ang_min + $slot_dither
	    || $zag > $z_ang_max - $slot_dither || $zag < $z_ang_min + $slot_dither) {
	    push @warn,sprintf "$alarm Angle Too Large. [%2d]\n",$i;
	}

	# Quandrant boundary interference
	if (abs($yag-$y0) < $qb_dist + $slot_dither
	     or abs($zag-$z0) < $qb_dist + $slot_dither ) {
	    push @yellow_warn, sprintf "$alarm Quadrant Boundary. [%2d]\n",$i;
	}

	# Faint and bright limits
	if ($type ne 'MON' and $mag ne '---' and
	    ($mag < $mag_bright or $mag > $mag_faint)) {
	    push @warn, sprintf "$alarm Magnitude. [%2d]: %6.3f\n",$i,$mag;
	}

	# Search box size
	if ($type ne 'MON' and
	    $c->{"HALFW$i"} > 120) {
	    push @warn, sprintf "$alarm Search Box Too Large. [%2d]\n",$i;
	}

	# Search box overlap
	foreach $j ($i+1 .. 16) {
	    next if ($c->{"TYPE$j"} eq 'NUL');
	    $ymin = ($c->{"YMIN$i"} > $c->{"YMIN$j"})? $c->{"YMIN$i"} : $c->{"YMIN$j"};
	    $ymax = ($c->{"YMAX$i"} < $c->{"YMAX$j"})? $c->{"YMAX$i"} : $c->{"YMAX$j"};
	    $zmin = ($c->{"ZMIN$i"} > $c->{"ZMIN$j"})? $c->{"ZMIN$i"} : $c->{"ZMIN$j"};
	    $zmax = ($c->{"ZMAX$i"} < $c->{"ZMAX$j"})? $c->{"ZMAX$i"} : $c->{"ZMAX$j"};
	    $mmin = ($c->{"MINMAG$i"} > $c->{"MINMAG$j"})? $c->{"MINMAG$i"} : $c->{"MINMAG$j"};
	    $mmax = ($c->{"MAXMAG$i"} < $c->{"MAXMAG$j"})? $c->{"MAXMAG$i"} : $c->{"MAXMAG$j"};
	    $yol = $ymax - $ymin;
	    $zol = $zmax - $zmin;
	    $mol = $mmax - $mmin;
	    if (($yol > 0) and ($zol > 0)) {
		my $warn = sprintf("$alarm Search Box Overlap. [%2d]-[%2d]: " .
				   "Y,Z,Mag Overlaps: %5.1f %5.1f %5.3f\n",$i,$j,$yol,$zol,$mol);
		$dy = abs($yag-$c->{"YANG$j"});
		$dz = abs($zag-$c->{"ZANG$j"});
		if ($dz < $halfw + $search_err and $dy < $halfw + $search_err) {
		    push @warn, $warn;
		} else {
		    push @yellow_warn, $warn;
		}
	    }
	}

	# Spoiler star (for search) and common column

	foreach $star (@{$self->{agasc_stars}}) {
	    # Skip tests if $star is the same as the catalog star
	    next if (   abs($star->{yag} - $yag) < 1.0
		     && abs($star->{zag} - $zag) < 1.0
		     && abs($star->{mag} - $mag) < 0.1  );

	    $dy = abs($yag-$star->{yag});
	    $dz = abs($zag-$star->{zag});
	    $dr = sqrt($dz**2 + $dy**2);
	    $dm = $mag ne '---' ? $mag - $star->{mag} : 0.0;
	    $dm_string = $mag ne '---' ? sprintf("%4.1f", $mag - $star->{mag}) : '?';

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
	    if ($dz < $halfw + $search_err and $dy < $halfw + $search_err and $dm > -1.0) {
	        my $warn = sprintf("$alarm Search spoiler. [%2d]- %10d: " .
				   "Y,Z,Radial,Mag seps: %3d %3d %3d %4s\n",$i,$star->{id},$dy,$dz,$dr,$dm_string);
		if ($dm > -0.2)  { push @warn, $warn }
		else { push @yellow_warn, $warn }
	    }
	    # Common column: dz within limit, spoiler is $col_sep_mag brighter than star,
	    # and spoiler is located between star and readout
	    if ($dz < $col_sep_dist
		and $dm > $col_sep_mag
		and ($star->{yag}/$yag) > 1.0 
                and abs($star->{yag}) < 2500) {
		push @warn,sprintf("$alarm Common Column. [%2d] - %10d " .
				   "at Y,Z,Mag: %5d %5d %5.2f\n",$i,$star->{id},$star->{yag},$star->{zag},$star->{mag});
	    }
	}

    }

    push @{$self->{warn}}, @warn;
    push @{$self->{yellow_warn}}, @yellow_warn;
}

##*********************************************************************************************
sub check_monitor_commanding {
##*********************************************************************************************
    my $self = shift;
    my $backstop = shift;	# Reference to array of backstop commands
    my $time_tol = 10;		# Commands must be within $time_tol of expectation
    my $c;
    my $bs;
    my $cmd;

    # Check for existence of a star catalog
    return unless ($c = find_command($self, "MP_STARCAT"));
    
    # See if there are any monitor stars.  Return if not.
    my @mon_stars = grep { $c->{"TYPE$_"} eq 'MON' } (1..16);
    return unless (@mon_stars);

    # Find the associated maneuver command for this obsid.  Need this to get the
    # exact time of the end of maneuver
    unless ($manv = find_command($self, "MP_TARGQUAT", -1)) {
	push @{$self->{warn}}, sprintf("$alarm Cannot find maneuver for checking monitor commanding\n");
	return;
    }

    # Now check in backstop commands for :
    #  Dither is disabled (AODSDITH) 1 min prior to the end of the maneuver (EOM)
    #    to the target attitude.
    #  The OFP Aspect Camera Process is restarted (AOACRSET) 3 minutes after EOM.
    #  Dither is enabled (AOENDITH) 5 min after EOM

    $t_manv = $manv->{tstop};
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

##*********************************************************************************************
sub check_fids {
##*********************************************************************************************
    my $self = shift;
    my $c = shift;		# Star catalog command 
    my $warn = shift;		# Array ref to warnings for this obsid

    my (@fid_ok, @fidsel_ok);
    my $n = 0;
    my ($i, $i_fid);
    
    # If no star cat fids and no commanded fids, then return
    return if (@{$self->{fid}} == 0 && @{$self->{fidsel}} == 0);

    # Make sure we have SI and SIM_OFFSET_Z to be able to calculate fid yang and zang
    unless (defined $self->{SI} && defined $self->{SIM_OFFSET_Z}) {
	push @{$warn}, "$alarm Unable to check fids because SI or SIM_OFFSET_Z undefined\n";
	return;
    }
    
    @fid_ok = map { 0 } @{$self->{fid}};

    # Calculate yang and zang for each commanded fid, then cross-correlate with
    # all commanded fids.
    foreach $fid (@{$self->{fidsel}}) {
	my ($yag, $zag) = calc_fid_ang($fid, $self->{SI}, $self->{SIM_OFFSET_Z});
	$fidsel_ok = 0;

	# Cross-correlate with all star cat fids
	for $i_fid (0 .. $#fid_ok) {
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
	$n++;
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
    my ($fid, $si, $sim_z_offset) = @_;
    my $r2a = 180./3.14159265*3600;

    # Make some variables for accessing ODB elements
    $si =~ tr/a-z/A-Z/;
    $si =~ s/[-_]//;
    
    ($si2hrma) = ($si =~ /(ACIS|HRCI|HRCS)/);
    my %offset = (ACIS => 0,
		  HRCI => 6,
		  HRCS => 10);
    my $fid_id = $fid - $offset{$si2hrma};
    
    # Calculate fid angles using formula in OFLS
    my $y_s = $odb{"ODB_${si}_FIDPOS"}[($fid_id-1)*2];
    my $z_s = $odb{"ODB_${si}_FIDPOS"}[($fid_id-1)*2+1];
    my $r_h = $odb{"ODB_${si2hrma}_TO_HRMA"}[$fid_id-1];
    my $z_f = -$sim_z_offset * $odb{"ODB_TSC_STEPS"}[0];
    my $x_f = 0;

    my $yag = -$y_s / ($r_h - $x_f) * $r2a;
    my $zag = -($z_s + $z_f) / ($r_h - $x_f) * $r2a;
    
    return ($yag, $zag);
}

##*********************************************************************************************
sub print_report {
##*********************************************************************************************
    my $self = shift;
    my $c;
    my $o = '';			# Output

#    @sizes = qw (4x4 6x6 8x8);
#    @types = qw (ACQ GUI BOT FID MON);


    $o .= sprintf "\\target{obsid$self->{obsid}}";
    $o .= sprintf ("\\blue_start OBSID: %-5s  ", $self->{obsid});
    $o .= sprintf ("%-22s  %-6s  SIM Z offset: %-5d  Grating: %-5s", $self->{TARGET_NAME}, $self->{SI}, 
		   $self->{SIM_OFFSET_Z}, $self->{GRATING}) if (exists $self->{TARGET_NAME});
    $o .= sprintf "\\blue_end     \n";
    $o .= sprintf "RA, Dec, Roll (deg): %12.6f %12.6f %12.6f\n", $self->{ra}, $self->{dec}, $self->{roll};
    if (exists $self->{DITHER_ON}) {
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
    $o .= "\\link_target{$self->{STARCHECK}/" . basename($self->{or_file}) . ".html#$self->{obsid},OR} ";
    $o .= "\\link_target{$self->{STARCHECK}/" . basename($self->{mm_file}) . ".html#$self->{dot_obsid},MANVR} ";
    $o .= "\\link_target{$self->{STARCHECK}/" . basename($self->{dot_file}) . ".html#$self->{obsid},DOT} ";
    $o .= "\\link_target{$self->{STARCHECK}/" . "make_stars.txt"            . ".html#$self->{obsid},MAKE_STARS} ";
    $o .= sprintf "\n\n";
    for $n (1 .. 10) {		# Allow for multiple TARGQUAT cmds, though 2 is the typical limit
	if ($c = find_command($self, "MP_TARGQUAT", $n)) {
	    $o .= sprintf "MP_TARGQUAT at $c->{date} (VCDU count = $c->{vcdu})\n";
	    $o .= sprintf "  Q1,Q2,Q3,Q4: %.8f  %.8f  %.8f  %.8f\n", $c->{Q1}, $c->{Q2}, $c->{Q3}, $c->{Q4};
	    $o .= sprintf("  MANVR: Angle= %6.2f deg  Duration= %.0f sec  Slew err= %.1f arcsec\n",
			  $c->{angle}, $c->{dur}, 45+$c->{angle}/2.)
		if (exists $c->{angle} and exists $c->{dur});
	    $o .= "\n";
	}
    }
    if ($c = find_command($self, "MP_STARCAT")) {
	@cat_fields = qw (IMNUM GS_ID    TYPE  SIZE MINMAG GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW);
	@cat_format = qw (  %3d  %12s     %6s   %5s  %8.3f    %8s  %8.3f  %7d  %7d    %4d    %4d    %5d);

	$o .= sprintf "MP_STARCAT at $c->{date} (VCDU count = $c->{vcdu})\n";
	$o .= sprintf "----------------------------------------------------------------------------------\n";
#              [ 4]  3   971113176   GUI  6x6   5.797   7.314   8.844  -2329  -2242   1   1   25
	$o .= sprintf " IDX SLOT        ID  TYPE   SZ  MINMAG    MAG   MAXMAG   YANG   ZANG DIM RES HALFW\n";
	$o .= sprintf "----------------------------------------------------------------------------------\n";
	
	
	foreach $i (1..16) {
	    next if ($c->{"TYPE$i"} eq 'NUL');

	    $o .= sprintf "[%2d]",$i;
	    foreach $n (0 .. $#cat_fields) {
		$o .= sprintf "$cat_format[$n]", $c->{"$cat_fields[$n]$i"}
	    };
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
    return $o;
}

##*********************************************************************************************
sub add_guide_summ {
##*********************************************************************************************
    my $self = shift;
    ($ra, $dec, $roll, $info) = @_;

    unless ($c = find_command($self, 'MP_STARCAT')) {
	if ($self->{n_guide_summ}++ == 0) {
	    push @{$self->{warn}}, ">> WARNING: " .
		"Star catalog for $self->{obsid} in guide star summary, but not backstop\n";
	}
	return; # Bail out, since there is no starcat cmd to update
    }
    $c->{target_ra} = $ra;
    $c->{target_dec} = $dec;
    $c->{target_roll} = $roll;

    @f = split ' ', $info;
    $OK = 0;
    for $j (1 .. 16) {
	if (abs( $f[5]*$r2a - $c->{"YANG$j"}) < 10
	    && abs( $f[6]*$r2a - $c->{"ZANG$j"}) < 10)
	{
	    $OK = 1;
	    $c->{"GS_TYPE$j"} = $f[0];
	    $c->{"GS_ID$j"} = $f[1];
	    $c->{"GS_RA$j"} = $f[2];
	    $c->{"GS_DEC$j"} = $f[3];
	    $c->{"GS_MAG$j"} = sprintf "%8.3f", $f[4];
	    $c->{"GS_YANG$j"} = $f[5] * $r2a;
	    $c->{"GS_ZANG$j"} = $f[6] * $r2a;
	}
    }
#    unless ($OK) {
#	push @{$self->{yellow_warn}}, ">> WARNING: " .
#	    "$f[0] $f[1] in guide star summary, but not backstop\n" ;
#    }
}

##***************************************************************************
sub get_agasc_stars {
##***************************************************************************
    # Run mp_get_agasc to get field stars
    $self = shift;

    $mp_get_agasc = "mp_get_agasc -r $self->{ra} -d $self->{dec} -w 1.0";
    my @stars = `$mp_get_agasc`;
    my $q_aca = Quat->new($self->{ra}, $self->{dec}, $self->{roll});

    foreach (@stars) {
	my ($id, $ra, $dec, undef, undef, undef, undef, $mag, undef, $bv) = split;
	my ($yag, $zag) = Quat::radec2yagzag($ra, $dec, $q_aca);
	$yag *= $r2a;
	$zag *= $r2a;
	push @{$self->{agasc_stars}}, { id => $id,
					ra  => $ra,  dec => $dec,
					mag => $mag, bv  => $bv,
					yag => $yag, zag => $zag } ;
    }
}

##***************************************************************************
sub identify_stars {
##***************************************************************************
    $self = shift;
    return unless ($c = find_command($self, 'MP_STARCAT'));
    $DIST_LIMIT = 1.0;		# 1 arcsec box for ID

    for $i (1 .. 16) {	
	next if ($c->{"TYPE$i"} eq 'NUL' or $c->{"GS_ID$i"} ne '---');
	$yag = $c->{"YANG$i"};
	$zag = $c->{"ZANG$i"};
	
	foreach $star (@{$self->{agasc_stars}}) {
	    if (abs($star->{yag} - $yag) < $DIST_LIMIT
		&& abs($star->{zag} - $zag) < $DIST_LIMIT) {
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

##***************************************************************************
sub plot_stars {
##  Make a plot of the field
##***************************************************************************
    use PGPLOT;

    $self = shift;
    return unless ($c = find_command($self, 'MP_STARCAT'));
    $self->{plot_file} = shift;
    
    %sym_type = (FID => 8,
		 BOT => 17,
		 ACQ => 17,
		 GUI => 17,
		 MON => 17,
		 field_star => 17);

    %sym_color = (FID => 2,
		  BOT => 4,
		  ACQ => 4,
		  GUI => 3,
		  MON => 8,
		  field_star => 1);

    # Setup pgplot
    $dev = "/vgif" unless defined $dev;  # "?" will prompt for device
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
    box(0,0,2560);

    # Plot field stars from AGASC
    pgsci($sym_color{field_star});
    foreach $star (@{$self->{agasc_stars}}) {
	next if ($star->{mag} > $faint_plot_mag);
	pgsch(sym_size($star->{mag})); # Set character height
	pgpoint(1, $star->{yag}, $star->{zag}, $sym_type{field_star});
    }

    # Plot fids/stars in star catalog
    for $i (1 .. 16) {	
	next if ($c->{"TYPE$i"} eq 'NUL');
	my $mag = $c->{"GS_MAG$i"} eq '---' ? $c->{"MAXMAG$i"} - 1.5 : $c->{"GS_MAG$i"};
	pgsch(sym_size($mag)); # Set character height
	$x = $c->{"YANG$i"};
	$y = $c->{"ZANG$i"};
	pgsci($sym_color{$c->{"TYPE$i"}});             # Change colour
	pgpoint(1, $x, $y, $sym_type{$c->{"TYPE$i"}}) if ($c->{"TYPE$i"} eq 'FID'); # Make open (fid)
	if ($c->{"TYPE$i"} =~ /(BOT|ACQ|MON)/) {       # Plot search box
	    box($x, $y, $c->{"HALFW$i"});
	}
	if ($c->{"TYPE$i"} =~ /(BOT|GUI)/) {           # Larger open circle for guide stars
	    pgpoint(1, $x, $y, 24);
	}
	pgsch(1.2);
	pgsci(2);
	pgtext($x+150, $y, "$i");
    }

    pgsci(8);			# Orange for size key
    @x = (-2700, -2700, -2700, -2700, -2700);
    @y = (2400, 2100, 1800, 1500, 1200);
    @mag = (10, 9, 8, 7, 6);
    foreach (0..$#x) {
	pgsch(sym_size($mag[$_])); # Set character height
	pgpoint(1, $x[$_], $y[$_], $sym_type{field_star});
    }
    pgend();				# Close plot
    
    rename "pgplot.gif", $self->{plot_file};
#    print STDERR "Created star chart $self->{plot_file}\n";
}

##***************************************************************************
sub quat2radecroll {
##***************************************************************************
    my $r2d = 180./3.14159265;

    ($q1, $q2, $q3, $q4) = @_;

    $q12 = $q1**2;
    $q22 = $q2**2;
    $q32 = $q3**2;
    $q42 = $q4**2;

    $xa = $q12 - $q22 - $q32 + $q42;
    $xb = 2 * ($q1 * $q2 + $q3 * $q4);
    $xn = 2 * ($q1 * $q3 - $q2 * $q4);
    $yn = 2 * ($q2 * $q3 + $q1 * $q4);
    $zn = $q32 + $q42 - $q12 - $q22;

    $ra   = atan2($xb, $xa) * $r2d;
    $dec  = atan2($xn, sqrt(1 - $xn**2)) * $r2d;
    $roll = atan2($yn, $zn) * $r2d;
    $ra += 360 if ($ra < 0);
    $roll += 360 if ($roll < 0);

    return ($ra, $dec, $roll);
}


##***************************************************************************
sub box {
##***************************************************************************
    my ($x, $y, $s) = @_;
    my @x = ($x-$s, $x-$s, $x+$s, $x+$s, $x-$s);
    my @y = ($y-$s, $y+$s, $y+$s, $y-$s, $y-$s);
    pgline(5, \@x, \@y);
}

##***************************************************************************
sub sym_size {
##***************************************************************************
    my $mag = shift;
    return ( (0.5 - 3.0) * ($mag - 6.0) / (12.0 - 6.0) + 2.5);
}

###################################################################################
sub time2date {
###################################################################################
# Date format:  1999:260:03:30:01.542
    my $time = shift;
    my $t1998 = @_ ? 0.0 : 883612736.816; # 2nd argument implies Unix time not CXC time
    my $floor_time = floor($time+$t1998);
    ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($floor_time);

    return sprintf ("%04d:%03d:%02d:%02d:%06.3f",
		    $year+1900, $yday+1, $hour, $min, $sec + ($time+$t1998-$floor_time));
}

