package Parse_CM_File;

###############################################################
#
# Parse one of several types of files produced in OFLS 
# command management
#
###############################################################

use POSIX;
use lib '/proj/rad1/ska/lib/perl5/local';
use TomUtil;
use Time::JulianDay;
use Time::DayOfYear;
use Time::Local;

1;

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
	$in_obs_statement = 1 if (/^OBS,\s*$/);
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
			 SIM_OFFSET_X SIM_OFFSET_Z GRATING);
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
    $obs{TARGET_NAME} = $3
	if (/TARGET=\(([^,]+),([^,]+),\{([^\}]+)\}\),/);
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
        $obsid = $2 if (/(INITIAL|FINAL) ID:\s+(\S+)\S\S/);
	$start_date = $1 if ($start_stop && /TIME\(GMT\):\s+(\S+)/);
	$stop_date  = $1 if (! $start_stop && /TIME\(GMT\):\s+(\S+)/);
	$ra         = $1 if (/RA\(deg\):\s+(\S+)/);
	$dec        = $1 if (/DEC\(deg\):\s+(\S+)/);
	$roll       = $1 if (/ROLL\(deg\):\s+(\S+)/);
	$dur        = $1 if (/Duration\(sec\):\s+(\S+)/);
	$angle      = $1 if (/Maneuver Angle\(deg\):\s+(\S+)/);
	@quat       = ($1,$2,$3,$4) if (/Quaternion:\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/);

	if (/Profile Parameters/) { # Effective end of maneuver statement
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
# Taken from RAC's code /proj/gads6/ops/soe/soeA.pl

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
