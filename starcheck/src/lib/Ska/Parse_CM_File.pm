
package Ska::Parse_CM_File;

###############################################################
#
# Parse one of several types of files produced in OFLS
# command management
#
# Part of the starcheck cvs project
#
###############################################################

use strict;
use warnings;
use POSIX qw( ceil);

use IO::All;
use Carp;

use Ska::Starcheck::Python qw(date2time time2date);


my $VERSION = '$Id$';  # '
1;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

require Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw();
our @EXPORT_OK = qw( );
%EXPORT_TAGS = ( all => \@EXPORT_OK );

###############################################################
sub rel_date2time{
###############################################################

    # Return seconds when suppled a "relative datetime" of the
    # format 000:00:00:00.000 (DOY:HH:MM:SS.sss).
    my $date = shift;

    # The old code here uses reverse to just ignore a year if
    # included in the string.
    my ($sec, $min, $hr, $doy) = reverse split ":", $date;
    return ($doy*86400 + $hr*3600 + $min*60 + $sec);
}

###############################################################
sub TLR_load_segments{
###############################################################
    my $tlr_file = shift;

    my @segment_times;
    my @tlr = io($tlr_file)->slurp;

    my @segment_start_lines = grep /START\sOF\sNEW\sOBC\sLOAD,\sCL\d{3}:\d{4}/, @tlr;

    for my $line (@segment_start_lines){
        if ( $line =~ /(\d{4}:\d{3}:\d{2}:\d{2}:\d{2}\.\d{3})\s+START\sOF\sNEW\sOBC\sLOAD,\s(CL\d{3}\:\d{4})/ ){
            my $time = $1;
            my $seg_id = $2;
            push @segment_times, { date => $time, seg_id => $seg_id };
        }

    }


    return @segment_times;

}



###############################################################
sub dither {
    # Takes dither history file, array of backstop commands, and a kadi dynamic states "state".
    # The kadi dynamic states state is fetched/intended to be the state just before the first
    # backstop command.  It is a reference to a hash with keys 'time', 'dither' (ENAB/DISA),
    # 'dither_ampl_pitch', 'dither_ampl_yaw', 'dither_period_pitch', 'dither_period_yaw'.
    #
    # This routine:
    # 1) confirms that the kadi state and the dither history file match with regard to
    #    the dither enabled/disabled status at the very start of products.
    # 2) confirms that the dither history file is readable and ends before the backstop starts
    # 3) builds an array of dither states using the backstop commands, starting with the fully
    #    determined state of the initial kadi dynamic state.
    # 4) returns a string for error status and the array of dither states
###############################################################
    my $dh_file = shift;      # Dither history file name
    my $bs_arr = shift;               # Backstop array reference
    my $kadi_dither = shift;
    my $dither_error;

    my $bs;

    my %dith_enab_cmd_map = ('DSDITH' => 'DISA',
                             'ENDITH' => 'ENAB',
                             'DITPAR' => undef);

    my @dh_state;
    my @dh_time;
    my @dh_params;

    # First get everything from DITHER
    # Parse lines like:
    # 2002262.094827395   | DSDITH  AODSDITH
    # 2002262.095427395   | ENDITH  AOENDITH

    my $dith_hist_fh = IO::File->new($dh_file, "r") or $dither_error = "Dither history file read err";
    my $date_start = time2date($bs_arr->[0]->{time} - 60 * 86400);
    while (<$dith_hist_fh>) {
	    if (/(\d\d\d\d)(\d\d\d)\.(\d\d)(\d\d)(\d\d) \d* \s+ \| \s+ (ENDITH|DSDITH)/x) {
            my ($yr, $doy, $hr, $min, $sec, $state) = ($1,$2,$3,$4,$5,$6);
            my $date = "$yr:$doy:$hr:$min:$sec";
            if ($date gt $date_start) {
                my $time = date2time($date);
                push @dh_state, $dith_enab_cmd_map{$state};
                push @dh_time, $time;
                push @dh_params, {};
            }
        }
    }
	$dith_hist_fh->close();

    if (not defined $dither_error){
        # If the most recent/last entry in the dither file has a timestamp newer than
        # the first entry in the load, return string error and undef dither history.
        if ($dh_time[-1] >= $bs_arr->[0]->{time}){
        $dither_error = "Dither history runs into load\n";
        }

        # Confirm that last state matches kadi continuity ENAB/DISA.
        # Otherwise, return string error and undef dither history.
        if ($kadi_dither->{'dither'} ne $dh_state[-1]){
            $dither_error = "Dither status in kadi commands does not match DITHER history\n"
                        . sprintf("kadi '%s' ; History '%s' \n",
                                    $kadi_dither->{'dither'}, $dh_state[-1]);
        }
    }


    # Now make an array of hashes as the final output.  Keep track of where the info
    # came from to assist in debugging ('source' key)
    my @dither;
    my $bs_start = $bs_arr->[0]->{time};
    my $r2a = 3600. * 180. / 3.14159265;
    my $pi = 3.14159265;


    my $dither_enab = $kadi_dither->{'dither'};
    my $dither_ampl_p = $kadi_dither->{'dither_ampl_pitch'};
    my $dither_ampl_y = $kadi_dither->{'dither_ampl_yaw'};
    my $dither_period_p = $kadi_dither->{'dither_period_pitch'};
    my $dither_period_y = $kadi_dither->{'dither_period_yaw'};

    push @dither, { 'time' => $kadi_dither->{'time'},
                    'state' => $dither_enab,
                    'source' => 'kadi',
                    'ampl_p' => $dither_ampl_p,
                    'ampl_y' => $dither_ampl_y,
                    'period_p' => $dither_period_p,
                    'period_y' => $dither_period_y};



    # Build dither states using just kadi initial state and backstop cmds
    foreach $bs (@{$bs_arr}) {
        # Skip all commands except ones that could be dither related
	if ($bs->{cmd} =~ '(COMMAND_SW|MP_DITHER)') {
	    my %params = %{$bs->{command}};
	    if ($params{TLMSID} =~ 'AO(DSDITH|ENDITH|DITPAR)') {
                my $dith_string = $1;
                # The "if defined" logic for each means that the AODITPAR does not
                # change the dither-enabled status, and the AOENDITH, does not change
                # the dither parameters...
                $dither_enab = $dith_enab_cmd_map{$dith_string}
                    if defined $dith_enab_cmd_map{$dith_string};
                $dither_ampl_p = $params{COEFP} * $r2a if defined $params{COEFP};
                $dither_ampl_y = $params{COEFY} * $r2a if defined $params{COEFY};
                $dither_period_p = 1 / ($params{RATEP} / (2 * $pi))
                    if defined $params{RATEP};
                $dither_period_y = 1 / ($params{RATEY} / (2 * $pi))
                    if defined $params{RATEP};
                # If disabled, reset the amplitudes to be 0.  The params may be nonzero onboard
                # but we're more interested in the effective amplitudes for starcheck.
                push @dither, { time => $bs->{time},
                                state => $dither_enab,
                                source => 'backstop',
                                ampl_p => $dither_enab eq 'DISA' ? 0 : $dither_ampl_p,
                                ampl_y => $dither_enab eq 'DISA' ? 0 : $dither_ampl_y,
                                period_p => $dither_period_p,
                                period_y => $dither_period_y,
                                tlmsid => $params{TLMSID},
                            };
            }
        }
    }
    return ($dither_error, \@dither);
}


###############################################################
sub radmon {
###############################################################
    my $h_file = shift;      # Radmon history file name
    my $bs_arr = shift;               # Backstop array reference
    my $bs;
    my @bs_state;
    my @bs_time;
    my @bs_date;
    my @bs_params;
    my @h_state;
    my @h_time;
    my @h_date;
    my %cmd = ('DS' => 'DISA',
	       'EN' => 'ENAB');
    my %obs;
    # First get everything from backstop
    foreach $bs (@{$bs_arr}) {
	if ($bs->{cmd} =~ '(COMMAND_SW)') {
	    my %params = %{$bs->{command}};
	    if ($params{TLMSID} =~ 'OORMP(DS|EN)') {
		push @bs_state, $cmd{$1};
		push @bs_time, $bs->{time};  # see comment below about timing
		push @bs_date, $bs->{date};
		push @bs_params, { %params };
	    }
	}
    }

    # Now get everything from RADMON.txt
    # Parse lines like:
    # 2012222.011426269 | ENAB OORMPEN
    # 2012224.051225059 | DISA OORMPDS
    my $hist_fh = IO::File->new($h_file, "r") or return (undef, undef);
    my $date_start = time2date($bs_arr->[0]->{time} - 60 * 86400);
	while (<$hist_fh>) {
            if (/(\d\d\d\d)(\d\d\d)\.(\d\d)(\d\d)(\d\d) \d* \s+ \| \s+ (DISA|ENAB) \s+ (OORMPDS|OORMPEN)/x) {
            my ($yr, $doy, $hr, $min, $sec, $state) = ($1,$2,$3,$4,$5,$6);
            my $date = "$yr:$doy:$hr:$min:$sec";
            if ($date gt $date_start) {
                my $time = date2time($date);
                my $date = "$yr:$doy:$hr:$min:$sec";
                push @h_date, $date;
                push @h_state, $state;
                push @h_time, $time;
            }
        }
    }
	$hist_fh->close();

    my @ok = grep { $h_time[$_] < $bs_arr->[0]->{time} } (0 .. $#h_time);
    my @state = (@h_state[@ok], @bs_state);
    my @time   = (@h_time[@ok], @bs_time);
    my @date   = (@h_date[@ok], @bs_date);

    # if the most recent/last entry in the dither file has a timestamp newer than
    # the first backstop time, set the time violation flag and return undef for
    # @radmon
    my $time_violation = ($h_time[-1] >= $bs_arr->[0]->{time});
    if ($time_violation){
      return ($time_violation, undef);
    }

    # Now make an array of hashes as the final output.  Keep track of where the info
    # came from to assist in debugging
    my $bs_start = $bs_arr->[0]->{time};
    my @radmon = map { { time => $time[$_],
                         date => $date[$_],
                         state => $state[$_],
                         source => $time[$_] < $bs_start ? 'history' : 'backstop'}
                     } (0 .. $#state);
    return ($time_violation, \@radmon);

}


###############################################################
sub fidsel {
###############################################################
    my $fidsel_file = shift;	# FIDSEL file name
    my $bs          = shift;	# Reference to backstop array
    my $error = [];
    my %time_hash = ();		# Hash of time stamps of fid cmds

    my @fs = ();
    foreach (0 .. 14) {
	$fs[$_] = [];
    }

    my ($actions, $times, $fid_time_violation) = get_fid_actions($fidsel_file, $bs);

    # Check for duplicate commanding
    map { $time_hash{$_}++ } @{$times};
#    foreach (sort keys %time_hash) {
#	push @{$error}, "ERROR - $time_hash{$_} fid hardware commands at time $_\n"
#	    if ($time_hash{$_} > 1);
#    }

    for (my $i = 0; $i <= $#{$times}; $i++) {
	# If command contains RESET, then turn off (i.e. set tstop) any
	# fid light that is on
	if ($actions->[$i] =~ /RESET/) {
	    foreach my $fid (1 .. 14) {
		foreach my $fid_interval (@{$fs[$fid]}) {
		    $fid_interval->{tstop} = $times->[$i] unless ($fid_interval->{tstop});
		}
	    }
	}
	# Otherwise turn fid on by adding a new entry with tstart=time
	elsif ((my $fid) = ($actions->[$i] =~ /FID\s+(\d+)\s+ON/)) {
	    push @{$fs[$fid]}, { tstart => $times->[$i] };
	} else {
	    push @{$error}, "Parse_cm_file::fidsel: WARNING - Could not parse $actions->[$i]";
	}
    }

    return ($fid_time_violation, $error, \@fs);
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
    my $fidsel_fh;

    # First get everything from backstop
    foreach $bs (@{$bs_arr}) {
	if ($bs->{cmd} eq 'COMMAND_HW') {
	    my %params = %{$bs->{command}};
	    if ($params{TLMSID} eq 'AFIDP') {
		my $msid = $params{MSID};
		push @bs_action, "$msid FID $1 ON" if ($msid =~ /AFLC(\d+)/);
		push @bs_action, "RESET" if ($msid =~ /AFLCRSET/);
		push @bs_time, $bs->{time} - 10;  # see comment below about timing
	    }
	}
    }

#    printf("first bs entry at %s, last entry at %s \n", $bs_time[0], $bs_time[-1]);

    # Now get everything from FIDSEL
    # Parse lines like:
    # 2001211.190730558   | AFLCRSET RESET
    # 2001211.190731558   | AFLC02D1 FID 02 ON
    if (defined $fs_file){
	my @fidsel_text = io($fs_file)->slurp;
	# take the last thousand entries if there are more than a 1000
	my @reduced_fidsel_text = @fidsel_text;
        if ($#fidsel_text > 1000){
            @reduced_fidsel_text = @fidsel_text[($#fidsel_text-1000) ... $#fidsel_text];
        }
#    if ($fs_file && ($fidsel_fh = new IO::File $fs_file, "r")) {
	for my $fidsel_line (@reduced_fidsel_text){
	    if ($fidsel_line =~ /(\d\d\d\d)(\d\d\d)\.(\d\d)(\d\d)(\d\d)\S*\s+\|\s+(AFL.+)/) {
		my ($yr, $doy, $hr, $min, $sec, $action) = ($1,$2,$3,$4,$5,$6);
		my $time = date2time("$yr:$doy:$hr:$min:$sec") - 10;

		if ($action =~ /(RESET|FID.+ON)/) {
		    # Convert to time, and subtract 10 seconds so that fid lights are
		    # on slightly before end of manuever.  In actual commanding, they
		    # come on about 1-2 seconds *after*.

		    push @fs_action, $action;
		    push @fs_time, $time;
		}
	    }
	}

#	$fidsel_fh->close();
    }

#    printf("count of fid entries is %s \n", scalar(@fs_time));
#    printf("first fs entry at %s, last entry at %s \n", $fs_time[0], $fs_time[-1]);

    my @ok = grep { $fs_time[$_] < $bs_arr->[0]->{time} } (0 .. $#fs_time);
    my @action = (@fs_action[@ok], @bs_action);
    my @time   = (@fs_time[@ok], @bs_time);

    my $fid_time_violation = 0;

    # if the fid history extends into the current load
    if ($fs_time[-1] >= $bs_arr->[0]->{time}){
	$fid_time_violation = 1;
    }

    return (\@action, \@time, $fid_time_violation);
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
    my @cols;
    open (my $MANERR, $man_err)
	or die "Couldn't open maneuver error file $man_err for reading\n";
    while (<$MANERR>) {
        chomp;
	last if (/total number/i);
        next unless (/\S/);
        next if (/#Schedule generated/);
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
	close $MANERR;
    return @me;
}

###############################################################
sub backstop {
###############################################################
    my $backstop = shift;

    my @bs = ();
    open (my $BACKSTOP, $backstop) || die "Couldn't open backstop file $backstop for reading\n";
    while (<$BACKSTOP>) {
	my ($date, $vcdu, $cmd, $params) = split '\s*\|\s*', $_;
	$vcdu =~ s/ +.*//; # Get rid of second field in vcdu
	my %command = parse_params($params);
	push @bs, { date => $date,
		    vcdu => $vcdu,
		    cmd  => $cmd,
		    params => $params,
		    time => date2time($date),
		    command => \%command,
		};
    }
    close $BACKSTOP;

    return @bs;
}


###############################################################
sub DOT {
###############################################################
    my $dot_file = shift;

    # Break DOT down into commands, each with a unique ID (with index)

    my %command;
    my %index;
    my %dot;
    my %linenum;
    my $touched_by_sausage = 0;


    open (my $DOT, $dot_file) || die "Couldn't open DOT file $dot_file\n";
    while ( <$DOT> ) {
        chomp;
        next unless (/\S/);
        next if (/^\!Schedule generated/);
        if ( /MTLB/ or /M\d{3}$/ ){
            $touched_by_sausage = 1;
        }
        my ($cmd, $id) = /(.+) +(\S+)....$/;
        $index{$id} = "0001" unless (exists $index{$id});
        $cmd =~ s/\s+$//;
        my $id_index = "$id$index{$id}";
        $command{$id_index} .= $cmd;
        $linenum{$id_index} = $. unless exists $linenum{$id_index}; # Perl file line number for <..>

        # If there is no continuation character "," then DOT command is complete
        $index{$id} = sprintf("%04d", $index{$id}+1) unless ($cmd =~ /,$/);

    }
    close $DOT;

    foreach (keys %command) {
        %{$dot{$_}} = parse_params($command{$_});
        $dot{$_}{time}  = date2time($dot{$_}{TIME}) if ($dot{$_}{TIME});

	# MANSTART is in the dot as a "relative" time like "000:00:00:00.000", so just pass it
	# to the rel_date2time routine designed to handle that.
        $dot{$_}{time} += rel_date2time($dot{$_}{MANSTART}) if ($dot{$_}{TIME} && $dot{$_}{MANSTART});
        $dot{$_}{cmd_identifier} = "$dot{$_}{anon_param1}_$dot{$_}{anon_param2}"
            if ($dot{$_}{anon_param1} and $dot{$_}{anon_param2});
        $dot{$_}{linenum} = $linenum{$_};
        ($dot{$_}{oflsid}) = /^\S0*(\S+)\S{4}/;  # This will always succeed
        $dot{$_}{id} = $_;
        $dot{$_}{command} = $command{$_};
    }

    # Generate list of DOT cmd structures ordered by line number
    my @ordered_dot = sort { $a->{linenum} <=> $b->{linenum} } values %dot;

    return (\%dot, $touched_by_sausage, \@ordered_dot);


}




##***************************************************************************
sub guide{
##***************************************************************************
# Take in name of guide star summary file
# return hash that contains
# target obsid, target dec, target ra, target roll
# and an array of the lines of the catalog info

    my $guide_file = shift;

    my %guidesumm;

    # Let's slurp the file instead of reading it a line at a time
    my $whole_guide_file = io($guide_file)->slurp;

    # And then, let's split that file into chunks by processing request
    # By chunking I can guarantee that an error parsing the ID doesn't cause the
    # script to blindly overwrite the RA and DEC and keep adding to the starcat..
    my @file_chunk = split /\n\n\n\*\*\*\* PROCESSING REQUEST \*\*\*\*\n/, $whole_guide_file;

    # Skip the first block in the file (which has no catalog) by using the index 1-end

    for my $chunk_number (1 .. $#file_chunk){

	# Then, for each chunk, split into a line array
	my @file_chunk_lines = split /\n/, $file_chunk[$chunk_number];

	# Now, since my loop is chunk by chunk, I can clear these for every chunk.
	my ($ra, $dec, $roll);
	my ($oflsid, $gsumid);

	foreach my $line (@file_chunk_lines){

	    # Look for an obsid, ra, dec, or roll
	    if ($line =~ /\s+ID:\s+([[:ascii:]]{5})\s+\((\S{3,5})\)/) {
		my @field = ($1, $2);
	    	($oflsid = $field[0]) =~ s/^0*//;
		($gsumid = $field[1]) =~ s/^0*//;
	    	$guidesumm{$oflsid}{guide_summ_obsid}= $gsumid;
	    }
	    if ($line =~ /\s+ID:\s+([[:ascii:]]{7})\s*$/) {
		($oflsid = $1) =~ s/^0*//;
		$oflsid =~ s/00$//;
	    }

	    # Skip the rest of the block for each line if
	    # oflsid hasn't been found/defined

	    next unless (defined $oflsid);

	    if ($line =~ /\s+RA:\s*([^ ]+) DEG/){
		$ra = $1;
		$guidesumm{$oflsid}{ra}=$ra;
	    }
	    if ($line =~ /\s+DEC:\s*([^ ]+) DEG/){
		$dec = $1;
		$guidesumm{$oflsid}{dec}=$dec;
	    }
	    if ($line =~ /ROLL \(DEG\):\s*([^ ]+)/){
		$roll = $1;
		$guidesumm{$oflsid}{roll}=$roll;
	    }

	    if ($line =~ /^(FID|ACQ|GUI|BOT)/) {
		push @{$guidesumm{$oflsid}{info}},  $line;

	    }
	    if ($line =~ /^MON/){
		my @l= split ' ', $line;
		if (scalar(@l) == 8){
		    push @{$guidesumm{$oflsid}{info}}, "MON --- $l[2] $l[3] --- $l[5] $l[6] $l[7]";
		}
		else{
		    push @{$guidesumm{$oflsid}{info}}, "MON --- $l[2] $l[3] --- $l[5] $l[6]";
		}
	    }
	}
    }

    return %guidesumm;

}


###############################################################
sub OR {
###############################################################
    my $or_file = shift;
    my %or;
    my %obs;
    my $obs;


    open (my $OR, $or_file) || die "Couldn't open OR file $or_file\n";
    my $in_obs_statement = 0;
    while (<$OR>) {
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
    close $OR;
    return %or;
}

###############################################################
sub OR_parse_obs {
###############################################################
    $_ = shift;
#    print STDERR "test $_ \n";

    my @obs_columns = qw(obsid TARGET_RA TARGET_DEC TARGET_NAME
			 SI TARGET_OFFSET_Y TARGET_OFFSET_Z
			 SIM_OFFSET_X SIM_OFFSET_Z GRATING MON_RA MON_DEC SS_OBJECT);
    # Init some defaults
    my %obs = ();
#    print STDERR "In OR_Parse_obs \n";
    foreach (@obs_columns) {
	$obs{$_} = '';
    }
    ($obs{TARGET_RA}, $obs{TARGET_DEC}) = (0.0, 0.0);
    ($obs{TARGET_OFFSET_Y}, $obs{TARGET_OFFSET_Z}) = (0.0, 0.0);
    ($obs{SIM_OFFSET_X}, $obs{SIM_OFFSET_Z}) = (0, 0);

    $obs{obsid} = 0+$1 if (/ID=(\d+),/);
    ($obs{TARGET_RA}, $obs{TARGET_DEC}) = ($1, $2)
	if (/TARGET=\(([^,]+),([^,\)]+)/);
    ($obs{MON_RA}, $obs{MON_DEC}, $obs{HAS_MON}) = ($1, $2, 1)
	if (/STAR=\(([^,]+),([^,\)]+)/);
    $obs{TARGET_NAME} = $3
	if (/TARGET=\(([^,]+),([^,]+),\s*\{([^\}]+)\}\),/);
    $obs{SS_OBJECT} = $1 if (/SS_OBJECT=([^,\)]+)/);
    $obs{SI} = $1 if (/SI=([^,]+)/);
 #   print STDERR "obsSI = $obs{SI} \n";
    if (/TARGET_OFFSET=\((-?[\d\.]+),(-?[\d\.]+)\)/){
        ($obs{TARGET_OFFSET_Y}, $obs{TARGET_OFFSET_Z}) = ($1, $2);
    }
    elsif (/TARGET_OFFSET=\((-?[\d\.]+)\)/){
        $obs{TARGET_OFFSET_Y} = $1;
    }
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
sub PS {
# Parse processing summary
# Actually, just read in the juicy lines in the middle
#   which are maneuvers or observations and store them
#   to a line array
###############################################################
    my $ps_file = shift;
    my @ps;

    my @ps_all_lines = io($ps_file)->slurp;

    my $date_re = '\d{4}:\d{3}:\d{2}:\d{2}:\d{2}\.\d{3}';
    my $rel_date_re = '\d{3}:\d{2}:\d{2}:\d{2}\.\d{3}';

    for my $ps_line (@ps_all_lines){
        if ($ps_line =~ /.*${date_re}\s+${date_re}\s+${rel_date_re}.*/){
            my @tmp = split ' ', $ps_line;
            if ($tmp[1] eq 'MANVR') {
                push @ps, $ps_line;
            }
            if ($tmp[1] eq 'OBS') {
                push @ps, $ps_line;
            }
            if (($ps_line =~ /OBSID\s=\s(\d\d\d\d\d)/) && (scalar(@tmp) >= 8)) {
                push @ps, $ps_line;
            }
        }
    }
    return @ps;
}



###############################################################
sub MM {
# Parse maneuver management (?) file
###############################################################
# This accepts a reference to a hash as the only argument
# the return type may be specified in the hash as 'hash' or 'array'
# default return is hash
# With regard to the return data:


    my $arg_ref = shift;
    my $mm_file = $arg_ref->{file};
    my $ret_type = 'hash';

    if ( defined $arg_ref->{ret_type} ){
        $ret_type = $arg_ref->{ret_type};
    }

    my $manvr_offset = 10; # seconds expected from AONMMODE to AOMANUVR

    my @mm_array;

    my $mm_text = io($mm_file)->slurp;
    # split the file into maneuvers
    my @sections = split(/MANEUVER\sDATA\sSUMMARY\n/, $mm_text);
    # ignore pieces of the file without ATTITUDES
    my @good_sect = grep {/INITIAL|FINAL/} @sections;

    my $int_obsid = 'IN_IA';
    for my $entry (@good_sect){
        # only keep the relevant bits of each entry (before OUTPUT DATA)
        my @para = split( /\n\n/, $entry);
        my @attitudes = grep {/ATTITUDE/} @para;
        if (scalar(@attitudes) > 2){
            croak("Maneuver Summary has too many attitudes in section\n");
        }
        # where final or initial attitude may be an intermediate attitude
        my @output_data_match = grep {/OUTPUT\sDATA/} @para;
	my $output_data = $output_data_match[0];
        my $initial_attitude = $attitudes[0];
        my $final_attitude = $attitudes[1];

        my %manvr_hash;
        $manvr_hash{initial_obsid} = $1 if ($initial_attitude =~ /INITIAL ID:\s+(\S+)\S\S/);
        $manvr_hash{final_obsid}   = $1 if ($final_attitude =~ /FINAL ID:\s+(\S+)\S\S/);
        $manvr_hash{start_date}    = $1 if ($initial_attitude =~ /TIME\s*\(GMT\):\s+(\S+)/);
        $manvr_hash{stop_date}     = $1 if ($final_attitude =~ /TIME\s*\(GMT\):\s+(\S+)/);
        $manvr_hash{ra}            = $1 if ($final_attitude =~ /RA\s*\(deg\):\s+(\S+)/);
        $manvr_hash{dec}           = $1 if ($final_attitude =~ /DEC\s*\(deg\):\s+(\S+)/);
        $manvr_hash{roll}          = $1 if ($final_attitude =~ /ROLL\s*\(deg\):\s+(\S+)/);
        $manvr_hash{dur}           = $1 if ($output_data =~ /Duration\s*\(sec\):\s+(\S+)/);
        $manvr_hash{angle}         = $1 if ($output_data =~ /Maneuver Angle\s*\(deg\):\s+(\S+)/);
        my @quat                   = ($1,$2,$3,$4) if ($final_attitude =~ /Quaternion:\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/);
        $manvr_hash{q1} = $quat[0];
        $manvr_hash{q2} = $quat[1];
        $manvr_hash{q3} = $quat[2];
        $manvr_hash{q4} = $quat[3];
        $manvr_hash{tstart} = date2time($manvr_hash{start_date});
        $manvr_hash{tstop} = date2time($manvr_hash{stop_date});

	# let's just add those 10 seconds to the summary tstart so it lines up with
	# AOMANUVR in backstop
	$manvr_hash{tstart} += $manvr_offset;
	$manvr_hash{start_date} = time2date($manvr_hash{tstart});

        # clean up obsids (remove prepended 0s)
        if (defined $manvr_hash{initial_obsid}) {
            $manvr_hash{initial_obsid} =~ s/^0+//;
        }
        # use a dummy or the last initial attitude if there isn't one
        else {
            $manvr_hash{initial_obsid} = $int_obsid;
        }

        if (defined $manvr_hash{final_obsid}) {
            $manvr_hash{final_obsid} =~ s/^0+//;
        }
        else{
            $int_obsid = $manvr_hash{initial_obsid} . '_IA';
            $manvr_hash{final_obsid} = $int_obsid;
        }

	$manvr_hash{obsid} = $manvr_hash{final_obsid};
        push @mm_array, \%manvr_hash;

    }

    # create a manvr_dest key to record the eventual destination of
    # all manvrs.
    for my $i (0 .. $#mm_array){
	# by default the destination is just the final_obsid
	$mm_array[$i]->{manvr_dest} = $mm_array[$i]->{final_obsid};
	# but if the final_obsid has the string that indicates it is
	# an intermediate attitude, loop through the rest of the manvrs
	# until we hit one that isn't an intermediate attitude
	next unless ($mm_array[$i]->{final_obsid} =~ /_IA/);
	for my $j ($i .. $#mm_array){
	    next if ($mm_array[$j]->{final_obsid} =~ /_IA/);
	    $mm_array[$i]->{manvr_dest} = $mm_array[$j]->{final_obsid};
	    last;
	}
    }

    if ($ret_type eq 'array'){
        return @mm_array;
    }

    my %mm_hash;
    for my $manvr (0 ... $#mm_array ){
        my $obsid = $mm_array[$manvr]->{final_obsid};
	$mm_hash{$obsid} = $mm_array[$manvr];
    }

    return %mm_hash;

}


##***************************************************************************
sub mechcheck {
##***************************************************************************
    my $mc_file = shift;
    my @mc;
    my ($date, $time, $cmd, $dur, $text);
    my %evt;
    my $SIM_FA_RATE = 90.0;	# Steps per seconds  18steps/shaft

    open my $MC, $mc_file or die "Couldn't open mech check file $mc_file\n";
    while (<$MC>) {
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
    close $MC;

    return @mc;
}

##***************************************************************************
sub SOE {
##***************************************************************************
    my    $soe_file = shift;
# Taken from RAC's code /proj/sot/ska/ops/soe/soeA.pl

# read the SOE record formats into the hashes of lists $fld and $len
    my (%fld, %len, $obsidx);
    my (%rlen, %templ);
    while (<DATA>) {
	my ($rtype,$rfld,$rlen,$rdim1,$rdim2) = split;
	for my $j (0 .. $rdim2-1) {
	    for my $i (0 .. $rdim1-1) {
		my $idx = '';
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

    open my $SOE, $soe_file or die "Couldn't open SOE file '$soe_file'\n";
    my $soe = (<$SOE>);
    my $l = length $soe;

# unpack the SOE file
    my %SOE;
    my $p = 0;
    while ($p < $l) {
	my $typ = substr $soe,$p,3;
	if (exists $rlen{$typ}) {
	    my $rec = substr $soe,$p,$rlen{$typ};
	    my @rvals = unpack $templ{$typ},$rec;
	    my @rflds = @{ $fld{$typ} };
	    my @rlens = @{ $len{$typ} };
	    my $obsid = ($typ eq "OBS" or $typ eq "CAL")? "$rvals[$obsidx] " : "";
	    $obsid =~ s/^0+//;
	    $obsid =~ s/\s//g;
	    if ($obsid) {
		foreach my $i (0 .. $#rvals) {
		    $SOE{$obsid}{$rflds[$i]} = $rvals[$i];
		}
	    }
	    $p += $rlen{$typ};
	} else {
	    die "Parse_CM_File::SOE: Cannot identify record of type $typ\n ";
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
    my %odb;

    open (my $ODB, $odb_file) || die "Couldn't open $odb_file\n";
    while (<$ODB>) {
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

    close $ODB;

    return (%odb);
}



##***************************************************************************
sub parse_params{
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
SIR odb_rec_type 3 1 1
SIR odb_instance_num 2 1 1
SIR odb_req_id 8 1 1
SIR odb_obs_id 5 1 1
SIR odb_obs_start_time 21 1 1
SIR odb_obs_end_time 21 1 1
SIR odb_obs_dur 17 1 1
SIR odb_obs_dur_extra 17 1 1
