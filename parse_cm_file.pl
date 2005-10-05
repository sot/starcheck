package Parse_CM_File;

###############################################################
#
# Parse one of several types of files produced in OFLS 
# command management
#
###############################################################

use POSIX;
use lib '/proj/sot/ska/lib/site_perl';
use Ska::Convert qw(date2time time2date);

use Time::JulianDay;
use Time::DayOfYear;
use Time::Local;
use IO::File;

$VERSION = '$Id$';  # '
1;

###############################################################
sub dither {
###############################################################
    my $dh_file = shift;      # Dither history file name
    my $bs_arr = shift;               # Backstop array reference
    my $bs;
    my @bs_state;
    my @bs_time;
    my @dh_state;
    my @dh_time;
    my %dith_cmd = ('DS' => 'DISA', 'EN' => 'ENAB');

    # First get everything from backstop
    foreach $bs (@{$bs_arr}) {
	if ($bs->{cmd} eq 'COMMAND_SW') {
	    my %params = parse_params($bs->{params});
	    if ($params{TLMSID} =~ 'AO(DS|EN)DITH') {
		push @bs_state, $dith_cmd{$1};
		push @bs_time, $bs->{time};  # see comment below about timing
	    }
	}
    }

    # Now get everything from DITHER
    # Parse lines like:
    # 2002262.094827395   | DSDITH  AODSDITH
    # 2002262.095427395   | ENDITH  AOENDITH

    if ($dh_file && ($dith_hist_fh = new IO::File $dh_file, "r")) {
	while (<$dith_hist_fh>) {
	    if (/(\d\d\d\d)(\d\d\d)\.(\d\d)(\d\d)(\d\d) \d* \s+ \| \s+ (EN|DS) DITH/x) {
		my ($yr, $doy, $hr, $min, $sec, $state) = ($1,$2,$3,$4,$5,$6);
		$time = date2time("$yr:$doy:$hr:$min:$sec");
		push @dh_state, $dith_cmd{$state};
		push @dh_time, $time;
	    }
	}

	$dith_hist_fh->close();
    }

    my @ok = grep { $dh_time[$_] < $bs_time[0] } (0 .. $#dh_time);
    my @state = (@dh_state[@ok], @bs_state);
    my @time   = (@dh_time[@ok], @bs_time);
    
    # Now make an array of hashes as the final output.  Keep track of where the info
    # came from, for later use in Chex
    return map { { time   => $time[$_],
		   state  => $state[$_],
		   source => $time[$_] < $bs_time[0] ? 'history' : 'backstop'}
	       } (0 .. $#state);
}

###############################################################
sub fidsel {
###############################################################
    $fidsel_file = shift;	# FIDSEL file name
    $bs          = shift;	# Reference to backstop array
    my $error = [];
    my %time_hash = ();		# Hash of time stamps of fid cmds

    my @fs = ();
    foreach (0 .. 14) {
	$fs[$_] = [];
    }
    
    my ($actions, $times) = get_fid_actions($fidsel_file, $bs);

    # Check for duplicate commanding
    map { $time_hash{$_}++ } @{$times};
    foreach (sort keys %time_hash) {
#	push @{$error}, "ERROR - $time_hash{$_} fid hardware commands at time $_\n"
#	    if ($time_hash{$_} > 1);
    }
	
    for ($i = 0; $i <= $#{$times}; $i++) {
	# If command contains RESET, then turn off (i.e. set tstop) any 
	# fid light that is on
	if ($actions->[$i] =~ /RESET/) {
	    foreach $fid (1 .. 14) {
		foreach $fid_interval (@{$fs[$fid]}) {
		    $fid_interval->{tstop} = $times->[$i] unless ($fid_interval->{tstop});
		}
	    }
	}
	# Otherwise turn fid on by adding a new entry with tstart=time
	elsif (($fid) = ($actions->[$i] =~ /FID\s+(\d+)\s+ON/)) {
	    push @{$fs[$fid]}, { tstart => $times->[$i] };
	} else {
	    push @{$error}, "Parse_cm_file::fidsel: WARNING - Could not parse $actions->[$i]";
	}
    }

    return ($error, @fs);
}    

###############################################################
sub get_fid_actions {
###############################################################
    my $fs_file = shift;	# Fidsel file name
    my $bs_arr = shift;		# Backstop array reference
    my $bs;
    my @bs_action;
    my @bs_time;
    my @fs_action;
    my @fs_time;

    # First get everything from backstop
    foreach $bs (@{$bs_arr}) {
	if ($bs->{cmd} eq 'COMMAND_HW') {
	    my %params = parse_params($bs->{params});
	    if ($params{TLMSID} eq 'AFIDP') {
		my $msid = $params{MSID};
		push @bs_action, "$msid FID $1 ON" if ($msid =~ /AFLC(\d+)/);
		push @bs_action, "RESET" if ($msid =~ /AFLCRSET/);
		push @bs_time, $bs->{time} - 10;  # see comment below about timing
	    }
	}
    }

    # Now get everything from FIDSEL
    # Parse lines like:
    # 2001211.190730558   | AFLCRSET RESET
    # 2001211.190731558   | AFLC02D1 FID 02 ON
    if ($fs_file && ($fidsel_fh = new IO::File $fs_file, "r")) {
	while (<$fidsel_fh>) {
	    if (/(\d\d\d\d)(\d\d\d)\.(\d\d)(\d\d)(\d\d)\S*\s+\|\s+(AFL.+)/) {
		my ($yr, $doy, $hr, $min, $sec, $action) = ($1,$2,$3,$4,$5,$6);
		
		if ($action =~ /(RESET|FID.+ON)/) {
		    # Convert to time, and subtract 10 seconds so that fid lights are
		    # on slightly before end of manuever.  In actual commanding, they
		    # come on about 1-2 seconds *after*. 
		    $time = date2time("$yr:$doy:$hr:$min:$sec") - 10;
		    push @fs_action, $action;
		    push @fs_time, $time;
		}
	    }
	}

	$fidsel_fh->close();
    }

    my @ok = grep { $fs_time[$_] < $bs_time[0] } (0 .. $#fs_time);
    my @action = (@fs_action[@ok], @bs_action);
    my @time   = (@fs_time[@ok], @bs_time);
    
    return (\@action, \@time);
}

#AXMAN Run at 03/25/2002 08:57:09  Version of Mar-12-2002
#
#Man File = C:\wsdavis\CXOFiles\MPS_Sched_Chk\APR0102A\md091_0405.dot.man
#Calib File 1 = C:\wsdavis\CXOFiles\ManError\GYRO_OAC.mat
#Calib File 2 = C:\wsdavis\CXOFiles\ManError\GYROTotalCal.mat
#SBoxMargin =    20.00 asec, 3-sig init roll uncer =    30.00 asec
# obsid MaxErrYZ Seg start_time        stop_time         ssss    angle    X-axis    Y-axis    Z-axis     initQ1      initQ2      initQ3      initQ4       finalQ1     finalQ2     finalQ3     finalQ4     iru-X    iru-Y    iru-Z     aber-X   aber-Y   aber-Z  del-Y    del-Z    delYZ   iruadjYZ totadjYZ syserr.Y syserr.Z ranerr.Y ranerr.Z
#  2193    59.43  0  2002:091:04:50:16 2002:091:05:09:04 ----   35.531 -0.425054 -0.486987  0.763003   0.85686666 -0.10606580 -0.34000709  0.37272612   0.69244839 -0.31178304 -0.37809776  0.52947960   -21.34     8.07    20.98     4.11     5.37    -8.15     0.00     0.00     0.00    22.48    29.25     2.70    29.13    12.15    10.31
#  1664    87.62  0  2002:091:10:59:56 2002:091:11:27:23 ----   74.053  0.113094 -0.877861  0.465370   0.69244839 -0.31178304 -0.37809776  0.52947960   0.30163013 -0.74861636 -0.49829514  0.31669350   -30.97    23.87    28.00     5.67    16.14   -15.44     0.00    -0.00     0.00    36.79    44.12     7.73    43.44    15.59    24.18
#total number of maneuvers = 27
#----      5
#---+      1
###############################################################
sub man_err {
###############################################################
    my $man_err = shift;
    my $in_man = 0;
    my @me = ();
    open (MANERR, $man_err)
	or die "Couldn't open maneuver error file $man_err for reading\n";
    while (<MANERR>) {
	last if (/total number/i);
	if ($in_man) {
	    my @vals = split;
	    if ($#vals != $#cols) {
		warn "man_err: ERROR - mismatch between column names and data values\n";
		return ();	# return nothing
	    }
	    my %data = map { $cols[$_], $vals[$_] } (0 .. $#cols);
	    $data{Seg} = 1 if ($data{Seg} == 0); # Make it easier later on to match the segment number
				# with the MP_TARGQUAT commands
	    $data{obsid} = sprintf "%d", $data{obsid};  # Clip leading zeros

	    push @me, \%data;
	}
	if (/^\s*obsid\s+maxerryz\s+seg/i) {
	    @cols = split;
	    $in_man = 1;
	}
    }
    return @me;
}

###############################################################
sub backstop {
###############################################################
    $backstop = shift;

    @bs = ();
    open (BACKSTOP, $backstop) || die "Couldn't open backstop file $backstop for reading\n";
    while (<BACKSTOP>) {
	my ($date, $vcdu, $cmd, $params) = split '\s*\|\s*', $_;
	$vcdu =~ s/ +.*//; # Get rid of second field in vcdu
	push @bs, { date => $date,
		    vcdu => $vcdu,
		    cmd  => $cmd,
		    params => $params,
		    time => date2time($date) };
    }
    close BACKSTOP;

    return @bs;
}

###############################################################
sub DOT {
###############################################################
    $dot_file = shift;

    # Break DOT down into commands, each with a unique ID (with index)

    undef %command;
    undef %index;
    undef %dot;

    open (DOT, $dot_file) || die "Couldn't open DOT file $dot_file\n";
    while (<DOT>) {
	chomp;
	next unless (/\S/);
	($cmd, $id) = /(.+) +(\S+)....$/;
	$index{$id} = "0001" unless (exists $index{$id});
	$cmd =~ s/\s+$//;
	$command{"$id$index{$id}"} .= $cmd;
	$index{$id} = sprintf("%04d", $index{$id}+1) unless ($cmd =~ /,$/);
    }
    close DOT;

    foreach (keys %command) {
	%{$dot{$_}} = parse_params($command{$_});
	$dot{$_}{time}  = date2time($dot{$_}{TIME})     if ($dot{$_}{TIME});
	$dot{$_}{time} += date2time($dot{$_}{MANSTART}) if ($dot{$_}{TIME} && $dot{$_}{MANSTART});
	$dot{$_}{cmd_identifier} = "$dot{$_}{anon_param1}_$dot{$_}{anon_param2}"
	    if ($dot{$_}{anon_param1} and $dot{$_}{anon_param2});
    } 
    return %dot;
}

###############################################################
sub OR {
###############################################################
    $or_file = shift;

    open (OR, $or_file) || die "Couldn't open OR file $or_file\n";
    while (<OR>) {
	chomp;
	if ($in_obs_statement) {
	    $obs .= $_;
	    unless (/,\s*$/) {
		%obs = OR_parse_obs($obs);
		$or{$obs{obsid}} = { %obs };
		$in_obs_statement = 0;
		$obs = '';
	    }
	}
	$in_obs_statement = 1 if (/^\s*OBS,\s*$/);
    }
    close OR;
    return %or;
 }

###############################################################
sub OR_parse_obs {
###############################################################
    $_ = shift;

    my @obs_columns = qw(obsid TARGET_RA TARGET_DEC TARGET_NAME
			 SI TARGET_OFFSET_Y TARGET_OFFSET_Z
			 SIM_OFFSET_X SIM_OFFSET_Z GRATING MON_RA MON_DEC SS_OBJECT);
    # Init some defaults
    my %obs = ();
    foreach (@obs_columns) {
	$obs{$_} = '';
    }
    ($obs{TARGET_RA}, $obs{TARGET_DEC}) = (0.0, 0.0);
    ($obs{TARGET_OFFSET_Y}, $obs{TARGET_OFFSET_Z}) = (0.0, 0.0);
    ($obs{SIM_OFFSET_X}, $obs{SIM_OFFSET_Z}) = (0, 0);

    $obs{obsid} = 0+$1 if (/ID=(\d+),/);
    ($obs{TARGET_RA}, $obs{TARGET_DEC}) = ($1, $2)
	if (/TARGET=\(([^,]+),([^,\)]+)/);
    ($obs{MON_RA}, $obs{MON_DEC}) = ($1, $2)
	if (/STAR=\(([^,]+),([^,\)]+)/);
    $obs{TARGET_NAME} = $3
	if (/TARGET=\(([^,]+),([^,]+),\s*\{([^\}]+)\}\),/);
    $obs{SS_OBJECT} = $1 if (/SS_OBJECT=([^,\)]+)/);
    $obs{SI} = $1 if (/SI=([^,]+)/);
    ($obs{TARGET_OFFSET_Y}, $obs{TARGET_OFFSET_Z}) = ($1, $2)
	if (/TARGET_OFFSET=\(([^,]+),([^,]+)\)/);
    ($obs{DITHER_ON},
     $obs{DITHER_Y_AMP},$obs{DITHER_Y_FREQ}, $obs{DITHER_Y_PHASE},
     $obs{DITHER_Z_AMP},$obs{DITHER_Z_FREQ}, $obs{DITHER_Z_PHASE}) = split ',', $1
	 if (/DITHER=\(([^)]+)\)/);
    $obs{SIM_OFFSET_Z} = $1
	if (/SIM_OFFSET=\(([^,\)]+)/);
    $obs{SIM_OFFSET_X} = $2
	if (/SIM_OFFSET=\(([^,\)]+),([^,]+)\)/);
    $obs{GRATING} = $1 if (/GRATING=([^,]+)/);

    return %obs;
}

	    
###############################################################
sub MM {
# Parse maneuver management (?) file
###############################################################
    my $mm_file = shift;
    my %mm;
    my $start_stop = 0;
    my $first = 1;

    open (MM, $mm_file) || die "Couldn't open MM file $mm_file\n";
    while (<MM>) {
	chomp;
	$start_stop = !$start_stop if (/(INITIAL|INTERMEDIATE|FINAL) ATTITUDE/);
        $initial_obsid = $1 if (/INITIAL ID:\s+(\S+)\S\S/);
        $obsid = $1 if (/FINAL ID:\s+(\S+)\S\S/);
	$start_date = $1 if ($start_stop && /TIME\s*\(GMT\):\s+(\S+)/);
	$stop_date  = $1 if (! $start_stop && /TIME\s*\(GMT\):\s+(\S+)/);
	$ra         = $1 if (/RA\s*\(deg\):\s+(\S+)/);
	$dec        = $1 if (/DEC\s*\(deg\):\s+(\S+)/);
	$roll       = $1 if (/ROLL\s*\(deg\):\s+(\S+)/);
	$dur        = $1 if (/Duration\s*\(sec\):\s+(\S+)/);
	$angle      = $1 if (/Maneuver Angle\s*\(deg\):\s+(\S+)/);
	@quat       = ($1,$2,$3,$4) if (/Quaternion:\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/);

	if (/Profile Parameters/) { # Effective end of maneuver statement
	    # If the FINAL ID was not found (in the case of an intermediate maneuver)
	    # then look ahead in the file to find it.  If that fails, use the initial obsid
	    unless ($obsid) {
		my $pos = tell MM;
		while (<MM>) {
		    if (/FINAL ID:\s+(\S+)\S\S/) {
			$obsid = $1;
			last;
		    }
		}
		$obsid = $initial_obsid unless ($obsid);
		seek MM, $pos, 0; # Go back to original spot
	    }
		    
	    while (exists $mm{$obsid}) { $obsid .= "!"; }

	    $mm{$obsid}->{start_date} = $start_date;
	    $mm{$obsid}->{stop_date}  = $stop_date;
	    $mm{$obsid}->{ra}         = $ra;
	    $mm{$obsid}->{dec}        = $dec;
	    $mm{$obsid}->{roll}       = $roll;
	    $mm{$obsid}->{dur}        = $dur;
	    $mm{$obsid}->{angle}      = $angle;
	    $mm{$obsid}->{tstart}     = date2time($start_date);
	    $mm{$obsid}->{tstop}      = date2time($stop_date);
	    ($mm{$obsid}->{obsid}     = $obsid) =~ s/^0+//;
	    $mm{$obsid}->{q1}         = $quat[0];
	    $mm{$obsid}->{q2}         = $quat[1];
	    $mm{$obsid}->{q3}         = $quat[2];
	    $mm{$obsid}->{q4}         = $quat[3];
	    undef $obsid;
	}
    }
    close MM;

    return %mm;
}

##***************************************************************************
sub mechcheck {
##***************************************************************************
    my $mc_file = shift;
    my @mc;
    my ($date, $time, $cmd, $dur, $text);
    my %evt;
    my $SIM_FA_RATE = 90.0;	# Steps per seconds  18steps/shaft

    open MC, $mc_file or die "Couldn't open mech check file $mc_file\n";
    while (<MC>) {
	chomp;

	# Make continuity statements have similar format
	$_ = "$3 $1$2" if (/^(SIMTRANS|SIMFOCUS)( [-\d]+ at )(.+)/);

	next unless (/^(\d\d\d\d)(\d\d\d)\.(\d\d)(\d\d)(\d\d)(\d\d\d)(.+)/);
	$date = "$1:$2:$3:$4:$5.$6";
	$text = $7;
	%evt = ();
	$evt{time} = date2time($date);
	if ($text =~ /NO_MATCH_NOW_FOR_OBSID\s+(\d+)/) {
	    $evt{var} = "obsid";
	    $evt{dur} = 0;
	    $evt{val} = $1;
	} elsif ($text =~ /SIMTRANS ([-\d]+) at/) {
	    $evt{var} = "simtsc_continuity";
	    $evt{dur} = 0;
	    $evt{val} = $1;
	} elsif ($text =~ /SIMFOCUS ([-\d]+) at/) {
	    $evt{var} = "simfa_continuity";
	    $evt{dur} = 0;
	    $evt{val} = $1;
	} elsif ($text =~ /SIMTRANS from ([-\d]+) to ([-\d]+) Dur (\d+)/) {
	    $evt{var} = "simtsc";
	    $evt{dur} = $3;
	    $evt{val} = $2;
	    $evt{from} = $1;
	} elsif ($text =~ /SIMFOCUS from ([-\d]+) to ([-\d]+)/) {
	    $evt{var} = "simfa";
	    $evt{dur} = ceil(abs($2 - $1) / $SIM_FA_RATE);
	    $evt{val} = $2;
	    $evt{from} = $1;
	} elsif ($text =~ /NO_MATCH_NOW_FOR_GRATINGS (.+) to (.+)/) {
	    $evt{var} = "gratings";
	    $evt{dur} = 160;
	    $evt{val} = $2;
	    $evt{from}= $1;
	}
    
	push @mc, { %evt } if ($evt{var});
    }
    close MC;

    return @mc;
}

##***************************************************************************
sub SOE {
##***************************************************************************
    $soe_file = shift;
# Taken from RAC's code /proj/sot/ska/ops/soe/soeA.pl

# read the SOE record formats into the hashes of lists $fld and $len
    while (<DATA>) {
	($rtype,$rfld,$rlen,$rdim1,$rdim2) = split;
	for $j (0 .. $rdim2-1) { 
	    for $i (0 .. $rdim1-1) {
		$idx = '';
		$idx .= "[$i]" if ($rdim1 > 1);
		$idx .= "[$j]" if ($rdim2 > 1);
		push @{ $fld{$rtype} },$rfld.$idx; 
		push @{ $len{$rtype} },$rlen;
	    }
	}
	$obsidx = $#{ $fld{OBS} } if ($rtype eq "OBS" and $rfld =~ /odb_obs_id/);
	$rlen{$rtype} += $rlen * $rdim1 * $rdim2;
	$templ{$rtype} .= "a$rlen" x ($rdim1 * $rdim2);
    }

# read the SOE file from STDIN into $soe

    open SOE, $soe_file or die "Couldn't open SOE file '$soe_file'\n";
    $soe = (<SOE>);
    $l = length $soe;

# unpack the SOE file

    $p = 0;
    while ($p < $l) {
	$typ = substr $soe,$p,3;
	if (exists $rlen{$typ}) {
	    $rec = substr $soe,$p,$rlen{$typ};
	    @rvals = unpack $templ{$typ},$rec;
	    @rflds = @{ $fld{$typ} };
	    @rlens = @{ $len{$typ} };
	    $obsid = ($typ eq "OBS" or $typ eq "CAL")? "$rvals[$obsidx] " : "";
	    $obsid =~ s/^0+//;
	    $obsid =~ s/\s//g;
	    if ($obsid) {
		foreach $i (0 .. $#rvals) {
		    $SOE{$obsid}{$rflds[$i]} = $rvals[$i];
		}
	    }
	    $p += $rlen{$typ};
	} else {
	    die "Parse_CM_File::SOE: Cannot identify record of type $typ\n";
	}
    }

    return %SOE;
}

##***************************************************************************
sub odb {
##***************************************************************************
    use Text::ParseWords;

    my $odb_file = shift;
    my $odb_var;
    my @words;

    open (ODB, $odb_file) || die "Couldn't open $odb_file\n";
    while (<ODB>) {
	next if (/^C/ || /^\s*\$/);
	next unless (/\S/);
	chomp;
	s/!.*//;
	s/^\s+//;
	s/\s+$//;
	@words = &parse_line(",", 0, $_);
	foreach (@words) {
	    next unless ($_);
	    if (/(\S+)\s*=\s*(\S+)/) {
		$odb_var = $1;
		$_ = $2;
	    }
	    push @{$odb{$odb_var}}, $_ if ($odb_var);
	}
    }

    close ODB;

    return (%odb);
}		


##***************************************************************************
sub local_date2time {
##***************************************************************************
# Date format:  1999:260:03:30:01.542
    
    my $date = shift;
    my ($sec, $min, $hr, $doy, $yr) = reverse split ":", $date;

    return ($doy*86400 + $hr*3600 + $min*60 + $sec) unless ($yr);

    my ($mon, $day) = ydoy2md($yr, $doy);
    $sec =~ s/\..+//; 

    return timegm($sec,$min,$hr,$day,$mon-1,$yr);
}

##***************************************************************************
sub rel_date2time {
##***************************************************************************
# Date format:  1999:260:03:30:01.542
    
    my $date = shift;
    my ($yr, $doy, $hr, $min, $sec) = split ":", $date;
}

##***************************************************************************
sub parse_params {
##***************************************************************************
    my @fields = split '\s*,\s*', shift;
    my %param = ();
    my $pindex = 1;

    foreach (@fields) {
	if (/(.+)= ?(.+)/) {
	    $param{$1} = $2;
	} else {
	    $param{"anon_param$pindex"} = $_;
	    $pindex++;
	}
    }

    return %param;
}

# define the structure of SOE file records:
# record type, field name, field size, field dimension 1, field dimension 2

__DATA__
HDR odb_rec_type 3 1 1
HDR odb_sched_id 8 1 1
HDR odb_prev_sched_id 8 1 1
HDR odb_orlist_id 11 1 1
HDR odb_erlist_id 11 10 1
HDR odb_sched_obj 2 1 1
HDR odb_start_time 21 1 1
HDR odb_end_time 21 1 1
HDR odb_sched_time 17 1 1
HDR odb_or_list_name 25 1 1
HDR odb_or_list_update 21 1 1
HDR odb_tot_obs_time 17 1 1
HDR odb_tot_src_time 17 1 1
HDR odb_tot_add_time 17 1 1
HDR odb_frac_add_time 10 1 1
HDR odb_tot_sub_time 17 1 1
HDR odb_frac_sub_time 10 1 1
HDR odb_tot_slew_time 17 1 1
HDR odb_frac_slew_time 10 1 1
HDR odb_tot_acq_time 17 1 1
HDR odb_frac_acq_time 10 1 1
HDR odb_tot_idle_time 17 1 1
HDR odb_frac_idle_time 10 1 1
HDR odb_tot_rad_time 17 1 1
HDR odb_frac_rad_time 10 1 1
HDR odb_tot_ecl_time 17 1 1
HDR odb_frac_ecl_time 10 1 1
HDR odb_av_efficiency 10 1 1
HDR odb_total_gas_used 10 1 1
OBS odb_rec_id 3 1 1
OBS odb_target_quat 10 4 1
OBS odb_sstart_ang 10 1 1
OBS odb_send_ang 10 1 1
OBS pdb_sclose_ang 10 1 1
OBS pdb_estart_ang 10 1 1
OBS pdb_eend_ang 10 1 1
OBS pdb_eclose_ang 10 1 1
OBS pdb_mstart_ang 10 1 1
OBS pdb_mend_ang 10 1 1
OBS pdb_mclose_ang 10 1 1
OBS pdb_pstart_ang 10 20 1
OBS pdb_pend_ang 10 20 1
OBS pdb_pclose_ang 10 20 1
OBS pdb_kstart_ang 10 20 1
OBS pdb_kend_ang 10 20 1
OBS pdb_kclose_ang 10 20 1
OBS odb_acq_stars 10 2 8
OBS odb_guide_images 10 3 8
OBS odb_fom 10 1 1
OBS odb_roll_ang 10 1 1
OBS odb_slew_ang 10 1 1
OBS odb_instance_num 2 1 1
OBS odb_req_id 8 1 1
OBS odb_obs_id 5 1 1
OBS odb_acq_id 10 8 1
OBS odb_guide_id 10 8 1
OBS odb_obs_start_time 21 1 1
OBS odb_obs_end_time 21 1 1
OBS odb_obs_dur 17 1 1
OBS odb_obs_dur_extra 17 1 1
OBS odb_mstart_time 21 1 1
OBS odb_mend_time 21 1 1
OBS odb_trans_stime 21 1 1
OBS odb_trans_etime 21 1 1
OBS odb_trans_wstime 21 1 1
OBS odb_trans_wetime 21 1 1
OBS odb_sclose_time 21 1 1
OBS odb_eclose_time 21 1 1
OBS odb_mclose_time 21 1 1
OBS odb_pclose_time 21 20 1
OBS odb_pclose_id 8 20 1
OBS odb_kclose_time 21 20 1
OBS odb_kclose_id 8 20 1
CAL odb_rec_id 3 1 1
CAL odb_target_quat 10 4 1
CAL odb_sstart_ang 10 1 1
CAL odb_send_ang 10 1 1
CAL pdb_sclose_ang 10 1 1
CAL pdb_estart_ang 10 1 1
CAL pdb_eend_ang 10 1 1
CAL pdb_eclose_ang 10 1 1
CAL pdb_mstart_ang 10 1 1
CAL pdb_mend_ang 10 1 1
CAL pdb_mclose_ang 10 1 1
CAL pdb_pstart_ang 10 20 1
CAL pdb_pend_ang 10 20 1
CAL pdb_pclose_ang 10 20 1
CAL pdb_kstart_ang 10 20 1
CAL pdb_kend_ang 10 20 1
CAL pdb_kclose_ang 10 20 1
CAL odb_acq_stars 10 2 8
CAL odb_guide_images 10 3 8
CAL odb_fom 10 1 1
CAL odb_roll_ang 10 1 1
CAL odb_slew_ang 10 1 1
CAL odb_instance_num 2 1 1
CAL odb_req_id 8 1 1
CAL odb_obs_id 5 1 1
CAL odb_acq_id 10 8 1
CAL odb_guide_id 10 8 1
CAL odb_obs_start_time 21 1 1
CAL odb_obs_end_time 21 1 1
CAL odb_obs_dur 17 1 1
CAL odb_obs_dur_extra 17 1 1
CAL odb_mstart_time 21 1 1
CAL odb_mend_time 21 1 1
CAL odb_trans_stime 21 1 1
CAL odb_trans_etime 21 1 1
CAL odb_trans_wstime 21 1 1
CAL odb_trans_wetime 21 1 1
CAL odb_sclose_time 21 1 1
CAL odb_eclose_time 21 1 1
CAL odb_mclose_time 21 1 1
CAL odb_pclose_time 21 20 1
CAL odb_pclose_id 8 20 1
CAL odb_kclose_time 21 20 1
CAL odb_kclose_id 8 20 1
VIS odb_rec_type 3 1 1
VIS odb_obs_id 8 1 1
VIS odb_vis_type 8 1 1
VIS odb_event_time 21 1 1
IDL odb_rec_type 3 1 1
IDL odb_istart_time 21 1 1
IDL odb_iend_time 21 1 1
PBK odb_rec_type 3 1 1
PBK odb_start_time 21 1 1
PBK odb_end_time 21 1 1
COM odb_rec_type 3 1 1
COM odb_start_time 21 1 1
COM odb_end_time 21 1 1
MOM odb_rec_type 3 1 1
MOM odb_start_time 21 1 1
MOM odb_end_time 21 1 1
TLM odb_rec_type 3 1 1
TLM odb_start_time 21 1 1
TLM odb_end_time 21 1 1
ACT odb_rec_type 3 1 1
ACT odb_start_time 21 1 1
ACT odb_end_time 21 1 1
CMT odb_rec_type 3 1 1
CMT odb_obs_id 8 1 1
CMT odb_comment_file 80 1 1
ERR odb_rec_type 3 1 1
ERR odb_obs_id 8 1 1
ERR odb_comment_file 80 1 1
