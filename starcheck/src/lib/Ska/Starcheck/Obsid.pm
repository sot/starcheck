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
use Ska::Starcheck::Python qw(date2time time2date call_python);

use List::Util qw(min max);
use Quat;
use File::Basename;
use POSIX qw(floor);
use English;
use IO::All;

use RDB;

use Carp;

# Constants

my $VERSION = '$Id$';    # '
my $ER_MIN_OBSID = 38000;
my $r2a = 3600. * 180. / 3.14159265;
my $faint_plot_mag = 11.0;
my %Default_SIM_Z = (
    'ACIS-I' => 92905,
    'ACIS-S' => 75620,
    'HRC-I' => -50505,
    'HRC-S' => -99612
);

my $font_stop = qq{</font>};
my ($red_font_start, $blue_font_start, $orange_font_start, $yellow_font_start);

my $ID_DIST_LIMIT = 1.5;    # 1.5 arcsec box for ID'ing a star

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
    bless($self);

    $self->{obsid} = shift;
    $self->{date} = shift;
    $self->{dot_obsid} = $self->{obsid};
    @{ $self->{warn} } = ();
    @{ $self->{orange_warn} } = ();
    @{ $self->{yellow_warn} } = ();
    @{ $self->{fyi} } = ();
    $self->{n_guide_summ} = 0;
    @{ $self->{commands} } = ();
    %{ $self->{agasc_hash} } = ();

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
    push @{ $self->{commands} }, $_[0];
}

##################################################################################
sub set_config {

    # Import characteristics from characteristics file
##################################################################################
    my $config_ref = shift;
    %config = %{$config_ref};

    # Set the ACA planning (red) and penalty (yellow) limits if defined.
    $config{'ccd_temp_red_limit'} =
      call_python('calc_ccd_temps.aca_t_ccd_planning_limit');
    $config{'ccd_temp_yellow_limit'} =
      call_python('calc_ccd_temps.aca_t_ccd_penalty_limit');
}

##################################################################################
sub set_odb {

    # Import %odb variable into starcheck_obsid package
##################################################################################
    %odb = @_;
    $odb{"ODB_TSC_STEPS"}[0] =~ s/D/E/;
}

##################################################################################
sub set_ACA_bad_pixels {
##################################################################################
    my $pixel_file = shift;
    my @tmp = io($pixel_file)->slurp;
    my @lines = grep { /^\s+(\d|-)/ } @tmp;
    foreach (@lines) {
        my @line = split /;|,/, $_;
        foreach my $i ($line[0] .. $line[1]) {
            foreach my $j ($line[2] .. $line[3]) {
                my $pixel = {
                    'row' => $i,
                    'col' => $j
                };
                push @bad_pixels, $pixel;
            }
        }
    }

    print STDERR "Read ", ($#bad_pixels + 1), " ACA bad pixels from $pixel_file\n";
}

##################################################################################
sub set_bad_acqs {
##################################################################################

    my $rdb_file = shift;
    if (-r $rdb_file) {
        my $rdb = new RDB $rdb_file or warn "Problem Loading $rdb_file\n";

        my %data;
        while ($rdb && $rdb->read(\%data)) {
            $bad_acqs{ $data{'agasc_id'} }{'n_noids'} = $data{'n_noids'};
            $bad_acqs{ $data{'agasc_id'} }{'n_obs'} = $data{'n_obs'};
        }

        undef $rdb;
        return 1;
    }
    else {
        return 0;
    }

}

##################################################################################
sub set_bad_gui {
##################################################################################

    my $rdb_file = shift;
    if (-r $rdb_file) {
        my $rdb = new RDB $rdb_file or warn "Problem Loading $rdb_file\n";

        my %data;
        while ($rdb && $rdb->read(\%data)) {
            $bad_gui{ $data{'agasc_id'} }{'n_nbad'} = $data{'n_nbad'};
            $bad_gui{ $data{'agasc_id'} }{'n_obs'} = $data{'n_obs'};
        }

        undef $rdb;
        return 1;
    }
    else {
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

    print STDERR "Read ", (scalar keys %bad_id), " bad AGASC IDs from $bad_file\n";
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
    my $gs = shift;    # Guide summary
    my $oflsid = $self->{dot_obsid};
    my $gs_obsid;
    my $bs_obsid;
    my $mp_obsid_cmd = find_command($self, "MP_OBSID");
    $gs_obsid = $gs->{$oflsid}{guide_summ_obsid} if defined $gs->{$oflsid};
    $bs_obsid = $mp_obsid_cmd->{ID} if $mp_obsid_cmd;
    $self->{obsid} = $bs_obsid || $gs_obsid || $oflsid;

    if (defined $bs_obsid and defined $gs_obsid and $bs_obsid != $gs_obsid) {
        push @{ $self->{warn} },
          sprintf("Obsid mismatch: guide summary %d != backstop %d\n",
            $gs_obsid, $bs_obsid);
    }
}

##################################################################################
sub print_cmd_params {
##################################################################################
    my $self = shift;
    foreach my $cmd (@{ $self->{commands} }) {
        print "  CMD = $cmd->{cmd}\n";
        foreach my $param (keys %{$cmd}) {
            print "   $param = $cmd->{$param}\n";
        }
    }
}

##################################################################################
sub set_files {
##################################################################################
    my $self = shift;
    (
        $self->{STARCHECK},
        $self->{backstop},
        $self->{guide_summ},
        $self->{or_file},
        $self->{mm_file},
        $self->{dot_file},
        $self->{tlr_file}
    ) = @_;
}

##################################################################################
sub set_target {
    #
    # Set the ra, dec, roll attributes based on target
    # quaternion parameters in the target_md
    #
##################################################################################
    my $self = shift;

    my $manvr = find_command($self, "MP_TARGQUAT", -1);    # Find LAST TARGQUAT cmd
    ($self->{ra}, $self->{dec}, $self->{roll}) =
      $manvr
      ? quat2radecroll($manvr->{Q1}, $manvr->{Q2}, $manvr->{Q3}, $manvr->{Q4})
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
    my @commands =
      ($number > 0) ? @{ $self->{commands} } : reverse @{ $self->{commands} };
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
    # Find the maneuver for each dot obsid.
    #
##################################################################################
    my $self = shift;
    my $mm = shift;
    my $n = 1;
    my $c;
    my $found;

    while ($c = find_command($self, "MP_TARGQUAT", $n++)) {
        $found = 0;
        foreach my $m (@{$mm}) {
            my $manvr_obsid = $m->{final_obsid};

# where manvr_dest is either the final_obsid of a maneuver or the eventual destination obsid
            # of a segmented maneuver
            if (   ($manvr_obsid eq $self->{dot_obsid})
                && abs($m->{q1} - $c->{Q1}) < 1e-7
                && abs($m->{q2} - $c->{Q2}) < 1e-7
                && abs($m->{q3} - $c->{Q3}) < 1e-7)
            {
                $found = 1;
                foreach (keys %{$m}) {
                    $c->{$_} = $m->{$_};
                }

          # Set the default maneuver error (based on WS Davis data) and cap at 85 arcsec
                $c->{man_err} = (exists $c->{angle}) ? 35 + $c->{angle} / 2. : 85;
                $c->{man_err} = 85 if ($c->{man_err} > 85);

                # Get quat from MP_TARGQUAT (backstop) command.
                # Compute 4th component (as only first 3 are uplinked) and renormalize.
                # Intent is to match OBC Target Reference subfunction
                my $q4_obc = sqrt(abs(1.0 - $c->{Q1}**2 - $c->{Q2}**2 - $c->{Q3}**2));
                my $norm = sqrt($c->{Q1}**2 + $c->{Q2}**2 + $c->{Q3}**2 + $q4_obc**2);
                if (abs(1.0 - $norm) > 1e-6) {
                    push @{ $self->{warn} },
                      sprintf(
                        "Uplink quaternion norm value $norm is too far from 1.0\n");
                }

                my @c_quat_norm = (
                    $c->{Q1} / $norm,
                    $c->{Q2} / $norm,
                    $c->{Q3} / $norm,
                    $q4_obc / $norm
                );

   # Compare to quaternion used in $m (which provides {ra} {dec} {roll}) which was built
                # directly from the 4 components in Backstop
                my $q_man = Quat->new($m->{ra}, $m->{dec}, $m->{roll});
                my $q_obc = Quat->new(@c_quat_norm);
                my @q_man = @{ $q_man->{q} };
                my $q_diff = $q_man->divide($q_obc);

                if (   abs($q_diff->{ra0} * 3600) > 1.0
                    || abs($q_diff->{dec} * 3600) > 1.0
                    || abs($q_diff->{roll0} * 3600) > 10.0)
                {
                    push @{ $self->{warn} },
                      sprintf(
"Target uplink precision problem for MP_TARGQUAT at $c->{date}\n"
                          . "   Error is yaw, pitch, roll (arcsec) = %.2f  %.2f  %.2f\n"
                          . "   Use Q1,Q2,Q3,Q4 = %.12f %.12f %.12f %.12f\n",
                        $q_diff->{ra0} * 3600,
                        $q_diff->{dec} * 3600,
                        $q_diff->{roll0} * 3600,
                        $q_man[0], $q_man[1], $q_man[2], $q_man[3]
                      );
                }

            }

        }
        push @{ $self->{yellow_warn} },
          sprintf("Did not find match in maneuvers for MP_TARGQUAT at $c->{date}\n")
          unless ($found);

    }
}


##################################################################################
sub set_ps_times {

    # Get the observation start and stop times from the processing summary
    # Just planning to use the stop time on the last observation to check dither
    # (that observation has no maneuver after it)
##################################################################################
    my $self = shift;
    my @ps = @_;
    my $obsid = $self->{obsid};
    my $or_er_start;
    my $or_er_stop;

    for my $ps_line (@ps) {
        my @tmp = split ' ', $ps_line;
        next unless scalar(@tmp) >= 4;
        if ($tmp[1] eq 'OBS') {
            my $length = length($obsid);
            if (substr($tmp[0], 5 - $length, $length) eq $obsid) {
                $or_er_start = $tmp[2];
                $or_er_stop = $tmp[3];
                last;
            }
        }
        if (($ps_line =~ /OBSID\s=\s(\d\d\d\d\d)/) && (scalar(@tmp) >= 8)) {
            if ($obsid eq $1) {
                $or_er_start = $tmp[2];
                $or_er_stop = $tmp[3];
            }
        }
    }
    if (not defined $or_er_start or not defined $or_er_stop) {
        push @{ $self->{warn} }, "Could not find obsid $obsid in processing summary\n";
        $self->{or_er_start} = undef;
        $self->{or_er_stop} = undef;
    }
    else {
        $self->{or_er_start} = date2time($or_er_start);
        $self->{or_er_stop} = date2time($or_er_stop);
    }

}

#############################################################################################
sub set_npm_times {

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
    if ((defined $manvr) and (defined $manvr->{tstop})) {
        $obs_tstart = $manvr->{tstop};
    }
    else {
        $obs_tstart = date2time($self->{date});
    }

    # set the observation stop as the beginning of the next maneuever
    # or, if last obsid in load, use the processing summary or/er observation
    # stop time
    if (defined $self->{next}) {
        my $next_manvr = find_command($self->{next}, "MP_TARGQUAT", -1);
        if ((defined $next_manvr) & (defined $next_manvr->{tstart})) {
            $obs_tstop = $next_manvr->{tstart};
        }
        else {
            # if the next obsid doesn't have a maneuver (ACIS undercover or whatever)
            # just use next obsid start time
            my $next_cmd_obsid = find_command($self->{next}, "MP_OBSID", -1);
            if ((defined $next_cmd_obsid) and ($self->{obsid} != $next_cmd_obsid->{ID}))
            {
                push @{ $self->{fyi} },
"Next obsid has no manvr; using next obs start date for checks (dither, momentum)\n";
                $obs_tstop = $next_cmd_obsid->{time};
                $self->{no_following_manvr} = 1;
            }
        }
    }
    else {
        $obs_tstop = $self->{or_er_stop};
    }

    if (not defined $obs_tstart or not defined $obs_tstop) {
        push @{ $self->{warn} },
"Could not determine obsid start and stop times for checks (dither, momentum)\n";
    }
    else {
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
    $self->{fidsel} = [];   # Init to know that fids have been set and should be checked

 # Return unless there is a maneuver command and associated tstop value (from manv summ)

    return unless ($manvr = find_command($self, "MP_TARGQUAT", -1));

    return
      unless ($tstart = $manvr->{tstop});    # "Start" of observation = end of manuever

    # Loop through fidsel commands for each fid light and find any intervals
    # where fid is on at time $tstart

    for my $fid (1 .. 14) {
        foreach my $fid_interval (@{ $fidsel->[$fid] }) {
            if (
                $fid_interval->{tstart} <= $tstart
                && (!exists $fid_interval->{tstop} || $tstart <= $fid_interval->{tstop})
              )
            {
                push @{ $self->{fidsel} }, $fid;
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

    @{ $self->{fid} } = ();
    @{ $self->{gui} } = ();
    @{ $self->{acq} } = ();
    @{ $self->{mon} } = ();

    foreach my $i (1 .. 16) {
        $c->{"SIZE$i"} = $sizes[ $c->{"IMGSZ$i"} ];
        $c->{"MAG$i"} = ($c->{"MINMAG$i"} + $c->{"MAXMAG$i"}) / 2;
        $c->{"TYPE$i"} =
          ($c->{"TYPE$i"} or $c->{"MINMAG$i"} != 0 or $c->{"MAXMAG$i"} != 0)
          ? $types[ $c->{"TYPE$i"} ]
          : 'NUL';
        push @{ $self->{mon} }, $i if ($c->{"TYPE$i"} eq 'MON');
        push @{ $self->{fid} }, $i if ($c->{"TYPE$i"} eq 'FID');
        push @{ $self->{acq} }, $i
          if ($c->{"TYPE$i"} eq 'ACQ' or $c->{"TYPE$i"} eq 'BOT');
        push @{ $self->{gui} }, $i
          if ($c->{"TYPE$i"} eq 'GUI' or $c->{"TYPE$i"} eq 'BOT');
        $c->{"YANG$i"} *= $r2a;
        $c->{"ZANG$i"} *= $r2a;
        $c->{"HALFW$i"} =
            ($c->{"TYPE$i"} ne 'NUL')
          ? (40 - 35 * $c->{"RESTRK$i"}) * $c->{"DIMDTS$i"} + 20
          : 0;
        $c->{"HALFW$i"} = $monhalfw[ $c->{"IMGSZ$i"} ] if ($c->{"TYPE$i"} eq 'MON');
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

    my $dthr = shift;    # Ref to array of hashes containing dither states

    my $large_dith_thresh =
      30;    # Amplitude larger than this requires special checking/handling

    my $obs_beg_pad = 8 * 60;    # Check dither status at obs start + 8 minutes to allow
                                 # for disabled dither because of mon star commanding
    my $obs_end_pad = 3 * 60;
    my $manvr;

    unless (defined $dthr) {
        push @{ $self->{warn} }, "Dither states unavailable. Dither not checked\n";
        return;
    }

    # set the observation start as the end of the maneuver
    my $obs_tstart = $self->{obs_tstart};
    my $obs_tstop = $self->{obs_tstop};

    unless (defined $obs_tstart) {
        push @{ $self->{warn} },
          "Cannot determine obs start time for dither, not checking.\n";
        return;
    }

    # Determine guide dither by finding the last dither commanding before
    # the start of observation (+ 8 minutes)
    my $guide_dither;
    foreach my $dither_state (reverse @{$dthr}) {
        if ($obs_tstart + $obs_beg_pad >= $dither_state->{time}) {
            $guide_dither = $dither_state;
            last;
        }
    }

    # Determine dither at acquisition
    my $acq_dither;
    foreach my $dither_state (reverse @{$dthr}) {
        if ($obs_tstart >= $dither_state->{time}) {
            $acq_dither = $dither_state;
            last;
        }
    }

    $self->{dither_acq} = $acq_dither;
    $self->{dither_guide} = $guide_dither;
    $self->{dither_guide}->{ampl_y_max} = $guide_dither->{ampl_y};
    $self->{dither_guide}->{ampl_p_max} = $guide_dither->{ampl_p};

    # Check for standard dither
    if ($guide_dither->{state} eq 'ENAB') {
        if ((not standard_dither($guide_dither)) or not standard_dither($acq_dither)) {
            push @{ $self->{yellow_warn} }, "Non-standard dither\n";
        }
        if (   ($guide_dither->{ampl_p} != $acq_dither->{ampl_p})
            or ($guide_dither->{ampl_y} != $acq_dither->{ampl_y}))
        {
            push @{ $self->{fyi} },
              sprintf("Reviewed with ACQ dither Y=%.1f Z=%.1f \n",
                $acq_dither->{ampl_y}, $acq_dither->{ampl_p});
        }
    }

# Check for large dither.  If large dither present, run the large dither checks and set the obs_end_pad
    if ($guide_dither->{state} eq 'ENAB') {
        if (   $guide_dither->{ampl_y} > $large_dith_thresh
            or $guide_dither->{ampl_p} > $large_dith_thresh)
        {
            $self->large_dither_checks($guide_dither, $dthr);

            # If this is a large dither, set a larger pad at the end, as we expect
            # standard dither parameters to be commanded at 5 minutes before end,
            # which is greater than the 3 minutes used in the "no dither changes
            # during observation check below
            $obs_end_pad = 5.5 * 60;
        }
    }

    # Check for dither changes during the observation
    # ACA-003
    if (not defined $obs_tstop) {
        push @{ $self->{warn} },
"Unable to determine obs tstop; could not check for dither changes during obs\n";
    }
    else {
        foreach my $dither (reverse @{$dthr}) {
            if ($dither->{time} < $obs_tstop) {
                $self->{dither_guide}->{ampl_p_max} =
                  max(($dither->{ampl_p}, $self->{dither_guide}->{ampl_p_max}));
                $self->{dither_guide}->{ampl_y_max} =
                  max(($dither->{ampl_y}, $self->{dither_guide}->{ampl_y_max}));
            }
            if (   $dither->{time} > ($obs_tstart + $obs_beg_pad)
                && $dither->{time} <= $obs_tstop - $obs_end_pad)
            {
                push @{ $self->{warn} },
                  "Dither commanding at $dither->{time}.  During observation.\n";
            }
            if ($dither->{time} < $obs_tstart) {
                last;
            }
        }
    }

    if (   ($self->{dither_guide}->{ampl_y_max} != $self->{dither_guide}->{ampl_y})
        or ($self->{dither_guide}->{ampl_p_max} != $self->{dither_guide}->{ampl_p}))
    {
        push @{ $self->{fyi} },
          sprintf(
            "Max Y Z ampl during guide used for checking Y=%.1f Z=%.1f \n",
            $self->{dither_guide}->{ampl_y_max} + 0.0,
            $self->{dither_guide}->{ampl_p_max} + 0.0
          );
    }

  # For eng obs, don't have OR to specify dither, so stop before doing vs-OR comparisons
    if ($self->{obsid} =~ /^\d*$/) {
        return if ($self->{obsid} >= $ER_MIN_OBSID);
    }

    # Get the OR value of dither and compare if available
    my $bs_val = $guide_dither->{state};
    my $or_val;
    if (defined $self->{DITHER_ON}) {
        $or_val = ($self->{DITHER_ON} eq 'ON') ? 'ENAB' : 'DISA';

        # ACA-002
        push @{ $self->{warn} }, "Dither mismatch - OR: $or_val != Backstop: $bs_val\n"
          if ($or_val ne $bs_val);
    }
    else {
        push @{ $self->{warn} }, "Unable to determine dither from OR list\n";
    }

  # If dither is enabled according to the OR, check that parameters match OR vs Backstop
    if ((defined $or_val) and ($or_val eq 'ENAB')) {
        my $or_ampl_y = $self->{DITHER_Y_AMP} * 3600;
        my $or_ampl_p = $self->{DITHER_Z_AMP} * 3600;
        if (
            (
                   abs($or_ampl_y - $guide_dither->{ampl_y}) > 0.1
                or abs($or_ampl_p - $guide_dither->{ampl_p}) > 0.1
            )
          )
        {
            my $warn = sprintf(
                "Dither amp. mismatch - OR: (Y %.1f, Z %.1f) "
                  . "!= Backstop: (Y %.1f, Z %.1f)\n",
                $or_ampl_y, $or_ampl_p,
                $guide_dither->{ampl_y},
                $guide_dither->{ampl_p}
            );
            push @{ $self->{warn} }, $warn;
        }
    }
}

#############################################################################################
sub standard_dither {
#############################################################################################
    my $dthr = shift;
    my %standard_dither_y = (
        20 => 1087.0,
        16 => 1414.2,
        8 => 1000.0
    );
    my %standard_dither_p = (
        20 => 768.6,
        16 => 2000.0,
        8 => 707.1
    );

    my $ampl_p = int($dthr->{ampl_p} + 0.5);
    my $ampl_y = int($dthr->{ampl_y} + 0.5);

    # If the rounded amplitude is not in the standard set, return 0
    if (not(grep $_ eq $ampl_p, (keys %standard_dither_p))) {
        return 0;
    }
    if (not(grep $_ eq $ampl_y, (keys %standard_dither_y))) {
        return 0;
    }

    # If the period is not standard for the standard amplitudes return 0
    if (abs($dthr->{period_p} - $standard_dither_p{$ampl_p}) > 10) {
        return 0;
    }
    if (abs($dthr->{period_y} - $standard_dither_y{$ampl_y}) > 10) {
        return 0;
    }

    # If those tests passed, the dither is standard
    return (($ampl_y == 20) & ($ampl_p == 20)) ? 'hrc' : 'acis';
}

#############################################################################################
sub large_dither_checks {
#############################################################################################
    # Check the subset of monitor-window-style commanding that should be used on
    # observations with large dither.

    my $self = shift;
    my $dither_state = shift;
    my $all_dither = shift;
    my $time_tol = 11;    # Commands must be within $time_tol of expectation

    # Save the number of warnings when starting this method
    my $n_warn = scalar(@{ $self->{warn} });

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
    if (abs($dither_state->{time} - $obs_tstart - 300) > $time_tol) {
        push @{ $self->{warn} },
          sprintf("Large Dither not enabled 5 min after EOM (%s)\n",
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

    my $det = (($self->{SI} eq 'HRC-S') or ($self->{SI} eq 'HRC-I')) ? 'hrc' : 'acis';

    # Is dither nominal for detector at EOM
    if ($det ne standard_dither($obs_start_dither)) {
        push @{ $self->{warn} },
          sprintf(
"Dither should be detector nominal 1 min before obs start for Large Dither\n"
          );
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
    if ((abs($obs_tstop - $obs_stop_dither->{time} - 310) > $time_tol)) {
        push @{ $self->{warn} },
          sprintf(
"Last dither state for Large Dither should start 5 minutes before obs end.\n"
          );
    }

    # Check that the dither state at the end of the observation is standard
    if (not standard_dither($obs_stop_dither)) {
        push @{ $self->{warn} },
          sprintf("Dither parameters not set to standard values before obs end\n");
    }

   # If the number of warnings has not changed during this routine, it passed all checks
    if (scalar(@{ $self->{warn} }) == $n_warn) {
        push @{ $self->{fyi} }, sprintf("Observation passes 'big dither' checks\n");
    }
}

#############################################################################################
sub check_bright_perigee {
#############################################################################################
    my $self = shift;
    my $radmon = shift;
    my $min_n_stars = 3;

    # if this is an OR, just return
    return if (($self->{obsid} =~ /^\d+$/ && $self->{obsid} < $ER_MIN_OBSID));

    # if radmon is undefined, warn and return
    if (not defined $radmon) {
        push @{ $self->{warn} },
          "Perigee bright stars not being checked, no rad zone info available\n";
        return;
    }

    # set the observation start as the end of the maneuver
    my $obs_tstart = $self->{obs_tstart};
    my $obs_tstop = $self->{obs_tstop};

    # if observation stop time is undefined, warn and return
    if (not defined $obs_tstop) {
        push @{ $self->{warn} },
          "Perigee bright stars not being checked, no obs tstop available\n";
        return;
    }

    # is this obsid in perigee?  assume no to start
    my $in_perigee = 0;

    for my $rad (reverse @{$radmon}) {
        next if ($rad->{time} > $obs_tstop);
        if ($rad->{state} eq 'DISA') {
            $in_perigee = 1;
            last;
        }
        last if ($rad->{time} < $obs_tstart);
    }

    # nothing to do if not in perigee
    return if (not $in_perigee);

    my $c = find_command($self, 'MP_STARCAT');
    return if (not defined $c);

    my @mags = ();
    for my $i (1 .. 16) {
        if ($c->{"TYPE$i"} =~ /GUI|BOT/) {
            my $mag = $c->{"GS_MAG$i"};
            push @mags, $mag;
        }
    }

    # Pass 1 to guide_count as count_9th kwarg to use the count_9th mode
    my $bright_count = sprintf(
        "%.1f",
        call_python(
            "utils.guide_count",
            [],
            {
                mags => \@mags,
                t_ccd => $self->{ccd_temp},
                count_9th => 1,
                date => $self->{date},
            }
        )
    );
    if ($bright_count < $min_n_stars) {
        push @{ $self->{warn} }, "$bright_count star(s) brighter than scaled 9th mag. "
          . "Perigee requires at least $min_n_stars\n";
    }
    $self->{figure_of_merit}->{guide_count_9th} = $bright_count;
}

#############################################################################################
sub check_momentum_unload {
#############################################################################################
    my $self = shift;
    my $backstop = shift;
    my $obs_tstart = $self->{obs_tstart};
    my $obs_tstop = $self->{obs_tstop};

    if (not defined $obs_tstart or not defined $obs_tstop) {
        push @{ $self->{warn} }, "Momentum Unloads not checked.\n";
        return;
    }
    for my $entry (@{$backstop}) {
        if ((defined $entry->{command}) and (defined $entry->{command}->{TLMSID})) {
            if ($entry->{command}->{TLMSID} =~ /AOMUNLGR/) {
                if (($entry->{time} >= $obs_tstart) and ($entry->{time} <= $obs_tstop))
                {
                    push @{ $self->{fyi} },
                      "Momentum Unload (AOMUNLGR) in NPM at " . $entry->{date} . "\n";
                }
            }
        }
    }
}

#############################################################################################
sub check_sim_position {
#############################################################################################
    my $self = shift;
    my @sim_trans = @_;    # Remaining values are SIMTRANS backstop cmds
    my $manvr;

    return unless (exists $self->{SIM_OFFSET_Z});
    unless ($manvr = find_command($self, "MP_TARGQUAT", -1)) {
        push @{ $self->{warn} }, "Missing MP_TARGQUAT cmd\n";
        return;
    }

    # Set the expected SIM Z position (steps)
    my $sim_z = $Default_SIM_Z{ $self->{SI} } + $self->{SIM_OFFSET_Z};

    foreach my $st (reverse @sim_trans) {
        if (not defined $manvr->{tstop}) {
            push @{ $self->{warn} },
              "Maneuver times not defined; SIM checking failed!\n";
        }
        else {
            if ($manvr->{tstop} >= $st->{time}) {
                my %par = Ska::Parse_CM_File::parse_params($st->{params});
                if (abs($par{POS} - $sim_z) > 4) {

                    #		print STDERR "Yikes, SIM mismatch!  \n";
                    #		print STDERR " self->{obsid} = $self->{obsid}\n";
           #		print STDERR " sim_offset_z = $self->{SIM_OFFSET_Z}   SI = $self->{SI}\n";
#		print STDERR " st->{POS} = $par{POS}   sim_z = $sim_z   delta = ", $par{POS}-$sim_z,"\n";
                    # ACA-001
                    push @{ $self->{warn} },
                      "SIM position mismatch:  OR=$sim_z  BACKSTOP=$par{POS}\n";
                }
                last;
            }
        }
    }
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

    # Rough angle / pixel scale for dither
    my $ang_per_pix = 5;

    # If guessing if a BOT or GUI star in slot 7 with an 8x8 box is also a MON
    # we expect MON stars to be within 480 arc seconds of the center, Y or Z
    my $mon_expected_ymax = 480;
    my $mon_expected_zmax = 480;

    my $min_y_side = 2500;    # Minimum rectangle size for all acquisition stars
    my $min_z_side = 2500;

    my $col_sep_dist = 50;    # Common column pixel separation
    my $col_sep_mag = 4.5;    # Common column mag separation (from ODB_MIN_COL_MAG_G)

    my $fid_faint = 7.2;
    my $fid_bright = 6.8;

    my $spoil_dist = 140;  # Min separation of star from other star within $sep_mag mags
    my $spoil_mag = 5.0;    # Don't flag if mag diff is more than this

    my $qb_dist = 20;    # QB separation arcsec (3 pixels + 1 pixel of ambiguity)

    my $y0 = 33;    # CCD QB coordinates (arcsec)
    my $z0 = -27;

    my $is_science = ($self->{obsid} =~ /^\d+$/ && $self->{obsid} < $ER_MIN_OBSID);
    my $is_er = ($self->{obsid} =~ /^\d+$/ && $self->{obsid} >= $ER_MIN_OBSID);
    my $min_guide = $is_science ? 5 : 6;    # Minimum number of each object type
    my $min_acq = $is_science ? 4 : 5;
    my $min_fid = 3;
    ########################################################################

    my @warn = ();
    my @orange_warn = ();
    my @yellow_warn = ();

    my $oflsid = $self->{dot_obsid};
    my $obsid = $self->{obsid};


    # ACA-004
    # if no starcat, warn and quit this subroutine
    unless ($c = find_command($self, "MP_STARCAT")) {
        push @{ $self->{warn} }, "No star catalog for obsid $obsid ($oflsid). \n";
        return;
    }

    my ($dither_acq_y, $dither_acq_z, $dither_guide_y, $dither_guide_z);
    if (defined $self->{dither_acq}) {
        $dither_acq_y = $self->{dither_acq}->{ampl_y};
        $dither_acq_z = $self->{dither_acq}->{ampl_p};
    }
    else {
        push @{ $self->{yellow_warn} },
          "Acquisition dither could not be determined, using 20\"x20\" for checking.\n";
        $dither_acq_y = 20.0;
        $dither_acq_z = 20.0;
    }

    if (defined $self->{dither_guide}->{ampl_y_max}) {
        $dither_guide_y = $self->{dither_guide}->{ampl_y_max};
        $dither_guide_z = $self->{dither_guide}->{ampl_p_max};
    }
    else {
        push @{ $self->{yellow_warn} },
          "Guide dither could not be determined, using 20\"x20\" for checking.\n";
        $dither_guide_y = 20.0;
        $dither_guide_z = 20.0;
    }

    # Decrement minimum number of guide stars on ORs if a monitor window is commanded
    $min_guide -= @{ $self->{mon} } if $is_science;

    print STDERR "Checking star catalog for obsid $self->{obsid}\n";

    # Global checks on star/fid numbers
    # ACA-005 ACA-006 ACA-007 ACA-008 ACA-044

    push @warn, "Too Few Fid Lights\n" if (@{ $self->{fid} } < $min_fid && $is_science);
    push @warn, "Too Many Fid Lights\n"
      if ( (@{ $self->{fid} } > 0 && $is_er)
        || (@{ $self->{fid} } > $min_fid && $is_science));
    push @warn, "Too Few Acquisition Stars\n" if (@{ $self->{acq} } < $min_acq);

    # Red warn if fewer than the minimum number of guide stars
    my $n_gui = @{ $self->{gui} };
    push @yellow_warn, "Only $n_gui Guide Stars ($min_guide required)\n"
      if ($n_gui < $min_guide);
    push @warn, "Too Many GUIDE + FID\n"
      if (@{ $self->{gui} } + @{ $self->{fid} } + @{ $self->{mon} } > 8);
    push @warn, "Too Many Acquisition Stars\n" if (@{ $self->{acq} } > 8);
    push @warn, "Too many MON\n"
      if ( (@{ $self->{mon} } > 1 && $is_science)
        || (@{ $self->{mon} } > 2 && $is_er));


    my $fid_positions = [];

    # Skip fid position calculations and fid checks on vehicle products
    if (not $vehicle) {
        $fid_positions = get_fid_positions($self, $c);

        # If there are fids turned on and positions for them have been determined
        # run fid checks.
        if (scalar(@{$fid_positions}) > 0 ){
            check_fids($self, $c, $fid_positions);
        }
    }

    # Make arrays of the items that we need for the hot pixel region check
    my (@idxs, @yags, @zags, @mags, @types);
    foreach my $i (1 .. 16) {
        if ($c->{"TYPE$i"} =~ /BOT|GUI|FID/) {
            push @idxs, $i;
            push @yags, $c->{"YANG$i"};
            push @zags, $c->{"ZANG$i"};

            # Add zero to get items that look more like float values in the arrays
            push @mags, ($c->{"GS_MAG$i"} eq '---') ? 13.94 : $c->{"GS_MAG$i"} + 0.0;
            push @types, $c->{"TYPE$i"};
        }
    }

    # Run the hot pixel region check on the Python side on FID|GUI|BOT
    my @imposters = @{
        call_python(
            "utils.check_hot_pix",
            [
                \@idxs,
                \@yags,
                \@zags,
                \@mags,
                \@types,
                $self->{ccd_temp},
                $self->{date},
                $dither_guide_y,
                $dither_guide_z,
            ]
        );
    };

    # Assign warnings based on those hot pixel region checks
  IMPOSTER:
    for my $imposter (@imposters) {

        # If the check just fails on the Python side write out a warning and move on.
        if ($imposter->{status} == 1) {
            push @warn,
              sprintf("[%2d] Processing error when checking for hot pixels.\n",
                $imposter->{idx});
            next IMPOSTER;
        }
        my $warn = sprintf(
"[%2d] Imposter mag %.1f centroid offset %.1f row, col (%4d, %4d) star (%4d, %4d)\n",
            $imposter->{idx},
            $imposter->{bad2_mag},
            $imposter->{offset},
            $imposter->{bad2_row},
            $imposter->{bad2_col},
            $imposter->{entry_row},
            $imposter->{entry_col}
        );
        if ($imposter->{offset} > 4.0) {
            push @warn, $warn;
        }
        elsif ($imposter->{offset} > 2.5) {
            push @orange_warn, $warn;
        }
    }

    # Overlap spoiler check
    # The PEA will drop a readout window if it overlaps with another window.  This was
    # noticed in obsid 45890 and 45884 in NOV2921A.
  # For each 'tracked' type (GUI, BOT, FID, MON) confirm that it isn't within 60 arcsecs
    # (Y and Z) of another tracked type.
    foreach my $i (1 .. 16) {
        next if $c->{"TYPE$i"} =~ /NUL|ACQ/;
        foreach my $j ($i + 1 .. 16) {
            next if $c->{"TYPE$j"} =~ /NUL|ACQ/;
            my $dy = $c->{"YANG${i}"} - $c->{"YANG${j}"};
            my $dz = $c->{"ZANG${i}"} - $c->{"ZANG${j}"};
            if ((abs($dy) < 60) & (abs($dz) < 60)) {
                push @warn,
                  sprintf(
                    "Track overlap for idxs [$i] [$j]. Delta y,z (%.1f,%.1f) < 60.\n",
                    $dy, $dz);
            }
        }
    }

    # Seed smallest maximums and largest minimums for guide star box
    my $max_y = -3000;
    my $min_y = 3000;
    my $max_z = -3000;
    my $min_z = 3000;

    foreach my $i (1 .. 16) {
        (my $sid = $c->{"GS_ID$i"}) =~ s/[\s\*]//g;
        my $type = $c->{"TYPE$i"};
        my $yag = $c->{"YANG$i"};
        my $zag = $c->{"ZANG$i"};
        my $mag = $c->{"GS_MAG$i"};
        my $maxmag = $c->{"MAXMAG$i"};
        my $halfw = $c->{"HALFW$i"};
        my $db_stats = $c->{"GS_USEDBEFORE${i}"};


        # Find position extrema for smallest rectangle check
        if ($type =~ /BOT|GUI/) {
            $max_y = ($max_y > $yag) ? $max_y : $yag;
            $min_y = ($min_y < $yag) ? $min_y : $yag;
            $max_z = ($max_z > $zag) ? $max_z : $zag;
            $min_z = ($min_z < $zag) ? $min_z : $zag;
        }
        next if ($type eq 'NUL');

        # Warn if star not identified ACA-042
        if ($type =~ /BOT|GUI|ACQ/ and not defined $c->{"GS_IDENTIFIED$i"}) {
            push @warn,
              sprintf("[%2d] Missing Star. No AGASC star near search center \n", $i);
        }

        # Warn if ASPQ1 is too large for nominal ACQ or GUI selection
        if (($type =~ /BOT|ACQ|GUI/) and (defined $c->{"GS_ASPQ$i"})) {
            if (   (($type =~ /BOT|GUI/) and ($c->{"GS_ASPQ$i"} > 20))
                or (($type =~ /BOT|ACQ/) && ($c->{"GS_ASPQ$i"} > 40)))
            {
                push @orange_warn,
                  sprintf("[%2d] Centroid Perturbation Warning.  %s: ASPQ1 = %2d\n",
                      $i, $sid, $c->{"GS_ASPQ$i"});
            }
        }

        my $obs_min_cnt = 2;
        my $obs_bad_frac = 0.3;

        # Bad Acquisition Star
        if ($type =~ /BOT|ACQ|GUI/) {
            my $n_obs = $bad_acqs{$sid}{n_obs};
            my $n_noids = $bad_acqs{$sid}{n_noids};
            if (defined $db_stats->{acq}) {
                $n_obs = $db_stats->{acq};
                $n_noids = $db_stats->{acq_noid};
            }
            if ($n_noids && $n_obs > $obs_min_cnt && $n_noids / $n_obs > $obs_bad_frac)
            {
                push @yellow_warn,
                  sprintf
                  "[%2d] Bad Acquisition Star. %s has %2d failed out of %2d attempts\n",
                  $i, $sid, $n_noids, $n_obs;
            }
        }

        # Bad Guide Star
        if ($type =~ /BOT|GUI/) {
            my $n_obs = $bad_gui{$sid}{n_obs};
            my $n_nbad = $bad_gui{$sid}{n_nbad};
            if (defined $db_stats->{gui}) {
                $n_obs = $db_stats->{gui};
                $n_nbad = $db_stats->{gui_bad};
            }
            if ($n_nbad && $n_obs > $obs_min_cnt && $n_nbad / $n_obs > $obs_bad_frac) {
                push @orange_warn,
                  sprintf "[%2d] Bad Guide Star. %s has bad data %2d of %2d attempts\n",
                  $i, $sid, $n_nbad, $n_obs;
            }
        }

        # Bad AGASC ID ACA-031
        push @yellow_warn, sprintf "[%2d] Non-numeric AGASC ID.  %s\n", $i, $sid
          if ($sid ne '---' && $sid =~ /\D/);
        if (($type =~ /BOT|GUI|ACQ/) and (defined $bad_id{$sid})) {
            push @warn, sprintf "[%2d] Bad AGASC ID.  %s\n", $i, $sid;
        }

        # Set NOTES variable for marginal or bad star based on AGASC info
        $c->{"GS_NOTES$i"} = '';
        my $note = '';
        my $marginal_note = '';
        if (defined $c->{"GS_CLASS$i"}) {
            $c->{"GS_NOTES$i"} .= 'b' if ($c->{"GS_CLASS$i"} != 0);

            # ignore precision errors in color
            my $color = sprintf('%.7f', $c->{"GS_BV$i"});
            $c->{"GS_NOTES$i"} .= 'c' if ($color eq '0.7000000');    # ACA-033
            $c->{"GS_NOTES$i"} .= 'C' if ($color eq '1.5000000');
            $c->{"GS_NOTES$i"} .= 'm' if ($c->{"GS_MAGERR$i"} > 99);
            $c->{"GS_NOTES$i"} .= 'p' if ($c->{"GS_POSERR$i"} > 399);

            # If 0.7 color or bad mag err or bad pos err, format a warning for the star.
            # Color 1.5 stars do not get a text warning and bad class stars are handled
            # separately a few lines lower.
            if ($c->{"GS_NOTES$i"} =~ /[cmp]/) {
                $note = sprintf(
                    "B-V = %.3f, Mag_Err = %.2f, Pos_Err = %.2f",
                    $c->{"GS_BV$i"},
                    ($c->{"GS_MAGERR$i"}) / 100,
                    ($c->{"GS_POSERR$i"}) / 1000
                );
                $marginal_note = sprintf("[%2d] Marginal star. %s\n", $i, $note);
            }

            # Assign orange warnings to catalog stars with B-V = 0.7 .
        # Assign yellow warnings to catalog stars with other issues (example B-V = 1.5).
            if (($marginal_note) && ($type =~ /BOT|GUI|ACQ/)) {
                if ($color eq '0.7000000') {
                    push @orange_warn, $marginal_note;
                }
                else {
                    push @yellow_warn, $marginal_note;
                }
            }

            # Print bad star warning on catalog stars with bad class.
            if ($c->{"GS_CLASS$i"} != 0) {
                if ($type =~ /BOT|GUI|ACQ/) {
                    push @warn,
                      sprintf("[%2d] Bad star.  Class = %s %s\n",
                        $i, $c->{"GS_CLASS$i"}, $note);
                }
                elsif ($type eq 'MON') {
                    push @{ $self->{fyi} },
                      sprintf("[%2d] MON class= %s %s (do not convert to GUI)\n",
                        $i, $c->{"GS_CLASS$i"}, $note);
                }
            }
        }

        # Star/fid outside of CCD boundaries
        # ACA-019 ACA-020 ACA-021
        my ($pixel_row, $pixel_col) =
          @{ call_python("utils._yagzag_to_pixels", [ $yag, $zag ]) };

        # Set "acq phase" dither to acq dither or 20.0 if undefined
        my $dither_acq_y = $self->{dither_acq}->{ampl_y} or 20.0;
        my $dither_acq_p = $self->{dither_acq}->{ampl_p} or 20.0;

        # Set "dither" for FID to be pseudodither of 5.0 to give 1 pix margin
# Set "track phase" dither for BOT GUI to max guide dither over interval or 20.0 if undefined.
        my $dither_track_y =
          ($type eq 'FID') ? 5.0 : $self->{dither_guide}->{ampl_y_max}
          or 20.0;
        my $dither_track_p =
          ($type eq 'FID') ? 5.0 : $self->{dither_guide}->{ampl_p_max}
          or 20.0;

        my $pix_window_pad =
          7;    # half image size + point uncertainty + ? + 1 pixel of margin
        my $pix_row_pad = 8;
        my $pix_col_pad = 1;
        my $row_lim = 512.0 - ($pix_row_pad + $pix_window_pad);
        my $col_lim = 512.0 - ($pix_col_pad + $pix_window_pad);

        my %track_limits = (
            'row' => $row_lim - $dither_track_y / $ang_per_pix,
            'col' => $col_lim - $dither_track_p / $ang_per_pix
        );
        my %pixel = (
            'row' => $pixel_row,
            'col' => $pixel_col
        );

# Store the sign of the pixel row/col just to make it easier to print the corresponding limit
        my %pixel_sign = (
            'row' => ($pixel_row < 0) ? -1 : 1,
            'col' => ($pixel_col < 0) ? -1 : 1
        );

        if ($type =~ /BOT|GUI|FID/) {
            foreach my $axis ('row', 'col') {
                my $track_delta = abs($track_limits{$axis}) - abs($pixel{$axis});
                if ($track_delta < 2.5) {
                    push @warn,
                      sprintf
"[%2d] Less than 2.5 pix edge margin $axis lim %.1f val %.1f delta %.1f\n",
                      $i, $pixel_sign{$axis} * $track_limits{$axis}, $pixel{$axis},
                      $track_delta;
                }
                elsif ($track_delta < 5) {
                    push @orange_warn,
                      sprintf
                      "[%2d] Within 5 pix of CCD $axis lim %.1f val %.1f delta %.1f\n",
                      $i, $pixel_sign{$axis} * $track_limits{$axis}, $pixel{$axis},
                      $track_delta;
                }
            }
        }

        # For acq stars, the distance to the row/col padded limits are also confirmed,
        # but code to track which boundary is exceeded (row or column) is not present.
    # Note from above that the pix_row_pad used for row_lim has 7 more pixels of padding
        # than the pix_col_pad used to determine col_lim.
        my $acq_edge_delta = min(
            ($row_lim - $dither_acq_y / $ang_per_pix) - abs($pixel_row),
            ($col_lim - $dither_acq_p / $ang_per_pix) - abs($pixel_col)
        );
        if (($type =~ /BOT|ACQ/) and ($acq_edge_delta < (-1 * 12))) {
            push @orange_warn, sprintf "[%2d] Acq Off (padded) CCD by > 60 arcsec.\n",
              $i;
        }


        # Faint and bright limits ~ACA-009 ACA-010
        if ($mag ne '---') {
            if ($type eq 'GUI' or $type eq 'BOT') {
                my $guide_mag_warn = sprintf "[%2d] Magnitude. Guide star %6.3f\n", $i,
                  $mag;
                if (($mag > 10.3) or ($mag < 5.2)) {
                    push @orange_warn, $guide_mag_warn;
                }
            }
            if ($type eq 'BOT' or $type eq 'ACQ') {
                my $acq_mag_warn = sprintf "[%2d] Magnitude. Acq star %6.3f\n", $i,
                  $mag;
                if ($mag < 5.2) {
                    push @warn, $acq_mag_warn;
                }
            }
        }

        # FID magnitude limits ACA-011
        if ($type eq 'FID') {
            if ($mag =~ /---/ or $mag < $fid_bright or $mag > $fid_faint) {
                push @warn, sprintf "[%2d] Magnitude.  %6.3f\n", $i,
                  $mag =~ /---/ ? 0 : $mag;
            }
        }

        # Check for situation that occurred for obsid 14577 with a fid light
        # inside the search box (PR #50).

        if ($type =~ /BOT|ACQ/) {

            # Margin for fid spoiling the acquisition star is the search box halfwidth
           # plus the uncertainty in fid position.  See starcheck #251 for justification
            # of the 25 arcsec value here.
            my $fid_spoil_margin = $halfw + 25.0;

            for my $fpos (@{$fid_positions}) {
                if (    abs($fpos->{y} - $yag) < $fid_spoil_margin
                    and abs($fpos->{z} - $zag) < $fid_spoil_margin)
                {
                    if ($type =~ /ACQ/) {
                        push @yellow_warn, sprintf "[%2d] Fid light in search box\n",
                          $i;
                    }
                    else {
                        push @warn, sprintf "[%2d] Fid light in search box\n", $i;
                    }
                }
            }
        }

        if ($type =~ /BOT|GUI/) {
            if (($maxmag =~ /---/) or ($mag =~ /---/)) {
                push @warn, sprintf "[%2d] Magnitude.  MAG or MAGMAX not defined \n",
                  $i;
            }
            else {
                # This is an explicit check of ACA-041
                if (($maxmag - $mag) < 0.3) {
                    push @warn, sprintf "[%2d] Magnitude.  MAXMAG - MAG < 0.3\n", $i;
                }

                # This is a check that maxmag for each slot is as-expected.
         # Note that for stars with large mag err (like color 1.5 stars) this will throw
                # a warning.
                my $rounded_maxmag = sprintf("%.2f", $maxmag);
                my $expected_maxmag = min($mag + 1.5, 11.2);
                if (abs($expected_maxmag - $rounded_maxmag) > 0.1) {
                    push @yellow_warn,
                      sprintf
"[%2d] Magnitude.  MAXMAG %.2f not within 0.1 mag of %.2f. (MAXMAG-MAG=%.2f) \n",
                      $i, $rounded_maxmag, $expected_maxmag, $maxmag - $mag;
                }
            }
        }

        # Search box too large ACA-018
        if ($type ne 'MON' and $c->{"HALFW$i"} > 200) {
            push @warn, sprintf "[%2d] Search Box Size. Search Box Too Large. \n", $i;
        }

        my $img_size = $ENV{PROSECO_OR_IMAGE_SIZE} || '8';
        my $or_size = "${img_size}x${img_size}";

        # Check that readout sizes are all as-requested for science observations ACA-027
        if ($is_science && $type =~ /BOT|GUI|ACQ/ && $c->{"SIZE$i"} ne $or_size) {
            push @warn,
              sprintf("[%2d] Readout Size. %s Should be %s\n",
                $i, $c->{"SIZE$i"}, $or_size);
        }

        # Check that readout sizes are all 8x8 for engineering observations ACA-028
        if ($is_er && $type =~ /BOT|GUI|ACQ/ && $c->{"SIZE$i"} ne "8x8") {
            push @warn,
              sprintf("[%2d] Readout Size.  %s Should be 8x8\n", $i, $c->{"SIZE$i"});
        }

        # Check that readout sizes are all 8x8 for FID lights ACA-029
        push @warn,
          sprintf("[%2d] Readout Size.  %s Should be 8x8\n", $i, $c->{"SIZE$i"})
          if ($type =~ /FID/ && $c->{"SIZE$i"} ne "8x8");

        # Check that readout size is 8x8 for monitor windows ACA-030
        push @warn,
          sprintf("[%2d] Readout Size. %s Should be 8x8\n", $i, $c->{"SIZE$i"})
          if ($type =~ /MON/ && $c->{"SIZE$i"} ne "8x8");

        # Bad Pixels ACA-025
        my @close_pixels;
        my @dr;
        if ($type =~ /GUI|BOT/) {
            foreach my $pixel (@bad_pixels) {
                my $dy = abs($pixel_row - $pixel->{row}) * 5;
                my $dz = abs($pixel_col - $pixel->{col}) * 5;
                my $dr = sqrt($dy**2 + $dz**2);
                next
                  unless ($dz < $self->{dither_guide}->{ampl_p} + 25
                    and $dy < $self->{dither_guide}->{ampl_y} + 25);
                push @close_pixels,
                  sprintf(" row, col (%d, %d), dy, dz (%d, %d) \n",
                    $pixel->{row}, $pixel->{col}, $dy, $dz);
                push @dr, $dr;
            }
            if (@close_pixels > 0) {
                my ($closest) = sort { $dr[$a] <=> $dr[$b] } (0 .. $#dr);
                my $warn =
                  sprintf("[%2d] Nearby ACA bad pixel. " . $close_pixels[$closest], $i)
                  ;    #Only warn for the closest pixel
                push @warn, $warn;
            }
        }

        # Spoiler star (for search) and common column

        foreach my $star (values %{ $self->{agasc_hash} }) {

            # Skip tests if $star is the same as the catalog star
            next
              if (
                $star->{id} eq $sid
                || (   abs($star->{yag} - $yag) < $ID_DIST_LIMIT
                    && abs($star->{zag} - $zag) < $ID_DIST_LIMIT
                    && abs($star->{mag_aca} - $mag) < 0.1)
              );
            my $dy = abs($yag - $star->{yag});
            my $dz = abs($zag - $star->{zag});
            my $dr = sqrt($dz**2 + $dy**2);
            my $dm = $mag ne '---' ? $mag - $star->{mag_aca} : 0.0;
            my $dm_string =
              $mag ne '---' ? sprintf("%4.1f", $mag - $star->{mag_aca}) : '?';

     # Fid within $dither + 25 arcsec of a star (yellow) and within 4 mags (red) ACA-024
            if (    $type eq 'FID'
                and $dz < $self->{dither_guide}->{ampl_p} + 25
                and $dy < $self->{dither_guide}->{ampl_y} + 25
                and $dm > -5.0)
            {
                my $warn =
                  sprintf("[%2d] Fid spoiler.  %10d: "
                      . "Y,Z,Radial,Mag seps: %3d %3d %3d %4s\n",
                    $i, $star->{id}, $dy, $dz, $dr, $dm_string);
                if ($dm > -4.0) { push @warn, $warn }
                else { push @yellow_warn, $warn }
            }

            # Spoiler star in track box ACA-022
            if (($type =~ /BOT|GUI/) and ($dz < 25) and ($dy < 25) and ($dm > -1.0)) {
                my $warn = sprintf(
                    "[%2d] Spoiler. %10d: " . "Y,Z,Radial,Mag seps: %3d %3d %3d %4s\n",
                    $i, $star->{id}, $dy, $dz, $dr, $dm_string);
                if ($dm > -0.2) { push @warn, $warn }
                else { push @yellow_warn, $warn }
            }


           # Common column: dz within limit, spoiler is $col_sep_mag brighter than star,
            # and spoiler is located between star and readout ACA-026
            if (    $type ne 'MON'
                and $dz < $col_sep_dist
                and $dm > $col_sep_mag
                and ($star->{yag} / $yag) > 1.0
                and abs($star->{yag}) < 2500)
            {
                push @warn,
                  sprintf("[%2d] Common Column. %10d " . "at Y,Z,Mag: %5d %5d %5.2f\n",
                    $i, $star->{id}, $star->{yag}, $star->{zag}, $star->{mag_aca});
            }
        }
    }

    # Find the smallest rectangle size that all acq stars fit in
    my $y_side = sprintf("%.0f", $max_y - $min_y);
    my $z_side = sprintf("%.0f", $max_z - $min_z);
    push @yellow_warn, "Guide stars fit in $y_side x $z_side square arc-second box\n"
      if $y_side < $min_y_side && $z_side < $min_z_side;

    # Collect warnings
    push @{ $self->{warn} }, @warn;
    push @{ $self->{orange_warn} }, @orange_warn;
    push @{ $self->{yellow_warn} }, @yellow_warn;
}

#############################################################################################
sub check_monitor_commanding {
#############################################################################################
    my $self = shift;
    my $backstop = shift;    # Reference to array of backstop commands
    my $or = shift;    # Reference to OR list hash
    my $time_tol = 10;    # Commands must be within $time_tol of expectation
    my $c;
    my $bs;
    my $cmd;

    my $r2a = 180. / 3.14159265 * 3600;

    # Save the number of warnings when starting this method
    my $n_warn = scalar(@{ $self->{warn} });

    # if this is a real numeric obsid
    if ($self->{obsid} =~ /^\d*$/) {

        # Don't worry about monitor commanding for non-science observations
        return if ($self->{obsid} >= $ER_MIN_OBSID);
    }

    # Check for existence of a star catalog
    return unless ($c = find_command($self, "MP_STARCAT"));

    # See if there are any monitor stars requested in the OR
    my $or_has_mon = (defined $or->{HAS_MON}) ? 1 : 0;

    my @mon_stars = grep { $c->{"TYPE$_"} eq 'MON' } (1 .. 16);

    # if there are no requests in the OR and there are no MON stars, exit
    return unless $or_has_mon or scalar(@mon_stars);

    my $found_mon = scalar(@mon_stars);
    my $stealth_mon = 0;

    if (($found_mon) and (not $or_has_mon)) {
        push @{ $self->{warn} },
          sprintf("MON not in OR, but in catalog. Position not checked.\n");
    }

    # Where is the requested OR?
    my $q_aca = Quat->new($self->{ra}, $self->{dec}, $self->{roll});
    my ($or_yang, $or_zang);
    if ($or_has_mon) {
        ($or_yang, $or_zang) = Quat::radec2yagzag($or->{MON_RA}, $or->{MON_DEC}, $q_aca)
          if ($or_has_mon);
    }

    # Check all indices
  IDX:
    for my $idx (1 ... 16) {
        my %idx_hash = (idx => $idx);
        (
            $idx_hash{type},
            $idx_hash{imnum},
            $idx_hash{restrk},
            $idx_hash{yang},
            $idx_hash{zang},
            $idx_hash{dimdts},
            $idx_hash{size}
          )
          = map { $c->{"$_${idx}"} }
          qw(
          TYPE
          IMNUM
          RESTRK
          YANG
          ZANG
          DIMDTS
          SIZE);
        my $y_sep = $or_yang * $r2a - $idx_hash{yang};
        my $z_sep = $or_zang * $r2a - $idx_hash{zang};
        $idx_hash{sep} = sqrt($y_sep**2 + $z_sep**2);

        # if this is a plain commanded MON
        if ($idx_hash{type} =~ /MON/) {

            # if it doesn't match the requested location ACA-037
            push @{ $self->{warn} },
              sprintf(
"[%2d] Monitor Commanding. Monitor Window is %6.2f arc-seconds off of OR specification\n",
                $idx_hash{idx}, $idx_hash{sep})
              if $idx_hash{sep} > 2.5;

            # if it isn't 8x8
            push @{ $self->{warn} },
              sprintf("[%2d] Monitor Commanding. Size is not 8x8\n", $idx_hash{idx})
              unless $idx_hash{size} eq "8x8";

            # if it isn't in slot 7 ACA-036
            push @{ $self->{warn} },
              sprintf(
"[%2d] Monitor Commanding. Monitor Window is in slot %2d and should be in slot 7.\n",
                $idx_hash{idx}, $idx_hash{imnum})
              if $idx_hash{imnum} != 7;

            # ACA-038
            push @{ $self->{warn} },
              sprintf(
                "[%2d] Monitor Commanding. Monitor Window is set to Convert-to-Track\n",
                $idx_hash{idx})
              if $idx_hash{restrk} == 1;

            # Verify the the designated track star is indeed a guide star. ACA-039
            my $dts_slot = $idx_hash{dimdts};
            my $dts_type = "NULL";
            foreach my $dts_index (1 .. 16) {
                next
                  unless $c->{"IMNUM$dts_index"} == $dts_slot
                  and $c->{"TYPE$dts_index"} =~ /GUI|BOT/;
                $dts_type = $c->{"TYPE$dts_index"};
                last;
            }
            push @{ $self->{warn} },
              sprintf(
"[%2d] Monitor Commanding. DTS for [%2d] is set to slot %2d which does not contain a guide star.\n",
                $idx_hash{idx},
                $idx_hash{idx},
                $dts_slot
              ) if $dts_type =~ /NULL/;
            next IDX;
        }

        if (    ($idx_hash{type} =~ /GUI|BOT/)
            and ($idx_hash{size} eq '8x8')
            and ($idx_hash{imnum} == 7))
        {
            $stealth_mon = 1;
            push @{ $self->{fyi} },
              sprintf("[%2d] Appears to be MON used as GUI/BOT.\n", $idx);

            # if it doesn't match the requested location
            push @{ $self->{warn} },
              sprintf(
"[%2d] Monitor Commanding. Guide star as MON %6.2f arc-seconds off OR specification\n",
                $idx_hash{idx}, $idx_hash{sep})
              if $idx_hash{sep} > 2.5;

            next IDX;
        }
        if ((not $found_mon) and ($idx_hash{sep} < 2.5)) {

            # if there *should* be one there...
            push @{ $self->{fyi} },
              sprintf(
"[%2d] Commanded at intended OR MON position; but not configured for MON\n",
                $idx);
        }

    }

    # if I don't have a plain MON or a "stealth" MON, throw a warning
    push @{ $self->{warn} }, sprintf("MON requested in OR, but none found in catalog\n")
      unless ($found_mon or $stealth_mon);

    # if we're using a guide star, we don't need the rest of the dither setup
    if ($stealth_mon and not $found_mon) {
        return;
    }

    # Find the associated maneuver command for this obsid.  Need this to get the
    # exact time of the end of maneuver
    my $manv;
    unless ($manv = find_command($self, "MP_TARGQUAT", -1)) {
        push @{ $self->{warn} },
          sprintf("Cannot find maneuver for checking monitor commanding\n");
        return;
    }

    # Now check in backstop commands for :
    #  Dither is disabled (AODSDITH) 1 min - 10s prior to the end of the maneuver (EOM)
    #    to the target attitude.
    #  The OFP Aspect Camera Process is restarted (AOACRSET) 3 minutes - 10s after EOM.
    #  Dither is enabled (AOENDITH) 5 min - 10s after EOM
    # ACA-040

    my $t_manv = $manv->{tstop};
    my %dt = (AODSDITH => -70, AOACRSET => 170, AOENDITH => 290);
    my %cnt = map { $_ => 0 } keys %dt;
    foreach $bs (grep { $_->{cmd} eq 'COMMAND_SW' } @{$backstop}) {
        my %param = Ska::Parse_CM_File::parse_params($bs->{params});
        next unless ($param{TLMSID} =~ /^AO/);
        foreach $cmd (keys %dt) {
            if ($cmd =~ /$param{TLMSID}/) {
                if (abs($bs->{time} - ($t_manv + $dt{$cmd})) < $time_tol) {
                    $cnt{$cmd}++;
                }
            }
        }
    }

   # Add warning messages unless exactly one of each command was found at the right time
    foreach $cmd (qw (AODSDITH AOACRSET AOENDITH)) {
        next if ($cnt{$cmd} == 1);
        $cnt{$cmd} = 'no' if ($cnt{$cmd} == 0);
        push @{ $self->{warn} }, "Found $cnt{$cmd} $cmd commands near "
          . time2date($t_manv + $dt{$cmd}) . "\n";
    }

   # If the number of warnings has not changed during this routine, it passed all checks
    if (scalar(@{ $self->{warn} }) == $n_warn) {
        push @{ $self->{fyi} },
          sprintf("Monitor window special commanding meets requirements\n");
    }
}

#############################################################################################
sub get_fid_positions {
#############################################################################################

    my $self = shift;
    my $c = shift;
    my @fid_positions;

    # If no star cat fids and no commanded fids, then return
    return \@fid_positions if (@{ $self->{fid} } == 0 && @{ $self->{fidsel} } == 0);

    # Make sure we have SI and SIM_OFFSET_Z to be able to calculate fid yang and zang
    unless (defined $self->{SI}) {
        push @{ $self->{warn} }, "Unable to check fids because SI undefined\n";
        return \@fid_positions;
    }
    unless (defined $self->{SIM_OFFSET_Z}) {
        push @{ $self->{warn} },
          "Unable to check fids because SIM_OFFSET_Z undefined\n";
        return \@fid_positions;
    }

    # Calculate fid offsets
    my $offsets =
      call_python("utils.get_fid_offset", [ $self->{date}, $self->{ccd_temp_acq} ]);
    my $dy = $offsets->[0];
    my $dz = $offsets->[1];

    # For each FIDSEL fid, calculate position
    foreach my $fid (@{ $self->{fidsel} }) {
        my ($yag, $zag, $error) =
          calc_fid_ang($fid, $self->{SI}, $self->{SIM_OFFSET_Z}, $self->{obsid});

        if ($error) {
            push @{ $self->{warn} }, "$error\n";
            next;
        }

        # Apply offsets
        $yag += $dy;
        $zag += $dz;

        push @fid_positions, { y => $yag, z => $zag };
    }
    return \@fid_positions;

}

#############################################################################################
sub check_fids {
#############################################################################################
    my $self = shift;
    my $c = shift;    # Star catalog command
    my $fid_positions = shift;

    my $fid_hw = 40;

    # If no star cat fids and no commanded fids, then return
    return if (@{ $self->{fid} } == 0 && @{ $self->{fidsel} } == 0);

    # Catalog fids
    my @fid_ok = map { 0 } @{ $self->{fid} };

    # For each FIDSEL fid, confirm it is in a catalog search box
    foreach my $fid (@{$fid_positions}) {

        my ($yag, $zag) = ($fid->{y}, $fid->{z});
        my $fidsel_ok = 0;

        # Cross-correlate with all star cat fids
        for my $i_fid (0 .. $#fid_ok) {
            my $i = $self->{fid}[$i_fid];    # Index into star catalog entries

            # Check if any starcat fid matches fidsel fid position
            if (   abs($yag - $c->{"YANG$i"}) < $fid_hw
                && abs($zag - $c->{"ZANG$i"}) < $fid_hw)
            {
                $fidsel_ok = 1;
                $fid_ok[$i_fid] = 1;

                # Add a warning if the match is within 5 arcsecs of the edge
                if ((abs($yag - $c->{"YANG$i"}) > ($fid_hw - 5)) |
                    (abs($zag - $c->{"ZANG$i"}) > ($fid_hw - 5)))
                {
                    push @{ $self->{orange_warn} },
                      sprintf(
                        "[%2d] expected fid pos within 5 arcsec of search box edge\n",
                        $i);
                }
                last;
            }
        }

        # ACA-034
        push @{ $self->{warn} },
          sprintf(
"No catalog fid found within $fid_hw arcsec of fid turned on at (%.1f, %.1f)\n",
            $yag, $zag)
          unless ($fidsel_ok);
    }

    # ACA-035
    for my $i_fid (0 .. $#fid_ok) {
        push @{ $self->{warn} },
          sprintf(
            "[%2d] catalog fid not within $fid_hw arcsec of an expected fid pos\n",
            $self->{fid}[$i_fid])
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
    my $r2a = 180. / 3.14159265 * 3600;

    # Make some variables for accessing ODB elements
    $si =~ tr/a-z/A-Z/;
    $si =~ s/[-_]//;

    my ($si2hrma) = ($si =~ /(ACIS|HRCI|HRCS)/);

    # Define allowed range for $fid for each detector
    my %range = (
        ACIS => [ 1, 6 ],
        HRCI => [ 7, 10 ],
        HRCS => [ 11, 14 ]
    );

    # Check that the fid light (from fidsel history) is appropriate for the detector
    unless ($fid >= $range{$si2hrma}[0] and $fid <= $range{$si2hrma}[1]) {
        return (undef, undef,
            "Commanded fid light $fid does not correspond to detector $si2hrma");
    }

    # Generate index into ODB tables.  This goes from 0..5 (ACIS) or 0..3 (HRC)
    my $fid_id = $fid - $range{$si2hrma}[0];

    # Calculate fid angles using formula in OFLS
    my $y_s = $odb{"ODB_${si}_FIDPOS"}[ $fid_id * 2 ];
    my $z_s = $odb{"ODB_${si}_FIDPOS"}[ $fid_id * 2 + 1 ];
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
sub get_report_html {
#############################################################################################
    my $self = shift;
    my $c;
    my $o = '';    # Output

    my $obsid = $self->{obsid};

    # Internal reference link
    $o .= "<!-- Start of HTML report content for obsid $obsid -->\n";

    # Main table for per-obsid report
    $o .= "<!-- Main table for per-obsid report for obsid $obsid -->\n";
    $o .= "<TABLE CELLPADDING=0>\n";

    # Left side of table with nav links and pre-formatted text
    $o .= "<TD VALIGN=TOP WIDTH=810>\n";
    my $nav_buttons = $self->get_report_prev_next_buttons_html();
    $o .= qq{<A NAME="obsid$obsid">$nav_buttons</A>\n};
    $o .= "<BR>\n";
    $o .= "<!-- Star catalog preformatted information and table for obsid $obsid -->\n";
    $o .= "<PRE>\n";
    $o .= $self->get_report_header_html();
    $o .= $self->get_report_starcat_table_html();
    $o .= $self->get_report_footer_html();
    $o .= "</PRE>\n";
    $o .= "</TD>\n";

    # Right side with images: starfield big, starfield small, compass
    $o .= "<!-- Star field plot for obsid $obsid -->\n";
    $o .= "<TD VALIGN=TOP>\n";
    $o .= $self->get_report_images_html();
    $o .= "</TD>\n";

    $o .= "</TR>\n";
    $o .= "</TABLE>\n";
    $o .= "<!-- End of HTML report content for obsid $obsid -->\n";
    return $o;
}

#############################################################################################
sub get_report_prev_next_buttons_html {
#############################################################################################
    my $self = shift;
    my $o = '';

    if (defined $self->{prev}->{obsid} or defined $self->{next}->{obsid}) {
        $o .= " <TABLE WIDTH=43><TR>";
        if (defined $self->{prev}->{obsid}) {
            $o .= sprintf(
"<TD><A HREF=\"#obsid%s\"><img align=\"top\" src=\"%s/up.gif\" ></A></TD>",
                $self->{prev}->{obsid},
                $self->{STARCHECK}
            );
            $o .= sprintf("<TD><A HREF=\"#obsid%s\">PREV</A> </TD>",
                $self->{prev}->{obsid});
        }
        else {
            $o .= sprintf("<TD><img align=\"top\" src=\"%s/up.gif\" ></TD>",
                $self->{STARCHECK});
            $o .= sprintf("<TD>PREV</TD>");
        }
        $o .= sprintf("<TD>&nbsp; &nbsp;</TD>");
        if (defined $self->{next}->{obsid}) {
            $o .= sprintf(
"<TD><A HREF=\"#obsid%s\"><img align=\"top\" src=\"%s/down.gif\" ></A></TD>",
                $self->{next}->{obsid},
                $self->{STARCHECK}
            );
            $o .= sprintf("<TD><A HREF=\"#obsid%s\">NEXT</A> </TD>",
                $self->{next}->{obsid});
        }
        $o .= " </TR></TABLE>";
    }
    return $o;
}


#############################################################################################
sub get_report_header_html {
# Make the bit like this:
#
# OBSID: 30182  NGC5134                ACIS-S SIM Z offset:0     (0.00mm) Grating: NONE
# RA, Dec, Roll (deg):   201.336746   -21.137976    62.841900
# Dither: ON Y_amp=16.0  Z_amp=16.0  Y_period=1414.0  Z_period=2000.0
# BACKSTOP GUIDE_SUMM OR MANVR DOT TLR
#
# MP_TARGQUAT at 2025:041:02:29:09.263 (VCDU count = 9219318)
#   Q1,Q2,Q3,Q4: 0.24868922  -0.47464310  -0.84208447  0.06132982
#   MANVR: Angle= 152.43 deg  Duration= 2692 sec  End= 2025:041:03:14:07
#
#############################################################################################
    my $self = shift;
    my $c;
    my $o = '';    # Output

    my $target_name =
      ($self->{TARGET_NAME}) ? $self->{TARGET_NAME} : $self->{SS_OBJECT};

    $o .= sprintf("${blue_font_start}OBSID: %-5s  ", $self->{obsid});
    $o .= sprintf(
        "%-22s %-6s SIM Z offset:%-5d (%-.2fmm) Grating: %-5s",
        $target_name, $self->{SI}, $self->{SIM_OFFSET_Z},
        ($self->{SIM_OFFSET_Z}) * 1000 * ($odb{"ODB_TSC_STEPS"}[0]),
        $self->{GRATING}
    ) if ($target_name);
    $o .= sprintf "${font_stop}\n";

    if ((defined $self->{ra}) and (defined $self->{dec}) and (defined $self->{roll})) {
        $o .= sprintf "RA, Dec, Roll (deg): %12.6f %12.6f %12.6f\n", $self->{ra},
          $self->{dec}, $self->{roll};
    }

# This 'defined' check has been changed to be a test on the amplitude.  It looks like for the undefined
    # case such as replan, this {dither_guide} is set but is an empty hash ref.
    if (defined $self->{dither_guide}->{ampl_y}) {
        my $z_amp = int($self->{dither_guide}->{ampl_p} + .5);
        my $y_amp = int($self->{dither_guide}->{ampl_y} + .5);
        if ($self->{dither_guide}->{state} eq 'ENAB') {
            $o .= sprintf "Dither: ON ";
            $o .= sprintf(
                "Y_amp=%4.1f  Z_amp=%4.1f  Y_period=%6.1f  Z_period=%6.1f \n",
                $y_amp, $z_amp,
                $self->{dither_guide}->{period_y},
                $self->{dither_guide}->{period_p}
            );
        }
        else {
            $o .= sprintf "Dither: OFF\n";
        }
    }

    $o .= sprintf(
        "<A HREF=\"%s/%s.html#%s\">BACKSTOP</A> ",
        $self->{STARCHECK}, basename($self->{backstop}),
        $self->{obsid}
    );
    $o .= sprintf(
        "<A HREF=\"%s/%s.html#%s\">GUIDE_SUMM</A> ",
        $self->{STARCHECK}, basename($self->{guide_summ}),
        $self->{obsid}
    );
    $o .= sprintf(
        "<A HREF=\"%s/%s.html#%s\">OR</A> ",
        $self->{STARCHECK}, basename($self->{or_file}),
        $self->{obsid}
    ) if ($self->{or_file});
    $o .= sprintf(
        "<A HREF=\"%s/%s.html#%s\">MANVR</A> ",
        $self->{STARCHECK}, basename($self->{mm_file}),
        $self->{dot_obsid}
    );
    $o .= sprintf(
        "<A HREF=\"%s/%s.html#%s\">DOT</A> ",
        $self->{STARCHECK}, basename($self->{dot_file}),
        $self->{obsid}
    );
    $o .= sprintf(
        "<A HREF=\"%s/%s.html#%s\">TLR</A> ",
        $self->{STARCHECK}, basename($self->{tlr_file}),
        $self->{obsid}
    );
    $o .= sprintf "\n\n";

    for my $n (1 .. 10)
    {    # Allow for multiple TARGQUAT cmds, though 2 is the typical limit
        if ($c = find_command($self, "MP_TARGQUAT", $n)) {
            $o .= sprintf "MP_TARGQUAT at $c->{date} (VCDU count = $c->{vcdu})\n";
            $o .= sprintf(
                "  Q1,Q2,Q3,Q4: %.8f  %.8f  %.8f  %.8f\n",
                $c->{Q1},
                $c->{Q2},
                $c->{Q3},
                $c->{Q4}
            );
            if (exists $c->{man_err} and exists $c->{dur} and exists $c->{angle}) {
                $o .= sprintf(
"  MANVR: Angle= %6.2f deg  Duration= %.0f sec  End= %s\n",
                    $c->{angle}, $c->{dur},
                    substr(time2date($c->{tstop}), 0, 17));
            }
            if (    (defined $c->{man_angle_calc})
                and (($c->{man_angle_calc} - $c->{angle}) > 5))
            {
                $o .= sprintf("  MANVR: Calculated angle from NMM time = %6.2f deg\n",
                    $c->{man_angle_calc});
            }
            $o .= "\n";
        }
    }
    return $o;
}

#############################################################################################
sub get_report_starcat_table_html {
# Make this:
#
# MP_STARCAT at 2025:041:02:29:10.906 (VCDU count = 9219324)
# ---------------------------------------------------------------------------------------------
#  IDX SLOT        ID  TYPE   SZ   P_ACQ    MAG   MAXMAG   YANG   ZANG DIM RES HALFW PASS NOTES
# ---------------------------------------------------------------------------------------------
# [ 1]  0           1   FID  8x8     ---   7.000   8.000    932  -1739   1   1   25
#      ...
# [12]  7   803738368   ACQ  8x8   0.586  10.222  11.203   1020   1893  20   1  120
#############################################################################################
    my $self = shift;
    my $c;
    my $table = '';
    my $star_stat_lookup = "http://kadi.cfa.harvard.edu/star_hist/?agasc_id=";

    if ($c = find_command($self, "MP_STARCAT")) {

        my @fields =
          qw (TYPE  SIZE P_ACQ GS_MAG MAXMAG YANG ZANG DIMDTS RESTRK HALFW GS_PASS GS_NOTES);
        my @format =
          qw(%6s    %5s  %8.3f  %8s   %8.3f  %7d  %7d   %4d    %4d    %5d    %6s     %4s);

        $table .= sprintf "MP_STARCAT at $c->{date} (VCDU count = $c->{vcdu})\n";
        $table .= sprintf
"---------------------------------------------------------------------------------------------\n";
        $table .= sprintf
" IDX SLOT        ID  TYPE   SZ   P_ACQ    MAG   MAXMAG   YANG   ZANG DIM RES HALFW PASS NOTES\n";

#                      [ 4]  3   971113176   GUI  6x6   1.000   7.314   8.844  -2329  -2242   1   1   25  bcmp
        $table .= sprintf
"---------------------------------------------------------------------------------------------\n";

        foreach my $i (1 .. 16) {
            next if ($c->{"TYPE$i"} eq 'NUL');

            # Define the color of output star catalog line based on NOTES:
            #   Yellow if NOTES is non-trivial.
            #   Red if NOTES has a 'b' for bad class or if a guide star has bad color.
            my $color = ($c->{"GS_NOTES$i"} =~ /\S/) ? 'yellow' : '';
            $color = 'red'
              if ($c->{"GS_NOTES$i"} =~ /b/
                || ($c->{"GS_NOTES$i"} =~ /c/ && $c->{"TYPE$i"} =~ /GUI|BOT/));

            if ($color) {
                $table .=
                    ($color eq 'red') ? $red_font_start
                  : ($color eq 'yellow') ? $yellow_font_start
                  : qq{};
            }
            $table .= sprintf "[%2d]", $i;

# change from a map to a loop to get some conditional control, since PoorTextFormat can't seem to
            # take nested \link_target when the line is colored green or red
            $table .= sprintf('%3d', $c->{"IMNUM${i}"});
            my $db_stats = $c->{"GS_USEDBEFORE${i}"};
            my $idlength = length($c->{"GS_ID${i}"});
            my $idpad_n = 12 - $idlength;
            my $idpad;
            while ($idpad_n > 0) {
                $idpad .= " ";
                $idpad_n--;
            }

            # Get a string for acquisition probability in the hover-over
            my $acq_prob = "";
            if ($c->{"TYPE$i"} =~ /BOT|ACQ/) {
                # Fetch this slot's acq probability for the hover-over string,
                # but if the probability is not defined (expected for weird cases such as
                # replan/reopen) just leave $acq_prob as the initialized empty string.
                if (defined $self->{acq_probs}->{ $c->{"IMNUM${i}"} }) {
                    $acq_prob = sprintf("Prob Acq Success %5.3f",
                        $self->{acq_probs}->{ $c->{"IMNUM${i}"} });
                }
            }

            # Make the id a URL if there is star history or if star history could
            # not be checked (no db_handle)
            my $star_link;
            if ($db_stats->{acq} or $db_stats->{gui}) {
                $star_link =
                  sprintf("HREF=\"%s%s\"", $star_stat_lookup, $c->{"GS_ID${i}"});
            }
            else {
                $star_link = sprintf("A=\"star\"");
            }

            # If there is database history, add it to the blurb
            my $history_blurb = "";
            if ($db_stats->{acq} or $db_stats->{gui}) {
                $history_blurb = sprintf(
                    "ACQ total:%d noid:%d <BR />"
                      . "GUI total:%d bad:%d fail:%d obc_bad:%d <BR />"
                      . "Avg Mag %4.2f <BR />",
                    $db_stats->{acq},
                    $db_stats->{acq_noid},
                    $db_stats->{gui},
                    $db_stats->{gui_bad},
                    $db_stats->{gui_fail},
                    $db_stats->{gui_obc_bad},
                    $db_stats->{avg_mag}
                );
            }

            # If the object has catalog information, add it to the blurb
            # for the hoverover
            my $cat_blurb = "";
            if (defined $c->{"GS_MAGERR$i"}) {
                $cat_blurb = sprintf(
                    "mac_aca_err=%4.2f pos_err=%4.2f color1=%4.2f <BR />",
                    $c->{"GS_MAGERR$i"} / 100.,
                    $c->{"GS_POSERR$i"} / 1000.,
                    $c->{"GS_BV$i"}
                );
            }

            # If the line is a fid or "---" don't make a hoverover
            if (($c->{"TYPE$i"} eq 'FID') or ($c->{"GS_ID$i"} eq '---')) {
                $table .= sprintf("${idpad}%s", $c->{"GS_ID${i}"});
            }

     # Otherwise, construct a hoverover and a url as needed, using the blurbs made above
            else {
                $table .= sprintf(
                    "${idpad}<A $star_link STYLE=\"text-decoration: none;\" "
                      . "ONMOUSEOVER=\"return overlib ('"
                      . "$cat_blurb"
                      . "$history_blurb"
                      . "$acq_prob"
                      . "', WIDTH, 300);\" ONMOUSEOUT=\"return nd();\">%s</A>",
                    $c->{"GS_ID${i}"}
                );
            }
            for my $field_idx (0 .. $#fields) {
                my $curr_format = $format[$field_idx];
                my $field_color = 'black';

                # override mag formatting if it lost its 3
                # decimal places during JSONifying
                if (    ($fields[$field_idx] eq 'GS_MAG')
                    and ($c->{"$fields[$field_idx]$i"} ne '---'))
                {
                    $curr_format = "%8.3f";
                }

                # For P_ACQ fields, if it is a string, use that format
                # If it is defined, and probability is less than .50, print red
                # If it is defined, and probability is less than .75, print "yellow"
                if (    ($fields[$field_idx] eq 'P_ACQ')
                    and ($c->{"P_ACQ$i"} eq '---'))
                {
                    $curr_format = "%8s";
                }
                elsif ( ($fields[$field_idx] eq 'P_ACQ')
                    and ($c->{"P_ACQ$i"} < .50))
                {
                    $field_color = 'red';
                }
                elsif ( ($fields[$field_idx] eq 'P_ACQ')
                    and ($c->{"P_ACQ$i"} < .75))
                {
                    $field_color = 'yellow';
                }

                # For MAG fields, if the P_ACQ probability is defined and has a color,
              # share that color.  Otherwise, if the MAG violates the yellow/red warning
                # limit, colorize.
                if ($fields[$field_idx] eq 'GS_MAG') {
                    if (($c->{"P_ACQ$i"} ne '---') and ($c->{"P_ACQ$i"} < .50)) {
                        $field_color = 'red';
                    }
                    elsif (($c->{"P_ACQ$i"} ne '---') and ($c->{"P_ACQ$i"} < .75)) {
                        $field_color = 'yellow';
                    }
                    elsif ( ($c->{"P_ACQ$i"} eq '---')
                        and ($c->{"GS_MAG$i"} ne '---')
                        and ($c->{"GS_MAG$i"} > $self->{mag_faint_red}))
                    {
                        $field_color = 'red';
                    }
                    elsif ( ($c->{"P_ACQ$i"} eq '---')
                        and ($c->{"GS_MAG$i"} ne '---')
                        and ($c->{"GS_MAG$i"} > $self->{mag_faint_yellow}))
                    {
                        $field_color = 'yellow';
                    }
                }

                # Use colors if required
                if ($field_color eq 'red') {
                    $curr_format = $red_font_start . $curr_format . $font_stop;
                }
                if ($field_color eq 'yellow') {
                    $curr_format = $yellow_font_start . $curr_format . $font_stop;
                }
                $table .= sprintf($curr_format, $c->{"$fields[$field_idx]$i"});

            }
            $table .= $font_stop if ($color);
            $table .= sprintf "\n";
        }

    }
    else {
        $table = sprintf(" " x 93 . "\n");
    }

    return $table;
}

#############################################################################################
sub get_report_footer_html {
# Make this:
#
# >> WARNING : [ 6] Imposter mag 11.0 centroid offset 2.9 row, col ( 422,  171) star ( 430,  179)
#
# Probability of acquiring 2 or fewer stars (10^-x):	3.4
# Acquisition Stars Expected  : 6.24
# Guide star count: 5.0
# Predicted Max CCD temperature: -7.0 C (-7.007 C)	 N100 Warm Pix Frac 0.446
# Dynamic Mag Limits: Yellow 9.96 	 Red 10.37
#
#############################################################################################
    my $self = shift;
    my $c;
    my $o = '';    # Output

    $o .= "\n"
      if ( @{ $self->{warn} }
        || @{ $self->{yellow_warn} }
        || @{ $self->{fyi} }
        || @{ $self->{orange_warn} });

    if (@{ $self->{warn} }) {
        $o .= "${red_font_start}";
        foreach (sort(@{ $self->{warn} })) {
            $o .= ">> CRITICAL: " . $_;
        }
        $o .= "${font_stop}";
    }
    if (@{ $self->{orange_warn} }) {
        $o .= "${orange_font_start}";
        foreach (sort(@{ $self->{orange_warn} })) {
            $o .= ">> WARNING : " . $_;
        }
        $o .= "${font_stop}";
    }
    if (@{ $self->{yellow_warn} }) {
        $o .= "${yellow_font_start}";
        foreach (sort(@{ $self->{yellow_warn} })) {
            $o .= ">> CAUTION : " . $_;
        }
        $o .= "${font_stop}";
    }
    if (@{ $self->{fyi} }) {
        $o .= "${blue_font_start}";
        foreach (sort(@{ $self->{fyi} })) {
            $o .= ">> INFO    : " . $_;
        }
        $o .= "${font_stop}";
    }
    $o .= "\n";

    # Don't print probability info, temperature, dynamic limits if there is no catalog
    if ($c = find_command($self, "MP_STARCAT")) {
        if (exists $self->{figure_of_merit}) {
            my $bad_FOM = $self->{figure_of_merit}->{cum_prob_bad};
            $o .= "$red_font_start" if $bad_FOM;
            $o .= "Probability of acquiring 2 or fewer stars (10^-x):\t";
            $o .= sprintf("%.1f", $self->{figure_of_merit}->{P2}) . "\t";
            $o .= "$font_stop" if $bad_FOM;
            $o .= "\n";
            $o .= sprintf("Acquisition Stars Expected  : %.2f\n",
                $self->{figure_of_merit}->{expected});
            $o .= sprintf("Guide star count: %.1f \t",
                $self->{figure_of_merit}->{guide_count});

            if (defined $self->{figure_of_merit}->{guide_count_9th}) {
                $o .= sprintf("Guide count_9th: %.1f",
                    $self->{figure_of_merit}->{guide_count_9th});
            }
            $o .= "\n";
        }

        $o .= sprintf(
            "Predicted Max CCD temperature: %.1f C (%.3f C)",
            $self->{ccd_temp},
            $self->{ccd_temp}
        );
        if (defined $self->{n100_warm_frac}) {
            $o .= sprintf("\t N100 Warm Pix Frac %.3f", $self->{n100_warm_frac});
        }
        $o .= "\n";
        $o .= sprintf(
            "Dynamic Mag Limits: Yellow %.2f \t Red %.2f\n",
            $self->{mag_faint_yellow},
            $self->{mag_faint_red}
        );
    }

    return $o;
}

sub get_report_images_html {
    my $self = shift;
    my $img_size = 600;

    my $out = "";
    if ($self->{plot_file}) {
        my $obs = $self->{obsid};
        $out .= $self->star_image_map($img_size);
        $out .= qq{<img src="$self->{plot_file}" usemap=\#starmap_${obs} width=$img_size height=$img_size border=0> };
    }
    return $out;
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
    for my $j (1 .. (1 + $#{ $guide_ref->{$obsid}{info} })) {

        @f = split ' ', $guide_ref->{$obsid}{info}[ $j - 1 ];

        if (   abs($f[5] * $r2a - $c->{"YANG$j"}) < 10
            && abs($f[6] * $r2a - $c->{"ZANG$j"}) < 10)
        {
            $c->{"GS_TYPE$j"} = $f[0];
            $c->{"GS_ID$j"} = $f[1];
            $c->{"GS_RA$j"} = $f[2];
            $c->{"GS_DEC$j"} = $f[3];
            if ($f[4] eq '---') {
                $c->{"GS_MAG$j"} = $f[4];
            }
            else {
                $c->{"GS_MAG$j"} = sprintf "%8.3f", $f[4];
            }
            $c->{"GS_YANG$j"} = $f[5] * $r2a;
            $c->{"GS_ZANG$j"} = $f[6] * $r2a;

            # Parse the SAUSAGE star selection pass number
            $c->{"GS_PASS$j"} =
              defined $f[7] ? ($f[7] =~ /\*+/ ? length $f[7] : $f[7]) : ' ';
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
    if ($bad_idx_match == 1) {
        push @{ $self->{warn} }, "Guide summary does not match commanded catalog.\n";
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
    $self->{agasc_hash} = call_python("utils._get_agasc_stars",
        [ $self->{ra}, $self->{dec}, $self->{roll}, 1.3, $self->{date}, $agasc_file ]);

    foreach my $star (values %{ $self->{agasc_hash} }) {
        if ($star->{'mag_aca'} < -10 or $star->{'mag_aca_err'} < -10) {
            push @{ $self->{warn} },
              sprintf(
                "Star with bad mag %.1f or magerr %.1f at (yag,zag)=%.1f,%.1f\n",
                $star->{'mag_aca'}, $star->{'mag_aca_err'},
                $star->{'yag'}, $star->{'zag'}
              );
        }
    }

}

#############################################################################################
sub identify_stars {
#############################################################################################
    my $self = shift;

    return unless (my $c = find_command($self, 'MP_STARCAT'));

    my $manvr = find_command($self, "MP_TARGQUAT");

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
        unless ((defined $self->{agasc_hash}{$gs_id}) or ($gs_id eq '---')) {
            push @{ $self->{warn} },
              sprintf(
                "[%2d] Star $gs_id is not in retrieved AGASC region by RA and DEC! \n",
                $i);
        }

        # if the star is defined in the agasc hash, copy
        # the information from the agasc to the catalog

        if (defined $self->{agasc_hash}{$gs_id}) {
            my $star = $self->{agasc_hash}{$gs_id};

            # Confirm that the agasc magnitude matches the guide star summary magnitude
            my $gs_mag = $c->{"GS_MAG$i"};
            my $dmag = abs($star->{mag_aca} - $gs_mag);
            if ($dmag > 0.01) {
                push @{ $self->{yellow_warn} },
                  sprintf("[%d] Guide sum mag diff from agasc mag %9.5f\n", $i, $dmag);
            }

            # let's still confirm that the backstop yag zag is what we expect
            # from agasc and ra,dec,roll ACA-043

            if (   abs($star->{yag} - $yag) > ($ID_DIST_LIMIT)
                || abs($star->{zag} - $zag) > ($ID_DIST_LIMIT))
            {
                my $dyag = abs($star->{yag} - $yag);
                my $dzag = abs($star->{zag} - $zag);

                if (   abs($star->{yag} - $yag) > (2 * $ID_DIST_LIMIT)
                    || abs($star->{zag} - $zag) > (2 * $ID_DIST_LIMIT))
                {
                    push @{ $self->{warn} },
                      sprintf(
"[%2d] Backstop YAG,ZAG differs from AGASC by > 3 arcsec: dyag = %2.2f dzag = %2.2f \n",
                        $i,
                        $dyag,
                        $dzag
                      );
                }
                else {
                    push @{ $self->{yellow_warn} },
                      sprintf(
"[%2d] Backstop YAG,ZAG differs from AGASC by > 1.5 arcsec: dyag = %2.2f dzag = %2.2f \n",
                        $i,
                        $dyag,
                        $dzag
                      );
                }
            }

            # should I put this in an else statement, or let it stand alone?

            $c->{"GS_IDENTIFIED$i"} = 1;
            $c->{"GS_BV$i"} = $star->{bv};
            $c->{"GS_MAGERR$i"} = $star->{mag_aca_err};
            $c->{"GS_POSERR$i"} = $star->{poserr};
            $c->{"GS_CLASS$i"} = $star->{class};
            $c->{"GS_ASPQ$i"} = $star->{aspq};
            my $db_hist = star_dbhist("$gs_id", $obs_time);
            $c->{"GS_USEDBEFORE$i"} = $db_hist;

        }
        else {
            # This loop should just get the $gs_id eq '---' cases
            foreach my $star (values %{ $self->{agasc_hash} }) {
                if (   abs($star->{yag} - $yag) < $ID_DIST_LIMIT
                    && abs($star->{zag} - $zag) < $ID_DIST_LIMIT)
                {
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
                    $c->{"GS_USEDBEFORE$i"} = star_dbhist($star->{id}, $obs_time);
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

    return call_python("utils.get_mica_star_stats",
        [ $star_id, $obs_tstart_minus_day ]);

}

#############################################################################################
sub star_image_map {
#############################################################################################
    my $self = shift;
    my $img_size = shift;
    my $c;
    return unless ($c = find_command($self, 'MP_STARCAT'));
    return
      unless ((defined $self->{ra})
        and (defined $self->{dec})
        and (defined $self->{roll}));
    my $obsid = $self->{obsid};

    # a hash of the agasc ids we want to plot
    my %plot_ids;

    # first the catalog ones
    for my $i (1 .. 16) {
        next if ($c->{"TYPE$i"} eq 'NUL');
        next if ($c->{"TYPE$i"} eq 'FID');
        if (defined $self->{agasc_hash}->{ $c->{"GS_ID${i}"} }) {
            $plot_ids{ $c->{"GS_ID${i}"} } = 1;
        }
    }

    # then up to 100 of the stars in the field brighter than
    # the faint plot limit
    my $star_count_limit = 100;
    my $star_count = 0;
    foreach my $star (values %{ $self->{agasc_hash} }) {
        next if ($star->{mag_aca} > $faint_plot_mag);
        $plot_ids{ $star->{id} } = 1;
        last if $star_count > $star_count_limit;
        $star_count++;
    }

    # For a 798x798 image (native with dpi=150), -2900 to 2900 arcsec is 619 pixels.
    # The top left corner is at x=100, y=63 pixels.
    my $img_size_ref = 798;  # pixels
    my $img_size_scale = $img_size / $img_size_ref;
    my $pix_scale = 619 / (2900. * 2) * $img_size_scale;
    my $x_offset = 100 * $img_size_scale;
    my $y_offset = 63 * $img_size_scale;

    # Convert all the yag/zags to pixel rows/cols
    my @yags = map { $self->{agasc_hash}->{$_}->{yag} } keys %plot_ids;
    my @zags = map { $self->{agasc_hash}->{$_}->{zag} } keys %plot_ids;
    my ($pix_rows, $pix_cols) =
      @{ call_python("utils._yagzag_to_pixels", [ \@yags, \@zags ]) };

    my $map = "<map name=\"starmap_${obsid}\" id=\"starmap_${obsid}\"> \n";
    my @star_ids = keys %plot_ids;
    for my $idx (0 .. $#star_ids) {
        my $star_id = $star_ids[$idx];
        my $pix_row = $pix_rows->[$idx];
        my $pix_col = $pix_cols->[$idx];
        my $cat_star = $self->{agasc_hash}->{$star_id};
        my $sid = $cat_star->{id};
        my $yag = $cat_star->{yag};
        my $zag = $cat_star->{zag};
        my $image_x = $x_offset + (2900 - $yag) * $pix_scale;
        my $image_y = $y_offset + (2900 - $zag) * $pix_scale;
        my $star =
            '<area href="javascript:void(0);"' . "\n"
          . 'ONMOUSEOVER="return overlib ('
          . "'id=$sid <br/>"
          . sprintf("yag,zag=%.2f,%.2f <br />", $yag, $zag)
          . sprintf("row,col=%.2f,%.2f <br />", $pix_row, $pix_col)
          . sprintf("mag_aca=%.2f <br />", $cat_star->{mag_aca})
          . sprintf("mag_aca_err=%.2f <br />", $cat_star->{mag_aca_err} / 100.0)
          . sprintf("class=%s <br />", $cat_star->{class})
          . sprintf("color=%.3f <br />", $cat_star->{bv})
          . sprintf("aspq1=%.1f <br />", $cat_star->{aspq})
          . '\', WIDTH, 220);"' . "\n"
          . 'ONMOUSEOUT="return nd();"' . "\n"
          . 'SHAPE="circle"' . "\n"
          . 'ALT=""' . "\n"
          . "COORDS=\"$image_x,$image_y,3\">" . "\n";
        $map .= $star;
    }
    $map .= "</map> \n";
    return $map;
}

#############################################################################################
sub quat2radecroll {
#############################################################################################
    my $r2d = 180. / 3.14159265;

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

    my $ra = atan2($xb, $xa) * $r2d;
    my $dec = atan2($xn, sqrt(1 - $xn**2)) * $r2d;
    my $roll = atan2($yn, $zn) * $r2d;
    $ra += 360 if ($ra < 0);
    $roll += 360 if ($roll < 0);

    return ($ra, $dec, $roll);
}

###################################################################################
sub check_guide_count {
###################################################################################
    my $self = shift;
    my $guide_count = $self->count_guide_stars();

    my $min_num_gui = ($self->{obsid} >= 38000) ? 6.0 : 4.0;

    if ($guide_count < $min_num_gui) {
        push @{ $self->{warn} }, "Guide count of $guide_count < $min_num_gui.\n";
    }

    # Also save the guide count in the figure_of_merit
    $self->{figure_of_merit}->{guide_count} = $guide_count;
}

###################################################################################
sub count_guide_stars {
###################################################################################
    my $self = shift;
    my $c;

    return 0.0 unless ($c = find_command($self, 'MP_STARCAT'));
    my @mags = ();
    for my $i (1 .. 16) {
        if ($c->{"TYPE$i"} =~ /GUI|BOT/) {
            my $mag = $c->{"GS_MAG$i"};
            push @mags, $mag;
        }
    }
    return sprintf(
        "%.1f",
        call_python(
            "utils.guide_count",
            [],
            {
                mags => \@mags,
                t_ccd => $self->{ccd_temp},
                count_9th => 0,
                date => $self->{date},
            }
        )
    );
}

###################################################################################
sub set_ccd_temps {
###################################################################################
    my $self = shift;
    my $obsid_temps = shift;

    # if no temperature data, just return
    if (   (not defined $obsid_temps->{ $self->{obsid} })
        or (not defined $obsid_temps->{ $self->{obsid} }->{ccd_temp}))
    {
        push @{ $self->{warn} }, "No CCD temperature prediction for obsid\n";
        push @{ $self->{warn} },
          sprintf("Using %s (planning limit) for t_ccd for mag limits\n",
            $config{ccd_temp_red_limit});
        $self->{ccd_temp} = $config{ccd_temp_red_limit};
        $self->{ccd_temp_acq} = $config{ccd_temp_red_limit};
        return;
    }

    # set the temperature to the value for the current obsid
    $self->{ccd_temp} = $obsid_temps->{ $self->{obsid} }->{ccd_temp};
    $self->{ccd_temp_min} = $obsid_temps->{ $self->{obsid} }->{ccd_temp_min};
    $self->{ccd_temp_acq} = $obsid_temps->{ $self->{obsid} }->{ccd_temp_acq};
    $self->{n100_warm_frac} = $obsid_temps->{ $self->{obsid} }->{n100_warm_frac};

    # Add critical warning for ACA planning limit violation. Round both the temperature
    # and the limit to 1 decimal place for comparison.
    my $ccd_temp_round = sprintf("%.1f", $self->{ccd_temp});
    my $ccd_temp_red_limit_round = sprintf("%.1f", $config{ccd_temp_red_limit});
    if ($ccd_temp_round > $ccd_temp_red_limit_round) {
        push @{ $self->{warn} },
          sprintf("CCD temperature exceeds %.1f C\n", $ccd_temp_red_limit_round);
    }

    # Add info for having a penalty temperature too
    if (defined $config{ccd_temp_yellow_limit}) {
        if ($self->{ccd_temp} > $config{ccd_temp_yellow_limit}) {
            push @{ $self->{fyi} },
              sprintf("Effective guide temperature %.1f C\n",
                call_python("utils.get_effective_t_ccd", [ $self->{ccd_temp} ]));

        }
        if ($self->{ccd_temp_acq} > $config{ccd_temp_yellow_limit}) {
            push @{ $self->{fyi} },
              sprintf("Effective acq temperature %.1f C\n",
                call_python("utils.get_effective_t_ccd", [ $self->{ccd_temp_acq} ]));

        }
    }

# Clip the acq ccd temperature to the calibrated range of the grid acq probability model
    # and add a yellow warning to let the user know this has happened.
    if (($self->{ccd_temp_acq} > 2.0) or ($self->{ccd_temp_acq} < -15.0)) {
        push @{ $self->{yellow_warn} },
          sprintf("acq t_ccd %.1f outside range -15.0 to 2.0. Clipped.\n",
            $self->{ccd_temp_acq});
        $self->{ccd_temp_acq} =
            $self->{ccd_temp_acq} > 2.0 ? 2.0
          : $self->{ccd_temp_acq} < -15.0 ? -15.0
          : $self->{ccd_temp_acq};
    }
}

###################################################################################
sub proseco_args {
###################################################################################
# Build a hash that corresponds to reasonable arguments to use to call proseco get_acq_catalog
    # to calculate marginalized acquisition probabilities for a star catalog.
    # This routine also saves the guides and fids into lists, but those are not used
    # by get_acq_catalog.
   # If an observation does not have a target quaternion or a starcat, it is skipped and
    # an empty hash is returned with no warning.
    my $self = shift;
    my %proseco_args;

# For the target quaternion, use the -1 to get the last quaternion (there could be more than
    # one for a segmented maneuver).
    my $targ_cmd = find_command($self, "MP_TARGQUAT", -1);
    my $cat_cmd = find_command($self, "MP_STARCAT");

# For observations without a target attitude, catalog, or defined obsid return an empty hash
    if ((not $targ_cmd) or (not $cat_cmd) or ($self->{obsid} =~ /NONE(\d+)/)) {
        return \%proseco_args;
    }

    my $man_angle_data = call_python("state_checks.get_obs_man_angle",
        [ $targ_cmd->{tstop}, $self->{backstop} ]);
    $targ_cmd->{man_angle_calc} = $man_angle_data->{'angle'};

    if (defined $man_angle_data->{'warn'}){
        push @{$self->{warn}}, $man_angle_data->{'warn'};
    }

    # Set a maneuver angle to be used by the proseco acquisition probability calculation.
    # Here the goal is to be conservative and use the angle that is derived from the
    # time in NMM before acquisition (the man_angle_calc from state_checks.get_obs_man_angle)
    # if needed but not introduce spurious warnings for cases where the angle as derived
    # from the time in NMM is in a neighboring bin for proseco maneuver error probabilities.
    # To satisfy those goals, use the derived-from-NMM-time angle if it is more than 5 degrees
    # larger than the  actual maneuver angle.  Otherwise use the actual maneuver angle.
    # This also lines up with what is printed in the starcheck maneuver output.
    my $man_angle = (($targ_cmd->{man_angle_calc} - $targ_cmd->{angle}) > 5)
                              ? $targ_cmd->{man_angle_calc} : $targ_cmd->{angle};



    # If the angle calculated from NMM time is more than 5 degrees less than the maneuver
    # angle, this is an unexpected condition that should have a critical warning.
    if ($targ_cmd->{man_angle_calc} < ($targ_cmd->{angle} - 5)){
        push @{$self->{warn}},
        sprintf("Manvr angle from NMM time %4.1f ", $targ_cmd->{man_angle_calc})
        . sprintf("< (manvr angle %4.1f - 5 deg).\n", $targ_cmd->{angle});
    }


    # Use a default SI and offset for ERs (no effect without fid lights)
    my $is_OR = $self->{obsid} < $ER_MIN_OBSID;
    my $si = $is_OR ? $self->{SI} : 'ACIS-S';
    my $offset = $is_OR ? $self->{SIM_OFFSET_Z} : 0;

    my @acq_ids;
    my @acq_indexes;
    my @gui_ids;
    my @fid_ids;
    my @halfwidths;

 # Loop over the star catalog and assign the acq stars, guide stars, and fids to arrays.
  IDX:
    foreach my $i (1 .. 16) {
        (my $sid = $cat_cmd->{"GS_ID$i"}) =~ s/[\s\*]//g;

        # If there is no star there is nothing for proseco probs to do so skip it.
        # But warn if it was a thing that should have had an id (BOT/ACQ/GUI).
        if ($sid eq '---') {
            if ($cat_cmd->{"TYPE$i"} =~ /BOT|ACQ|GUI/) {
                push @{ $self->{warn} },
                  sprintf("[%2d] Could not calculate acq prob for star with no id.",
                    $i);
            }
            next IDX;
        }
        $sid = int($sid);

# While assigning ACQ stars into a list, warn if outside the 60 to 180 range used by proseco
        # and the grid acq model.
        if ($cat_cmd->{"TYPE$i"} =~ /BOT|ACQ/) {
            push @acq_ids, $sid;
            my $hw = $cat_cmd->{"HALFW$i"};
            if (($hw > 180) or ($hw < 60)) {
                push @{ $self->{orange_warn} },
                  sprintf(
"[%2d] Halfwidth %d outside range 60 to 180. Will be clipped in proseco probs.\n",
                    $i, $hw);
            }
            push @halfwidths, $hw;
            push @acq_indexes, $i;
        }
        if ($cat_cmd->{"TYPE$i"} =~ /BOT|GUI/) {
            push @gui_ids, $sid;
        }
        if ($cat_cmd->{"TYPE$i"} =~ /FID/) {
            push @fid_ids, $sid;
        }
    }

# Build a hash of the arguments that could be used by proseco (get_aca_catalog or get_acq_catalog).
# Zeros are added to most of the numeric parameters as that seems to help "cast" them to floats or ints in
# Perl to some extent.  Also save the acquisition star catalog indexes to make it easier to assign back
    # the probabilities without having to search again on the Perl side by agasc id.
    %proseco_args = (
        obsid => $self->{obsid},
        date => $targ_cmd->{stop_date},
        att => [
            0 + $targ_cmd->{q1},
            0 + $targ_cmd->{q2},
            0 + $targ_cmd->{q3},
            0 + $targ_cmd->{q4}
        ],
        man_angle => 0 + $man_angle,
        detector => $si,
        sim_offset => 0 + $offset,
        dither_acq => [ $self->{dither_acq}->{ampl_y}, $self->{dither_acq}->{ampl_p} ],
        dither_guide =>
          [ $self->{dither_guide}->{ampl_y}, $self->{dither_guide}->{ampl_p} ],
        t_ccd_acq => $self->{ccd_temp_acq},
        t_ccd_guide => $self->{ccd_temp},
        include_ids_acq => \@acq_ids,
        n_acq => scalar(@acq_ids),
        include_halfws_acq => \@halfwidths,
        include_ids_guide => \@gui_ids,
        n_guide => scalar(@gui_ids),
        fid_ids => \@fid_ids,
        n_fid => scalar(@fid_ids),
        acq_indexes => \@acq_indexes
    );

    return \%proseco_args;

}

###################################################################################
sub set_proseco_probs_and_check_P2 {
###################################################################################
# For observations with a star catalog and which have valid parameters already determined
    # in $self->{proseco_args}, call the Python proseco_probs method to calculate the
    # marginalized probabilities, P2, and expected stars, and assign those values back
    # where expected in the data structure.
    # This assigns the individual acq star probabilites back into $self->{acq_probs} and
    # assigns the P2 and expected values into $self->{figure_of_merit}.
    my $self = shift;
    my $cat_cmd = find_command($self, "MP_STARCAT");
    my $args = $self->{proseco_args};

    if (not %{$args}) {
        return;
    }
    my ($p_acqs, $P2, $expected) = @{ call_python("utils.proseco_probs", [], $args) };

    $P2 = sprintf("%.1f", $P2);

    my @acq_indexes = @{ $args->{acq_indexes} };

    # Assign those p_acqs to a slot hash and the catalog P_ACQ by index
    my %slot_probs;
    for my $idx (0 .. $#acq_indexes) {
        my $i = $acq_indexes[$idx];
        $cat_cmd->{"P_ACQ$i"} = $p_acqs->[$idx];
        $slot_probs{ $cat_cmd->{"IMNUM$i"} } = $p_acqs->[$idx];
    }
    $self->{acq_probs} = \%slot_probs;

    # Red and yellow warnings on acquisition safing probability.

    # Set the P2 requirement to be 2.0 for ORs and 3.0 for ERs.  The higher limit for ER
    # reflects a desire to minimize integrated mission risk for observations where the
    # attitude can be selected freely.  Yellow warning for marginal catalog is set to a
   # factor of 10 less risk than the red limit P2 probability for OR / ER respectively).
    my $P2_red = $self->{obsid} < $ER_MIN_OBSID ? 2.0 : 3.0;
    my $P2_yellow = $P2_red + 1.0;

    # Create a structure that gets used for report generation only.
    $self->{figure_of_merit} = {
        expected => substr($expected, 0, 4),
        P2 => $P2,
        cum_prob_bad => ($P2 < $P2_red)
    };

    # Do the actual checks
    if ($P2 < $P2_red) {
        push @{ $self->{warn} }, "-log10 probability of 2 or fewer stars < $P2_red\n";
    }
    elsif ($P2 < $P2_yellow) {
        push @{ $self->{yellow_warn} },
          "-log10 probability of 2 or fewer stars < $P2_yellow\n";
    }

}

sub set_dynamic_mag_limits {

# Use the t_ccd at time of acquistion and time to set the mag limits corresponding to the the magnitude
 # for a 75% acquisition succes (yellow limit) and a 50% acquisition success (red limit)
    my $c;
    my $self = shift;
    return unless ($c = $self->find_command("MP_STARCAT"));

    my $date = $c->{date};
    my $t_ccd = $self->{ccd_temp_acq};

    # Dynamic mag limits based on 75% and 50% chance of successful star acq
    # Maximum limits of 10.3 and 10.6
    $self->{mag_faint_yellow} =
      min(10.3, call_python("utils._mag_for_p_acq", [ 0.75, $date, $t_ccd ]));
    $self->{mag_faint_red} =
      min(10.6, call_python("utils._mag_for_p_acq", [ 0.5, $date, $t_ccd ]));
}

