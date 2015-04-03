package Ska::Starcheck::Dark_Cal_Checker;

# part of aca_dark_cal_checker project

use strict;
use warnings;
use Carp;
use IO::All;
use Ska::Convert qw(date2time time2date);
use Quat;
use Config::General;
use Math::Trig;
use Data::Dumper;

use Ska::Parse_CM_File;

sub new{
    my $class = shift;
    my $par_ref = shift;

    # Set Defaults
    my $SKA = $ENV{SKA} || '/proj/sot/ska';
    my $DarkCal_Data = "$ENV{SKA_DATA}/starcheck" || "$SKA/data/starcheck";
    my $DarkCal_Share = "$ENV{SKA_SHARE}/starcheck" || "$SKA/share/starcheck";

    my %par = (
			   dir => '.',
			   app_data => "${DarkCal_Data}",
			   config => 'tlr.cfg',
			   tlr => 'CR*.tlr',
			   mm => '/mps/mm*.sum',
			   backstop => 'CR*.backstop',
			   dot => "/mps/md*.dot",
			   %{$par_ref},
	       );


    my @checks = (qw(
					aca_init_command
					trans_replica_0
					dither_disable_0
					tnc_replica_0
					trans_replica_1
					dither_disable_1
					tnc_replica_1
					trans_replica_2
					dither_disable_2
					tnc_replica_2
					trans_replica_3
					dither_disable_3
					tnc_replica_3
					trans_replica_4
					dither_disable_4
					tnc_replica_4
					check_manvr
					check_dwell
					check_manvr_point
					check_momentum_unloads
					check_dither_enable_at_end
					check_dither_param_at_end
					));

    
# Create a hash to store all information about the checks as they are performed
    my %feedback = (
					input_files => [],
					dark_cal_present => 1,
					checks => \@checks,
					);


	
# %Input files is used by get_file()

    my %config = ParseConfig(-ConfigFile => "$par{app_data}/$par{config}");
	$feedback{oflsids} = $config{template}->{manvr}->{point_order}->{oflsid};
    fix_config_hex(\%config);

    my $tlr_file    = get_file("$par{dir}/$par{tlr}", 'tlr', 'required', \@{$feedback{input_files}});
    my $tlr = TLR->new($tlr_file, 'tlr', \%config);
	$feedback{tlr} = $tlr;
	#my $mm_file = get_file("$par{dir}/$par{mm}", 'Maneuver Management', 'required', \@{$feedback{input_files}});
    my $dot_file = get_file("$par{dir}/$par{dot}", 'DOT', 'required', \@{$feedback{input_files}});
    #my @mm = Ska::Parse_CM_File::MM({file => $mm_file, ret_type => 'array'});
    my ($dot_href, $s_touched, $dot_aref) = Ska::Parse_CM_File::DOT($dot_file);
    my $bs_file = get_file("$par{dir}/$par{backstop}", 'Backstop', 'required', \@{$feedback{input_files}});
    my @bs = Ska::Parse_CM_File::backstop($bs_file);
    
    # load A and B templates
    my %templates = map { $_ => TLR->new(get_file("$par{app_data}/$config{file}{template}{$_}", 
                                                  'template', 
                                                  'required', 
                                                  \@{$feedback{input_files}} ), 'template', \%config) } (qw(A B));
    
    my $manvrs = maneuver_parse($dot_aref);
    my $dwells = calc_dwells($manvrs);
    my ($timelines, $trans_changes) = iu_timeline($tlr);
    my @trim_tlr = @{ trim_tlr( $tlr, \%config )};

    $feedback{aca_init_command} = compare_timingncommanding( [$tlr->{first_aca_hw_cmd}], [$templates{A}->{entries}[0]], \%config, 
                                                             "First ACA command is the template-independent init command");
    %feedback = (%feedback, %{replicas($tlr, \%templates, $timelines, $trans_changes, \%config)});
    
    $feedback{check_dither_enable_at_end} = check_dither_enable_at_end($tlr, \%config);
    $feedback{check_dither_param_at_end} = check_dither_param_at_end($tlr, \%config);
    $feedback{check_manvr} = check_manvr( \%config, $manvrs);
    $feedback{check_dwell} = check_dwell(\%config, $manvrs, $dwells);
    $feedback{check_manvr_point} = check_manvr_point( \%config, \@bs, $manvrs);
    $feedback{check_momentum_unloads} = check_momentum_unloads(\%config, \@bs, $manvrs, $dwells);
	
    bless \%feedback, $class;
    return \%feedback;

}

##***************************************************************************
sub maneuver_parse{
##***************************************************************************
# use the DOT entries to create an array of maneuver (hashes) each with
# a defined initial and final oflsid, tstart, tstop, and duration	

	my $dot = shift;

	my @raw_manvrs;
    for my $dot_entry (@{$dot}){
		if ($dot_entry->{cmd_identifier} =~ /ATS_MANVR/){
			push @raw_manvrs, $dot_entry;
		}
    }

	# mock initial starting attitude
	my $init = 'dcIAT';
	my @manvrs;
	# for each maneuver, make a hash and push it
	# saving the new attitude as the initial oflsid for the next maneuver
	for my $manvr (@raw_manvrs){
		my %man = ( init => $init,
					final => $manvr->{oflsid},
					tstart => $manvr->{time} + timestring_to_secs($manvr->{MANSTART}),
					tstop => $manvr->{time} 
					+ timestring_to_secs($manvr->{MANSTART}) 
					+ timestring_to_secs($manvr->{DURATION}),
					duration => timestring_to_mins($manvr->{DURATION}),
					);
		
		push @manvrs, \%man;
		$init = $manvr->{oflsid};

	}
	return \@manvrs;

}

##***************************************************************************
sub calc_dwells{
##***************************************************************************
# From the parsed DOT maneuvers, generate an hash of dwells keyed off of
# oflsid.  This will not be robust for obsids without maneuvers, but
# that should not be a problem for any of the oflsids we'll be checking
# (specifically, the dark cal ones).

	my $manvrs = shift;
	my %dwell;
	my $dwell_start;
	for my $manvr (@{$manvrs}){
		if (defined $dwell_start){
			$dwell{$manvr->{init}} = { duration => $manvr->{tstart} - $dwell_start,
									   tstart => $dwell_start,
									   tstop => $manvr->{tstart},
									   oflsid => $manvr->{init},
								   };
		}
		$dwell_start = $manvr->{tstop};
	}
	return \%dwell;
}


##***************************************************************************	    
sub replicas{
##***************************************************************************
# perform dither, transponder selection, and complete command/timing checks on
# each of the dark cal replicas

	my $tlr = shift;
	my $templates = shift;
	my $timelines = shift;
        my $trans_changes = shift;
	my $config = shift;
	my @trim_tlr = @{ trim_tlr( $tlr, $config )};
	my %feedback;
	# for each replica
	for my $r_idx (0 .. 4){
		# find the indexes in the real tlr and trim to a reduced set of commands to check
		# note that begin_replica and end_replica use trace_ids from the TLR
		my $r_start = $tlr->begin_replica($r_idx)->index();
		my $r_end = $tlr->end_replica($r_idx)->index();
		my @replica_tlr;
		for my $entry (@trim_tlr){
			if (($entry->index() >= $r_start) and ($entry->index() <= $r_end)){
				push @replica_tlr, $entry;
			}
		}
		# run the command checks on each transponder and store the results in the %per_trans hash
		my %per_trans;
		my $best_guess;
		for my $trans (qw( A B )){
			my $template = $templates->{$trans};
			my @replica_templ;
			for my $entry (@{$template->{entries}}){
				if ((defined $entry->replica()) and ($entry->replica() == $r_idx )){
					push @replica_templ, $entry;
				}
			}
			$per_trans{$trans} = compare_timingncommanding( \@replica_tlr, \@replica_templ, $config, 
															"Strict Timing Checks: Timing and Hex Commanding for replica $r_idx transponder $trans");
			$per_trans{$trans}->{transponder} = $trans;
		}
		# for the transponder version with fewest errors, assign the output, and
		# assign a transponder
		if ($per_trans{A}->{n_fails} < $per_trans{B}->{n_fails}){
			$best_guess = 'A';
			$feedback{"tnc_replica_${r_idx}"} = $per_trans{A};
		}
		else{
			$best_guess = 'B';
			$feedback{"tnc_replica_${r_idx}"} = $per_trans{B};
		}
        # for the given transponder and replica, check that the transponder state is correct
		$feedback{"trans_replica_${r_idx}"} = check_iu({ replica => $r_idx, 
														 r_tstart => $replica_tlr[0]->time(), 
														 r_tstop => $replica_tlr[-1]->time(),
														 r_datestart => $replica_tlr[0]->datestamp(),
														 r_datestop => $replica_tlr[-1]->datestamp(),
														 transponder => $best_guess, 
														 timelines => $timelines,
                                                                 trans_changes => $trans_changes,
														 config => $config});
		# also confirm that dither is disabled before the start of the replica
		$feedback{"dither_disable_${r_idx}"} = check_dither_disable_before_replica( $tlr, $config, $r_idx);		
	}

	return \%feedback;

}

##***************************************************************************
sub check_iu{
##***************************************************************************
	my $check_cfg = shift;
	my ($replica, $r_datestart, $transponder, $timelines, $trans_changes, $config) = 
		@{$check_cfg}{(qw(replica r_datestart transponder timelines trans_changes config))};

	#my $r_tstart $r_tstop, $transponder, $timelines, $config) = @_;
	my %output = (
				  comment => ["Checking IU/transponder state before replica $replica"],
				  criteria => ["Find the commanded IU state before $r_datestart, looking for",
							   'all CIMODESL, CPX???, CPA??? commands',
							   "Compares current CTX/CPA state with desired state for transponder $transponder",
							   "The transponder is predetermined by the hex checks against each template",
							   "if both fail, a 'best guess' based on the smaller number of errors is used",
							   ],
				  status => 1,
				  transponder => $transponder,
				  );

	my %tmpl = ( A => $config->{template}->{A}->{transponder},
				 B => $config->{template}->{B}->{transponder});


        my $want_iu;
	my $state;
	for my $t (reverse @{$timelines}){
		next unless $t->{time} < $check_cfg->{r_tstart};
		$state = $t;
		last;
	}
	if (not defined $state->{iu}){
		push @{$output{info}}, { text => "IU config not set (should be CIU512X or CIU512T)", type => 'error' };
		$output{status} = 0;
	}
	else{
		$want_iu = ($transponder eq 'A') ? 'CIU512T' : 'CIU512X';
		if ($state->{iu} eq $want_iu){
			push @{$output{info}}, { text => "IU config set to $want_iu at ". $state->{datestart}, type => 'info' };
		}
		else{
			push @{$output{info}}, { text => "IU config set to '" . $state->{iu} ."', should be $want_iu", type => 'error' };	
			$output{status} = 0;
		}
	}


	my %want = %{$tmpl{$transponder}};
        $want{iu} = $want_iu;
	my $t_select = 1;
	my @tinfo;
	push @{$output{info}}, {text => "Checking against config for intended transponder $transponder", type => 'info'};
	for my $cm (keys %want){
            next if ($cm eq 'iu');
            push @tinfo, { text => "transponder state $cm set to " . $state->{$cm} . ", should be " . $want{$cm},
                           type => $state->{$cm} ne $want{$cm} ? 'error' : 'info'};
            $t_select = 0 if ($state->{$cm} ne $want{$cm});
	}
	# check for changes during the replica
	if ($state->{tstop} < $check_cfg->{r_tstop}){
            for my $ch (@{$trans_changes}){
                if (($ch->{time} >= $check_cfg->{r_tstart}) & ($ch->{time} <= $check_cfg->{r_tstop})){
                    for my $cm (keys %{$ch}){
                        next if ($cm eq 'time');
                        next if ($cm eq 'date');
                        if ($ch->{$cm} ne $want{$cm}){
                            push @tinfo, {text => "transponder commanding during replica at " . $ch->{date} . " sets bad value",
                                          type => 'error'};
                            push @tinfo, {text => "\tsets $cm to " . $state->{$cm} . ", should be " . $want{$cm},
                                          type => 'error'};
                            $t_select = 0;
                        }
                    }
                }
            }
	}
	else{
            push @{$output{info}}, { text => "Transponder state unchanged through replica end at $check_cfg->{r_datestop}", type => 'info' };
	}

	push @{$output{info}}, @tinfo;
	if ($t_select == 0){
		$output{status} = 0;
		push @{$output{info}}, { text => "Transponder not correctly set for $transponder", type => 'error' };
	}
	else{
		push @{$output{info}}, { text => "Transponder correctly set to $transponder", type => 'info' };
	}

	return \%output;

}


##***************************************************************************
sub iu_timeline{
##***************************************************************************
# Step through the TLR and generate/clock out an array of timeline "states" for 
# the CPA, CTX, and CIMODESL options.

	my $tlr = shift;
	my @timelines;
	my %timeline;
	my %cimodesl = ('7C0 6360' => 'CIU128T',
					'7C0 6380' => 'CIU256T', 
					'7C0 63A0' => 'CIU512T', 
					'7C0 63C0' => 'CIU1024T',
					'7C0 6780' => 'CIU256X', 
					'7C0 67A0' => 'CIU512X', 
					'7C0 67C0' => 'CIU1024X',
					'7C0 6BA0' => 'CIMODESL',
					'7C0 6FA0' => 'CIMODESL');

	my %tog = ( 'ON' => 'ON',
				'OF' => 'OFF');

        my @changes;
	for my $entry (@{$tlr->{entries}}){
		if (defined $entry->comm_mnem()){
			if ($entry->comm_mnem() eq 'CIMODESL'){
				my $iu = $cimodesl{$entry->hex()->[0]};
				if (((not defined $timeline{iu}) or ($iu ne $timeline{iu}))
					and ($iu ne 'CIMODESL')){
					$timeline{iu} = $iu;
					$timeline{datestart} = $entry->datestamp();
					$timeline{time} = $entry->time();
					$timeline{tstart} = $entry->time();
					if (scalar(@timelines)){
						$timelines[-1]->{datestop} = $entry->datestamp();
						$timelines[-1]->{tstop} = $entry->time();
					}
					push @timelines, {%timeline};
				}
                                push @changes, {'time' => $entry->time(),
                                                'date' => $entry->datestamp(),
                                                'iu' => $iu};
			}
			if ($entry->comm_mnem() =~ /^(C(TX|PA))(A|B)(ON|OF)/){
				my $tkey = "$1$3";
				my $tval = $tog{$4};
				if ((not defined $timeline{$tkey}) or ($timeline{$tkey} ne $tval)){
					$timeline{$tkey} = $tval;
					$timeline{datestart} = $entry->datestamp();
					$timeline{time} = $entry->time();
					$timeline{tstart} = $entry->time();
					if (scalar(@timelines)){
						$timelines[-1]->{datestop} = $entry->datestamp();
						$timelines[-1]->{tstop} = $entry->time();
					}
					push @timelines, {%timeline};
				}
                                push @changes, {'time' => $entry->time(),
                                                'date' => $entry->datestamp(),
                                                $tkey => $tval};
                            }
                    }
            }

        return \@timelines, \@changes;

}


 


##***************************************************************************
sub check_dither_disable_before_replica{
##***************************************************************************

    my ($tlr, $config, $replica) = @_;    

    my %output = (
		  comment => ["Dither disable before Dark Cal replica $replica"],
		  );

    my @tlr_arr = @{$tlr->{entries}};

    my %cmd_list = map { $_ => $config->{template}{independent}{$_}} (qw( dither_enable dither_disable ));

    my $index_0 = $tlr->begin_replica($replica)->index();

    my $time_before_replica_0 = $config->{template}{time}{dtime_dither_disable_repl_0};

    push @{$output{criteria}}, sprintf("Steps back through the TLR from the replica start time");
    push @{$output{criteria}}, sprintf("where replica $replica starts at " . $tlr->begin_replica($replica)->datestamp() );
    push @{$output{criteria}}, sprintf("and looks for any dither enable or disable command mnemonics :");

    my $string_cmd_list;
    for my $comm_mnem (map {@$_} @{cmd_list{'dither_enable','dither_disable'}}){
        $string_cmd_list .= " " . $comm_mnem->{comm_mnem};
    }
    push @{$output{criteria}}, $string_cmd_list;
    

    # find the last dither commanding before the first replica
    # create an array of those commands (even if just one command)

    my @last_dith_cmd;

    for my $tlr_entry (reverse @tlr_arr[0 .. $index_0]){
	next unless ( grep { $tlr_entry->comm_mnem() eq $_->{comm_mnem} } (map {@$_} @{cmd_list{'dither_enable','dither_disable'}}) );
	push @last_dith_cmd, $tlr_entry;
	last;
    }

    if (scalar(@last_dith_cmd) == 0){
	push @{$output{info}}, { text => "No Dither Commands found before replica $replica",
				 type => 'error'};
	$output{status} = 0;
	return \%output;
    }

    push @{$output{criteria}}, "Compares discovered dither command to correct dither disable command";
    # confirm that the most recent dither command is correct
    my $match = entry_arrays_match( \@last_dith_cmd, $cmd_list{dither_disable} ); 
    $output{status} = $match->{status};
    for my $data (qw(info criteria)){
	if ($match->{$data}){
	    push @{$output{$data}}, @{$match->{$data}};
	}
    }
    return \%output;
    

}



##***************************************************************************
sub check_dither_enable_at_end{
##***************************************************************************

    my %output = (
		  comment => ['Dither enabled after Dark Cal'],
		  );

    my ($tlr, $config) = @_;    
    
    my @tlr_arr = @{$tlr->{entries}};

    my %cmd_list = map { $_ => $config->{template}{independent}{$_}} (qw( dither_enable dither_disable ));

    my $index_end = $tlr->end_replica(4)->index();
    my $manvr_away_from_dfc = $tlr->manvr_away_from_dfc();

    push @{$output{criteria}}, sprintf("Steps through the TLR from the last hw command at replica 4");
    push @{$output{criteria}}, sprintf("to the maneuver from DFC to ADJCT, where");
    push @{$output{criteria}}, sprintf("end replica 4 at " . $tlr->end_replica(4)->datestamp() );
    push @{$output{criteria}}, sprintf("maneuver away from dfc at  " . $tlr->manvr_away_from_dfc->datestamp() );
    push @{$output{criteria}}, sprintf("looks for any dither enable or disable command mnemonics :");

    my $string_cmd_list;
    for my $comm_mnem (map {@$_} @{cmd_list{'dither_enable','dither_disable'}}){
        $string_cmd_list .= " " . $comm_mnem->{comm_mnem};
    }
    push @{$output{criteria}}, $string_cmd_list;
    

    # find the first dither command after the end of replica 4
    # and before the maneuver away from dark field center at the end of the calibration

    my @dith_cmd;

    for my $tlr_entry (@tlr_arr[$index_end .. $manvr_away_from_dfc->index()]){
	next unless ( grep { $tlr_entry->comm_mnem() eq $_->{comm_mnem} } (map {@$_} @{cmd_list{'dither_enable','dither_disable'}}) );
	last if ($tlr_entry->time() > ($manvr_away_from_dfc->time()));
	push @dith_cmd, $tlr_entry;
    }

    push @{$output{criteria}}, "Throws error on 0 or more than 1 dither enable command in the interval";

    if (scalar(@dith_cmd) == 0 or scalar(@dith_cmd) > 1){
	if (scalar(@dith_cmd) > 1){
	    push @{$output{info}}, { text => "Extra dither commands at end", type => 'error'};
	    for my $entry (@dith_cmd){
		push @{$output{info}}, { text => sprintf($entry->datestamp(). "\t". $entry->comm_mnem()), type => 'error'};
	    }
	}
	else{
	    push @{$output{info}}, { text => "Dither not enabled at end", type => 'error'};
	}
	
	$output{status} = 0;
	return \%output;
    }

    push @{$output{criteria}}, "Compares discovered dither command to correct dither enable command";
    # confirm that the most recent dither command is correct
    my $match = entry_arrays_match( \@dith_cmd, $cmd_list{dither_enable} ); 
    $output{status} = $match->{status};
    for my $data (qw(info  criteria)){
	if ($match->{$data}){
	    push @{$output{$data}}, @{$match->{$data}};
	}
    }
    return \%output;
    


}

##***************************************************************************
sub check_dither_param_before_replica{
##***************************************************************************

    my ($tlr, $config, $replica) = @_;    

    my %output = (
		  comment => ['Dither param before Dark Cal'],
		  );
    
    my @tlr_arr = @{$tlr->{entries}};

    my $dither_null_param = $config->{template}{independent}{dither_null_param}; 
		    
    my %cmd_list;

    for my $cmd (@{$dither_null_param}){
	$cmd_list{$cmd->{comm_mnem}} = 1;
    }

   
    push @{$output{criteria}}, sprintf("Steps back through the TLR from the replica $replica");
    push @{$output{criteria}}, sprintf("where replica $replica at " . $tlr->begin_replica($replica)->datestamp() );
    push @{$output{criteria}}, sprintf("looks for any dither parameter command mnemonics :");

    my $string_cmd_list;
    for my $comm_mnem (keys %cmd_list){
        $string_cmd_list .= " " . $comm_mnem;
    }
    push @{$output{criteria}}, $string_cmd_list;
    
    
    my $index_0 = $tlr->begin_replica($replica)->index();

    my $time_before_replica_0 = $config->{template}{time}{dtime_dither_disable_repl_0};

    # find the last dither commanding before replica 0
    # create an array of those commands (even if just one command)

    my @last_dith_param;

    for my $tlr_entry (reverse @tlr_arr[0 .. $index_0]){
	next unless (defined $cmd_list{$tlr_entry->comm_mnem});
	push @last_dith_param, $tlr_entry;
	last;
    }
    
    push @{$output{criteria}}, "If no commands are found, generates an error.";
	
    if (scalar(@last_dith_param) == 0 ){

	push @{$output{info}}, { text => "Dither parameters not set before replica $replica", type => 'error'};
 	$output{status} = 0;
	return \%output;
    }

    push @{$output{criteria}}, "Otherwise, goes on and compares dither parameter command to correct dither parameter command";

    # confirm that the most recent dither command is correct
    my $match = entry_arrays_match( \@last_dith_param, $dither_null_param ); 
    $output{status} = $match->{status};
    for my $data (qw(info criteria)){
	if ($match->{$data}){
	    push @{$output{$data}}, @{$match->{$data}};
	}
    }
    return \%output;
    

}



##***************************************************************************
sub check_dither_param_at_end{
##***************************************************************************

    my ($tlr, $config) = @_;    

    my %output = (
		  comment => ['Dither param set to default at end'],
		  );
    
    my @tlr_arr = @{$tlr->{entries}};

    my $dither_default_param = $config->{template}{independent}{dither_default_param};

    my %cmd_list;

    for my $cmd (@{$dither_default_param}){
	$cmd_list{$cmd->{comm_mnem}} = 1;
    }


   
    push @{$output{criteria}}, sprintf("Steps through the TLR from the last command at the end of replica 4");
    push @{$output{criteria}}, sprintf("to the command to maneuver away from DFC to ADJCT");
    push @{$output{criteria}}, sprintf( "end of replica 4 at " . $tlr->end_replica(4)->datestamp() );
    push @{$output{criteria}}, sprintf( "maneuver away from dfc at " . $tlr->manvr_away_from_dfc->datestamp() );
    push @{$output{criteria}}, sprintf("looks for any dither parameter command mnemonics :");

    my $string_cmd_list;
    for my $comm_mnem (keys %cmd_list){
        $string_cmd_list .= " " . $comm_mnem;
    }
    push @{$output{criteria}}, $string_cmd_list;
    

    my $index_end = $tlr->end_replica(4)->index();

    my $manvr_away_from_dfc = $tlr->manvr_away_from_dfc();

    # find the last dither commanding before that "start time"
    # create an array of those commands (even if just one command)

    my @dith_param;

    for my $tlr_entry (@tlr_arr[$index_end .. $manvr_away_from_dfc->index()]){
	next unless (defined $cmd_list{$tlr_entry->comm_mnem});
	last if ($tlr_entry->time() > ($manvr_away_from_dfc->time()));
	push @dith_param, $tlr_entry;
    }

    push @{$output{criteria}}, "Throws error on 0 or more than 1 dither parameter command in the interval";

    if (scalar(@dith_param) == 0 or scalar(@dith_param) > 1){

	$output{status} = 0;

	if (scalar(@dith_param) > 1){
	    push @{$output{info}}, { text => "Extra dither params set at end", type => 'error'};
	    for my $entry (@dith_param){
		push @{$output{info}}, { text => sprintf($entry->datestamp() . "\t" . $entry->comm_mnem()),
					 type => 'info'};
	    }
	}
	else{
	    push @{$output{info}}, { text => "Default dither params not set at end", type => 'error' };
	}
	
	return \%output;
    }

    push @{$output{criteria}}, "Otherwise, goes on and compares dither parameter command to correct dither parameter command";

    # confirm that the most recent dither command is correct
    my $match = entry_arrays_match( \@dith_param, $dither_default_param ); 
    $output{status} = $match->{status};
    for my $data (qw(info criteria)){
	if ($match->{$data}){
	    push @{$output{$data}}, @{$match->{$data}};
	}
    }
    return \%output;
	

}



##***************************************************************************
sub check_manvr {
##***************************************************************************
# Check that the maneuver timing is consistent with the template for maneuvers to and from replicas

    my ($config, $manvrs) = @_;

	my %maneuver_times = %{$config->{template}{maneuver}};
	my %init = %{$config->{template}{replica_targ}};
	my %final = %{$config->{template}{replica_targ}};
	
    my %output = (
		  status => 1,
		  comment => ['Maneuver Timing'],
		  );
    
    push @{$output{criteria}}, "Compares the DC maneuver times to and from replicas to the config file times";

	
    for my $manvr (@{$manvrs}){

		# if to or from a replica
		if (($manvr->{init} =~ /DC_T/) or ($manvr->{final} =~ /DC_T/)){
			my $expected_time;
			# to a replica
			if (($manvr->{init} =~ /DFC/) and ($manvr->{final} =~ /DC_T/)){
				$expected_time = $maneuver_times{center_to_replica};
				$final{$manvr->{final}} += 1;
			}
			# from a replica
			if (($manvr->{init} =~ /DC_T/) and ($manvr->{final} =~ /DFC/)){
				$expected_time = $maneuver_times{replica_to_center};
				$init{$manvr->{init}} += 1;
			}
			# if unexpected (as in, oflsid for DFC doesn't match /DFC/)
			if (not defined $expected_time){
				push @{$output{info}}, { text => "Illegal Dark Cal Maneuver. Unexpected maneuver from "
											 . "$manvr->{init} to $manvr->{final} ",
											 type => 'error' };
				$output{status} = 0;
				next;
			}
			my $t_manvr_min = $manvr->{duration};
			push @{$output{info}}, { text => "Maneuver from $manvr->{init} to $manvr->{final} : "
										 . "time = $t_manvr_min min ; "
										 . "expected time = $expected_time",
										 type => 'info' };
			if ($expected_time != $t_manvr_min){
				$output{status} = 0;
				push @{$output{info}}, { text => "Maneuver Time Incorrect",
										 type => "error" };
			}				
			
		}
	}

	# confirm that we have one maneuver to each replica, and one maneuver
	# away from each replica.
	if ((grep {!/1/} values %init) or (grep {!/1/} values %final)){
		push @{$output{info}}, { text => "Extra maneuvering to or from replicas... check manually.",
								 type => "error" };
		$output{status} = 0;
	}

    return \%output;
}
    

##***************************************************************************
sub check_dwell{
##***************************************************************************

    my ($config, $manvrs, $dwells) = @_;

	my %template_dwell = %{$config->{template}{dwell}};
	my %replica_targ = %{$config->{template}{replica_targ}};

    my %output = (
		  status => 1,
		  comment => ['Dwell Timing'],
		  );

    push @{$output{criteria}}, "Checks the dwell time at every replica and at every Dark Field Center just before a replica.";

	# find ids of dfcs before replicas
	my @check_ids;
	for my $manvr (@{$manvrs}){
		if ($manvr->{final} =~ /DC_T/){
			push @check_ids, $manvr->{init};
		}
	}
	# and the replicas themselves
	push @check_ids, sort keys %replica_targ;

	# check 
	for my $id (@check_ids){
		if (not defined $dwells->{$id}){
			push @{$output{info}}, { text => "No dwell found for $id from DOT maneuvers",
									 type => "error"};
			$output{status} = 0;
		}
		my $template_type = ($id =~ /DFC/) ? 'center' : 'replica';
		my ($outputs, $status) = single_dwell_check( $id, 
													 $dwells->{$id}->{duration}, 
													 $template_dwell{$template_type} * 60);
		push @{$output{info}}, @{$outputs};
		$output{status} = 0 if ($status == 0);
		 
	}
	return \%output;
}

##***************************************************************************
sub single_dwell_check{
##***************************************************************************
	my ($oflsid, $dwell, $expected_dwell) = @_;
	
	my $dwell_tolerance = 1; # second		
	my @outputs;
	my $status = 1;

	push @outputs, { text => "Dwell at $oflsid : time = $dwell secs  ; expected time = $expected_dwell secs",
					 type => 'info' };
		
	if (abs($dwell - $expected_dwell) > $dwell_tolerance ){
		if ($dwell < $expected_dwell){
			push @outputs, { text => "Dwell Time incorrect", type => 'error' };
			$status = 0;
		}
		else{
			push @outputs, { text => "Dwell Time too long (probably OK)", type => 'warn' };
			$status = 0;
		}
	}
    return \@outputs, $status;
}

##***************************************************************************
sub timestring_to_secs {
##***************************************************************************
    my $timestring = shift;
    my %timehash;
    ($timehash{days}, $timehash{hours}, $timehash{min}, $timehash{sec}) = split(":", $timestring);
    my $secs = 0;
    $secs += $timehash{days} * 24 * 60 * 60; # secs per day
    $secs += $timehash{hours} * 60 * 60; # secs per hour
    $secs += $timehash{min} * 60; # secs per minute
    $secs += $timehash{sec}; 
    return $secs;

}

##***************************************************************************
sub timestring_to_mins {
##***************************************************************************
    my $timestring = shift;
    my %timehash;
    ($timehash{days}, $timehash{hours}, $timehash{min}, $timehash{sec}) = split(":", $timestring);
    my $mins = 0;
    $mins += $timehash{days} * 24 * 60; # minutes per day
    $mins += $timehash{hours} * 60; # minutes per hour
    $mins += $timehash{min};
    $mins += $timehash{sec} / 60.; # minutes per second
    return $mins;
}


##***************************************************************************
sub check_momentum_unloads {
##***************************************************************************
	
    my ($config, $bs, $manvrs, $dwells) = @_;

	# first, look for any unloads
	my @unloads = ();
	for my $entry (@{$bs}){
		if ((defined $entry->{command}) and (defined $entry->{command}->{TLMSID})){
			if ($entry->{command}->{TLMSID} =~ /AOMUNLGR/){
				push @unloads, $entry->{date};
			}
		}
	}

    my %output = (
				  status => 1,
				  comment => ['Check for Momentum Unloads'],
				  );
    
	
    push @{$output{criteria}}, "Confirms no momentum dumps at DFC or at replicas or during manvr to or from replicas";
	
	# not worth doing much if there aren't any unloads
	if (scalar(@unloads) == 0){
		return \%output;
	}

	
    for my $manvr (@{$manvrs}){
		# maneuver to or from a replica
		if (($manvr->{init} =~ /DC_T/) or ($manvr->{final} =~ /DC_T/)){
			push @{$output{info}}, { text => sprintf("Checking for momentum dumps during maneuver from %s to %s",
													 $manvr->{init},
													 $manvr->{final}),
									 type => 'info'};
			
			for my $unload (@unloads){
				if ((date2time($unload) >= $manvr->{tstart})
					and (date2time($unload) <= $manvr->{tstop})){
					$output{status} = 0;
					push @{$output{info}}, { text => sprintf("Momentum dump at %s during maneuver from %s to %s",
															 $unload,
															 $manvr->{init},
															 $manvr->{final}),
											 type => 'error'};
				}
			}
		}

	}

	# find ids of dfcs before replicas
	my @oflsids;
	for my $manvr (@{$manvrs}){
		if ($manvr->{final} =~ /DC_T/){
			push @oflsids, $manvr->{init};
		}
	}
	# and add the replicas
	my %replica_targ = %{$config->{template}{replica_targ}};
	push @oflsids, sort keys %replica_targ;

	# check all these dwells
	for my $id (@oflsids){
		my ($outputs, $status) = single_unload_check( $dwells->{$id}, \@unloads);
		push @{$output{info}}, @{$outputs};
		$output{status} = 0 if ($status == 0);
	}

    return \%output;
    
    
}

##***************************************************************************
sub single_unload_check{
##***************************************************************************
	my ($dwell, $unloads) = @_;

	my @outputs;
	my $status = 1;

	push @outputs, { text => sprintf("Checking for unloads during $dwell->{oflsid} "
									 . ": %s to %s ", 
									 time2date($dwell->{tstart}),
									 time2date($dwell->{tstop})),
						 type => 'info' };
	
	for my $unload (@{$unloads}){
		if ((date2time($unload) >= $dwell->{tstart})
			and (date2time($unload) <= $dwell->{tstop})){
			$status = 0;
			push @outputs, { text => sprintf("Momentum dump at %s during dwell at %s",
													 $unload,
													 $dwell->{oflsid}),
									 type => 'error'};
		}
	}

    return \@outputs, $status;
}    

##***************************************************************************
sub check_manvr_point{
##***************************************************************************
    
    my ($config, $bs, $manvrs) = @_;

    my %output = (
		  comment => ['Maneuver Pointing'],
		  status => 1,
		  );

    push @{$output{criteria}}, "Confirms that the delta positions for each of the dark cal pointings",
                               "match the expected delta positions listed in the config file";

	my %replica_targ = %{$config->{template}{replica_targ}};
	my %pointings = %{$config->{template}{point}{replicas}};
	my $as_slop = $config->{template}{point}{arcsec_slop};

    my $center_quat;

    for my $manvr (@{$manvrs}){

		my $dest_obsid = $manvr->{final};
		# find maneuvers to a DFC or to a replica
		next unless ($dest_obsid =~ /DFC/ or $dest_obsid =~ /DC_T/);

		# find the first matching backstop target quaternion after the maneuver command
		# time
		my $bs_match;
		for my $bs_entry (@{$bs}) {
			next unless ($bs_entry->{time} > $manvr->{tstart});
			next unless ($bs_entry->{cmd} =~ /MP_TARGQUAT/);
			$bs_match = $bs_entry;
			last;
		}
	    
       	my $targ_quat = Quat->new($bs_match->{command}->{Q1}, 
								  $bs_match->{command}->{Q2}, 
								  $bs_match->{command}->{Q3},
								  $bs_match->{command}->{Q4});

		my %target = ( 
					   obsid => $dest_obsid,
					   quat => $targ_quat,
					   );
		
		# store the quaternion for the field center
		if ($dest_obsid =~ /DFC_I/){
			$center_quat = $targ_quat;
		}
		next unless defined $center_quat;


		my $delta = ($target{quat})->divide($center_quat);
		my $x = sprintf( "%5.2f", rad_to_arcsec($delta->{q}[1]*2));
		my $y = sprintf( "%5.2f", rad_to_arcsec($delta->{q}[2]*2));

		my $pred_point;
		# make a throw-away delta quaternion and then fill in the x and y for the targets
		# DFC/DC_T that are being checked.
		my $temp_delta = ($target{quat})->divide($center_quat);
		if ($dest_obsid =~ /DFC/){
			$temp_delta->{q}[1] = 0;
			$temp_delta->{q}[2] = 0;
			$pred_point = $temp_delta->multiply($center_quat);
		}
		if ($dest_obsid =~ /DC_T/){
			$temp_delta->{q}[1] = arcsec_to_rad($pointings{$dest_obsid}->{dx})/2;
			$temp_delta->{q}[2] = arcsec_to_rad($pointings{$dest_obsid}->{dy})/2;
			$pred_point = $temp_delta->multiply($center_quat);
		}

		if ( !quat_near($target{quat}, $pred_point, $as_slop) ){
			push @{$output{info}}, { text => sprintf("Delta position of " . $target{obsid} 
													 . " relative to DFC of ($x, $y) is incorrect"),
									 type => 'error' };
			$output{status} = 0;
		}
		else{
			push @{$output{info}}, { text => sprintf("Delta position of " . $target{obsid} 
													 . " relative to DFC_I is (% 7.2f, % 7.2f) : Correct", $x, $y),
								 type => 'info' };
		}
    }
    return \%output;
        
}


##***************************************************************************
sub quat_near{
##***************************************************************************
    #radius in arcseconds
    my ($quat1, $quat2, $radius) = @_;
    my $delta = $quat2->divide($quat1);
    my ($d_pitch, $d_yaw) = ($delta->{q}[1]*2, $delta->{q}[2]*2);
    my $dist = rad_to_arcsec(sph_dist($d_pitch, $d_yaw));    
    return ( $dist <= $radius);

}

##***************************************************************************
sub sph_dist{
##***************************************************************************
# in radians
    my ($a2, $d2)= @_;
    my ($a1, $d1) = (0, 0);

    return(0.0) if ($a1==$a2 && $d1==$d2);

    return acos( cos($d1)*cos($d2) * cos(($a1-$a2)) +
              sin($d1)*sin($d2));
}
    
##***************************************************************************
sub rad_to_arcsec{
##***************************************************************************
    my $rad = shift;
    my $r2d = 180./3.14159265358979;
    return $rad*60*60*$r2d;
}

##***************************************************************************
sub arcsec_to_rad{
##***************************************************************************
    my $arcsec = shift;
    my $r2d = 180./3.14159265358979;
    return $arcsec/( 60*60*$r2d );
}


    

##***************************************************************************
sub entry_arrays_match{
##***************************************************************************

    my %output = (
		  status => 1,
		  );


    my ($entries, $config_entries ) = @_;

    if (scalar(@{$entries}) != scalar(@{$config_entries})){
	$output{status} = 0;
	$output{info} = [{ text => "Mismatch in number of commands", type => 'error'}];
	return \%output;
    }
    
    for my $i (0 .. scalar(@{$entries})-1){
	
	my $config_entry = TLREntry->new(%{$config_entries->[$i]});
	my $match = $entries->[$i]->loose_match($config_entry);
	if (defined $match->{info}){
	    push @{$output{info}}, @{$match->{info}};
	}
	
	unless ( $match->{status} ){
	    $output{status} = 0;
	}    
    }
    
    return \%output;
}

##***************************************************************************
sub trim_tlr{
##***************************************************************************

    my $tlr = shift;
    my $config = shift;
    my %command_dict = %{$config->{dict}{TLR}{comm_mnem}};

    my @trim_tlr;
    
    for my $entry (@{$tlr->{entries}}){
	next unless( defined $entry->rel_time() );
	next unless( $entry->rel_time() >= 0 );
	next unless( defined $command_dict{$entry->comm_mnem()});
	if (scalar(@trim_tlr)){
	    $entry->previous_entry($trim_tlr[-1]);
	}
	push @trim_tlr, $entry;
    }

    return \@trim_tlr;
}


##***************************************************************************
sub compare_timingncommanding{
##***************************************************************************

    my $tlr_arr = shift;
    my $templ_arr = shift;
    my $config = shift;
	my $comment = shift;

    my %output = (
				  status => 1,
				  comment => ["$comment"],
				  n_checks => 0,
				  n_fails => 0, 
				  );
    


    my %command_dict = %{$config->{dict}{TLR}{comm_mnem}};
    
    my @match_tlr_arr = @{$tlr_arr};
    
    push @{$output{criteria}}, "Compares TLR entries to template TLR entries";
    my $string_cmd_dict = join(" ", (keys %command_dict));
    push @{$output{criteria}}, $string_cmd_dict;

    push @{$output{criteria}}, "Checks each entry against template entry for matching timing, comm_mnem, and hex.";
    for my $i (0 .. scalar(@match_tlr_arr)-1){
		if ((defined $match_tlr_arr[$i]) and (defined $templ_arr->[$i])){
			my $match = $match_tlr_arr[$i]->matches_entry($templ_arr->[$i]);
			push @{$output{info}}, @{$match->{info}};
			$output{n_checks}++;
			if ( $match->{status} ){
				next;
			}
			else{
				$output{status} = 0;
				$output{n_fails}++;
				next;
			}
		}
		else{
			push @{$output{error}}, "Mismatch in number of entries" ;
			$output{status} = 0;
		}
    }


    push @{$output{criteria}}, "Error if wrong number of commands found";
    if (scalar(@match_tlr_arr) < scalar(@{$templ_arr})){
		push @{$output{info}} , { text => "Not enough entries in the ACA commanding section", type => 'error'} ;
		$output{status} = 0;
    }

    return \%output;
    
}


##***************************************************************************
sub fix_config_hex{
##***************************************************************************

    my $config = shift;

# Config::General doesn't seem to have a method to create single element
# arrays.  Here I push single hex command strings into arrays.  I should get
# the list from the config instead of specifying it here

    my @transponders = ( 'independent' );
    
    for my $transponder (@transponders){

	my $template = $config->{template}{$transponder};

	for my $command (keys %{$template}){

	    if (ref($template->{$command}) ne 'ARRAY'){
		$template->{$command} = [$template->{$command}];
	    }

	    for my $entry (@{$template->{$command}}){
		if ( grep 'hex', (keys %{$entry})){
		    if (ref($entry->{hex}) ne 'ARRAY'){
			$entry->{hex} = [$entry->{hex}];
		    }

		}
	    }


	}
    }


}
		

##***************************************************************************
sub get_file {
##***************************************************************************
    my $glob = shift;
    my $name = shift;
    my $required = shift;
    my $input_files = shift;
    my $warning = ($required ? "ERROR" : "WARNING");

    my @files = glob("$glob");
    if (@files != 1) {
	if (scalar(@files) == 0){
	    croak("$warning: No $name file matching $glob\n");
	}
	else{
	    croak("$warning: Found more than one file matching $glob, using none\n");
	}
    } 
#    $input_files->{$name}=$files[0];
    push @{$input_files}, "Using $name file $files[0]";
    return $files[0];
}


##***************************************************************************
sub print{
##***************************************************************************

	my $dark_cal_checker = shift;
    my $opt = shift;
    my $out;

    for my $file (@{$dark_cal_checker->{input_files}}){
		$out .= "$file \n";
    }
	$out .= "\n";
    

    for my $check (@{$dark_cal_checker->{checks}}){
		$out .= $dark_cal_checker->format_dark_cal_check($check, $opt);
		if ($opt->{html_standalone}){
			$out .= "\n";
		}
    }
    
    $out .= "\n\n";
    $out .= "ACA Dark Cal Checker Report:\n";
    $out .= sprintf( "[" . is_ok($dark_cal_checker->{trans_replica_0}->{status} 
								 and $dark_cal_checker->{trans_replica_1}->{status} 
								 and $dark_cal_checker->{trans_replica_2}->{status} 
								 and $dark_cal_checker->{trans_replica_3}->{status} 
								 and $dark_cal_checker->{trans_replica_4}->{status}) . "]\ttransponder correctly selected before each replica\n");
    $out .= sprintf("[" . is_ok($dark_cal_checker->{tnc_replica_0}->{status}
								and $dark_cal_checker->{tnc_replica_1}->{status}
								and $dark_cal_checker->{tnc_replica_2}->{status}
								and $dark_cal_checker->{tnc_replica_3}->{status}
								and $dark_cal_checker->{tnc_replica_4}->{status}) . "]\tACA Calibration Commanding (hex, sequence, and timing of ACA/OBC commands).\n");
    $out .= sprintf("[". is_ok($dark_cal_checker->{check_manvr}->{status} and $dark_cal_checker->{check_dwell}->{status}) . "]\tManeuver and Dwell timing.\n");
    $out .= sprintf("[" . is_ok($dark_cal_checker->{check_manvr_point}->{status}) . "]\tManeuver targets.\n");
    $out .= sprintf("[" . is_ok($dark_cal_checker->{dither_disable_0}->{status}
								and $dark_cal_checker->{dither_disable_1}->{status}
								and $dark_cal_checker->{dither_disable_2}->{status}
								and $dark_cal_checker->{dither_disable_3}->{status}
								and $dark_cal_checker->{dither_disable_4}->{status}
								and $dark_cal_checker->{check_dither_enable_at_end}->{status}
								and $dark_cal_checker->{check_dither_param_at_end}->{status}) . "]\tDither enable/disable and parameter commands\n");
    
    $out .= "\n";
	
	$out .= $dark_cal_checker->transponder_timing();


    if ($opt->{html_standalone}){
		my $html = "<HTML><HEAD></HEAD><BODY><PRE>" . $out . "</PRE></BODY></HTML>" ;
		return $html;
    }

    return $out;
}

##***************************************************************************
sub transponder_timing{
##***************************************************************************
	my $self = shift;
	my $trans = '';
	my $text = "For dark current operations, transponder should be set to:\n";
	for my $t (0 .. 4){
		if ($trans ne $self->{"tnc_replica_$t"}->{'transponder'}){
			$trans = $self->{"tnc_replica_$t"}->{'transponder'};
			$text .= "Transponder " . $trans;
			if ($t > 0){
				$text .= "\tafter " . $self->{'tlr'}->end_replica($t-1)->datestamp() . "\n\t";
			}
			$text .= "\tbefore " . $self->{'tlr'}->begin_replica($t)->datestamp() . "\n";
			if ($self->{"trans_replica_$t"}->{status} == 1){
				$text .= "\t\t(Commanding already included in Loads)\n";
			}
			else{
				$text .= "\t\tRequires real time commanding\n";
			}
		}
	}

	return $text;
}

##***************************************************************************
sub is_ok{
##***************************************************************************
    my $check = shift;
	my $red_font_start = qq{<font color="#FF0000">};
	my $font_stop = qq{</font>};
    if ($check){
        return "ok";
    }
    else{
        return "${red_font_start}NO${font_stop}";
    }
}



##***************************************************************************
sub format_dark_cal_check{
# Run check controls the printing of all information passed back from the
# checking subroutines
##***************************************************************************

	my $self = shift;
	my $check_name = shift;
	# if anything left, use the options, else set defaults
	my $opt = 1 == @_ ? pop @_ : { 'criteria' => 0, 'verbose' => 0, 'html_standalone' => 0 };

	my $feedback = $self->{$check_name};

	my $red_font_start = qq{<font color="#FF0000">};
	my $yellow_font_start = qq{<font color="#009900">};
	my $blue_font_start = qq{<font color="#0000FF">};
	my $font_stop = qq{</font>};

    my $return_string;
	
	if ($opt->{criteria}){
		# add a ref to get here from the starcheck page
        $return_string .= "<A NAME=\"$check_name\"></A>\n";
	}

    $return_string .= "[" . is_ok($feedback->{status}). "]\t";

	if (!$opt->{criteria} & !$opt->{verbose} & !$opt->{html_standalone} & defined $opt->{link_to}){
		$return_string .= "<A HREF=\"$opt->{link_to}#$check_name\">";
	}

    $return_string .= $feedback->{comment}[0] . "\n";

	if (!$opt->{criteria} & !$opt->{verbose} & !$opt->{html_standalone} & defined $opt->{link_to}){
		$return_string .= "</A>";
	}

    # if verbose or there's an error
    if ($opt->{criteria}){
		for my $line (@{$feedback->{criteria}}){
	    $return_string .= "$blue_font_start         $line${font_stop}\n";
        }	
    }
    if ($opt->{verbose}){
		for my $entry (@{$feedback->{info}}){
			my $line = $entry->{text};
			my $type = $entry->{type};
			if ($type eq 'info'){
				$return_string .= " \t$line \n";
			}
			if ($type eq 'error'){
				$return_string .= "${red_font_start} --->>>  $line${font_stop}\n";
			}
			if ($type eq 'warn'){
				$return_string .= "${yellow_font_start} --->>>  $line${font_stop}\n";
			}
		}	    
		
    }

    return $return_string;
    
}





package TLR;

use strict;
use warnings;
use IO::All;
use Data::Dumper;
use Carp;


##***************************************************************************
sub new {
##***************************************************************************
    my ($class, $file, $type, $config) = @_;
    my @tlr_lines = io($file)->slurp;
    my @tlr_entries;
    my $self;
    $self->{n_entries} = 0;
    $self->{entries} = [];

    bless $self, $class;

    if ($type eq 'tlr'){
	@tlr_entries = get_tlr_array(\@tlr_lines, $config, $self);
    }
    if ($type eq 'template'){
	@tlr_entries = get_templ_array(\@tlr_lines, $config, $self);
    }

    for my $entry (@tlr_entries){
	$self->add_entry($entry);
    }
        
    
    return $self;

}

##***************************************************************************
sub add_entry{
##***************************************************************************
    my $self = shift;
    my $entry = shift;
    $entry->set_index($self->{n_entries});
    $self->{n_entries}++;
    push @{$self->{entries}}, $entry;
    return 1;
}


##***************************************************************************
sub first_aca_hw_cmd{
##***************************************************************************
    my $self = shift;
    return $self->{first_aca_hw_cmd} if (defined $self->{first_aca_hw_cmd});
        
    for my $entry (@{$self->{entries}}){
	if (defined $entry->{comm_mnem}){
	    if ($entry->{comm_mnem} eq 'AAC1CCSC'){
		$self->{first_aca_hw_cmd} = $entry;
		last;
	    }
	}
    }

    croak("No ACA commanding found.") unless defined $self->{first_aca_hw_cmd};


    return $self->{first_aca_hw_cmd};

}

##***************************************************************************
sub begin_replica{
##***************************************************************************
    my $self = shift;
    my $replica = shift;
    return $self->{begin_replica}->{$replica} if (defined $self->{begin_replica}->{$replica});
    
    my @aca_hw_cmds;
        
    for my $entry (@{$self->{entries}}){
		if (defined $entry->trace_id()){
			#print $entry->trace_id(), "\n";
		}
		if ((defined $entry->trace_id()) and ($entry->trace_id() =~ /ADC_R$replica/)){
			$self->{begin_replica}->{$replica} = $entry;	
			last;
		}
		
	}
    
    croak( "Could not find replica $replica beginning")
		unless defined $self->{begin_replica}->{$replica};
    return $self->{begin_replica}->{$replica};

}

##***************************************************************************
sub end_replica{
##***************************************************************************
    my $self = shift;
    my $replica = shift;
    return $self->{end_replica}->{$replica} if (defined $self->{end_replica}->{$replica});
    
	for my $entry (reverse @{$self->{entries}}){
		if ((defined $entry->trace_id()) and ( $entry->trace_id() =~ /ADC_R$replica/)) {
			$self->{end_replica}->{$replica} = $entry;
			last;
	    }
	}


    croak("Could not find replica $replica end")
		unless defined $self->{end_replica}->{$replica};

    return $self->{end_replica}->{$replica};

}

##***************************************************************************
sub last_aca_hw_cmd{
##***************************************************************************
    my $self = shift;
    return $self->{last_aca_hw_cmd} if (defined $self->{last_aca_hw_cmd});
   
    $self->{last_aca_hw_cmd} = $self->end_replica(4);
   

    croak("No ACA commanding found.  Could not define reference entry")
	unless defined $self->{last_aca_hw_cmd};


    return $self->{last_aca_hw_cmd};

}

##***************************************************************************
sub manvr_away_from_dfc{
##*************************************************************************** 
    my $self = shift;
    return $self->{manvr_away_from_dfc} if (defined $self->{manvr_away_from_dfc});

    # I want the maneuver away from dfc, which should be the 2nd maneuver
    # after the last aca hw cmd
    my $manvr_cnt = 0;
    my @manvr_list;
    

    for my $entry (@{$self->{entries}}){
	next unless (defined $entry->{comm_mnem});
	next unless ($entry->time() > $self->last_aca_hw_cmd()->time()); 
#	print $entry->datestamp, "\t", $entry->time(), "\t", ref($entry), "\n";
	next unless ($entry->comm_mnem() eq 'AOMANUVR');
	last if $manvr_cnt == 2;
	push @manvr_list, $entry;
	$manvr_cnt++;
    }

    croak("Error finding maneuver away from DFC. ")
	unless scalar(@manvr_list) == 2;
    
    $self->{manvr_away_from_dfc} = $manvr_list[1];
    
    return $self->{manvr_away_from_dfc};

}


##***************************************************************************
sub get_tlr_array {
##***************************************************************************

    my $raw_tlr = shift;
    my $config = shift;
    my $parent = shift;
    my $arr_field = $config->{format}{TLR}{arr_field};
    my $field = $config->{format}{TLR}{field};
    my @tlr;
    my @raw_tlr_array = @{$raw_tlr};

    for my $line_index (0 .. $#raw_tlr_array){

	my $timestamp =  tlr_substr($raw_tlr_array[$line_index], $field->{datestamp});
	
	if (has_timestamp($timestamp)){
	    
	    my $hex = tlr_substr($raw_tlr_array[$line_index], $arr_field->{hex});

	    if (has_hex($hex)){
		
		my %linehash = ( 
				 type => 'command',
				 parent => $parent,
				 );

		for my $key (keys %{$field}){
		    $linehash{$key} = tlr_substr($raw_tlr_array[$line_index], $field->{$key});
		}
		
		# clean up the hash
		%linehash = remove_nullsnspaces(\%linehash);
		
                # print Dumper %linehash;
		my $entry = CandidateTLREntry->new(%linehash);
		$entry->add_hex($hex);

		push @tlr, $entry;
		
	    }
	    # if there is no hex, store the line as info
	    else{
                my %linehash = (
                                type => 'entry',
				parent => $parent,
                                datestamp => $timestamp,
                                string => $raw_tlr_array[$line_index] =~ s/\s$timestamp//,
                               );
		my $entry = CandidateTLREntry->new(%linehash);
                push @tlr, $entry;
	    }
	}
	# if no timestamp but there is hex
	else{
	    my $hex = tlr_substr($raw_tlr_array[$line_index], $arr_field->{hex});
	    if (defined $hex && $hex =~ /\S\S\S\s\S\S\S\S/){
		my $last_entry = $tlr[-1];
#		print Dumper $last_entry;
		$last_entry->add_hex($hex);
	    }
	}
	
    }

    return @tlr;
    
}

##***************************************************************************
sub remove_nullsnspaces{
##***************************************************************************
    my $hashref = shift;
    my %newhash = %{$hashref};

    #don't bother with nulls and strip off spaces
    while (my ($key, $value) = each(%newhash)){
	if ($value =~ /^\s+$/){
	    delete($newhash{$key});
	}
	else{
	    $newhash{$key} =~ s/^\s+//;
	    $newhash{$key} =~ s/\s+$//;
	}
    }
    
    return %newhash;
}

##***************************************************************************
sub has_hex{
##***************************************************************************
    my $field = shift;
    if (not defined $field){
	return 0;
    }
    if ($field =~ /\S\S\S\s\S\S\S\S/){
	return 1;
    }
    else{
	return 0;
    }

}


##***************************************************************************
sub has_timestamp{
##***************************************************************************
    my $field = shift;
    if ( not defined $field){
	return 0;
    }
    if ( $field =~ /\d\d\d\d:\d\d\d:\d\d:\d\d:\d\d\.\d\d\d/ ){
	return 1;
    }
    else{
	return 0;
    }

}

##***************************************************************************
sub get_templ_array {
##***************************************************************************

    my $raw_tlr = shift;
    my $config = shift;
    my $parent = shift;
    my $field = $config->{format}{Template}{field};

    my $arr_field = $config->{format}{Template}{arr_field};

    my @template;
    my @raw_tlr_array = @{$raw_tlr};

    for my $line_index (0 .. $#raw_tlr_array ){

	my $timestamp_area = tlr_substr($raw_tlr_array[$line_index], $field->{datestamp});

	if (has_timestamp($timestamp_area)){
	    my $hex_area = tlr_substr($raw_tlr_array[$line_index], $arr_field->{hex});	    

	    if (has_hex($hex_area)){
		my %linehash = ( 
				 type => 'command',
				 parent => $parent,
				 );
		
		for my $key (keys %{$field}){
		    $linehash{$key} = tlr_substr($raw_tlr_array[$line_index], $field->{$key});
		}
	    
		#don't bother with nulls and strip off spaces
		%linehash = remove_nullsnspaces(\%linehash);

		my $entry = TemplateTLREntry->new(%linehash);
	    	      
		$entry->add_hex($hex_area);
		
		if (scalar(@template)){
		    $entry->previous_entry($template[-1]);
		}
		
		push @template, $entry;
	    }
	}
	# if no timestamp but there is hex
	else{
	    my $hex_area = tlr_substr($raw_tlr_array[$line_index], $arr_field->{hex});
	    if (has_hex($hex_area)){
		my $last_entry = $template[-1];
		$last_entry->add_hex($hex_area);
	    }
	}
	
    }


    return @template;

}


##***************************************************************************
sub tlr_substr{
##***************************************************************************
    my $line = shift;
    my $loc_ref = shift;
    my $string;

    if (length($line) >= $loc_ref->{stop}){
	$string = substr($line, ($loc_ref->{start}-1), ($loc_ref->{stop}-($loc_ref->{start}-1)));
    }

    return $string;
}



package TLREntry;

use strict;
use Carp;
use Ska::Convert qw(date2time);


use Class::MakeMethods::Standard::Hash  (
					 scalar => [ (qw(
							comm_desc
							datestamp
							replica
							hex
							index
							trace_id
							previous_entry
							))
						     ],
					 );


##***************************************************************************
sub new{
##***************************************************************************
    my ($class, %data) = @_;
    my $clean_hash = strip_whitespace(\%data);
    bless $clean_hash, $class;

}

##***************************************************************************
sub set_index{
##***************************************************************************
    my $self = shift;
    $self->{index} = shift;
}

##***************************************************************************
sub matches_entry{
##***************************************************************************
    my $entry1 = shift;
    my $entry2 = shift;

    my %output = (
		  status => 0,
		  );

    $output{info} = [{ text =>  sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc()),
		       type => 'info'}];

    my $comm_mnem_match = ($entry1->comm_mnem() eq $entry2->comm_mnem());
	
    if ( !$comm_mnem_match ){
#	push @{$output{error}} ,sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc());
	push @{$output{info}}, { text =>  sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc()),
				 type => 'error'};

	push @{$output{info}}, { text => sprintf( "\tBad comm_mnem: " . $entry1->comm_mnem() . " does not match expected " . $entry2->comm_mnem()), 
				  type => 'error' };
    }

    my $REL_TIME_TOL = 1e-6; # seconds
    my $step_rel_time_match = (abs($entry1->step_rel_time_replica() - $entry2->step_rel_time_replica()) < $REL_TIME_TOL);
    if ( !$step_rel_time_match ){
#	push @{$output{error}} ,sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc());
#	push @{$output{error}}, sprintf("step relative time mismatch: " . $entry1->step_rel_time_replica() . " secs tlr, " . $entry2->step_rel_time_replica() . " secs template ");
	push @{$output{info}}, { text =>  sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc()),
			 type => 'error'};

	push @{$output{info}}, { text => sprintf("step relative time mismatch: " 
											 . $entry1->step_rel_time_replica() . " secs tlr, " 
											 . $entry2->step_rel_time_replica() . " secs template "),
				 type => 'error'};
    }
    else{
	push @{$output{info}}, { text => sprintf("step relative time match : " . $entry1->step_rel_time_replica() . " secs "),
				 type => 'info' };
    }

#    my $rel_time_match = ($entry1->rel_time() == $entry2->rel_time());
#
#    if ( !$rel_time_match ){
##	push @{$output{info}} ,sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc());
##	push @{$output{info}}, { text =>  sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc()),
##			 type => 'error'};
#
#		push @{$output{info}}, { text => sprintf( "Bad rel time from start: " . $entry1->rel_time() . " does not match expected " . $entry2->rel_time()),
#							 type => 'info'};
#}
#    else{
#		push @{$output{info}}, { text => sprintf("Good rel time from start: " . $entry1->rel_time() . " secs "),
#				 type => 'info'};
#    }

    my $hex_equal = check_hex_equal($entry1->hex(), $entry2->hex());
    if (defined $hex_equal->{info}){
	push @{$output{info}}, @{$hex_equal->{info}};
    }
    if (($entry1->comm_mnem() eq $entry2->comm_mnem()) and
	($step_rel_time_match) and
	($hex_equal->{status})){
	$output{status} = 1;
    }
	 
    return \%output;
    
} 

##***************************************************************************
sub loose_match{

    my $entry1 = shift;
    my $entry2 = shift;

    my %output;

    $output{status} = 0;

    $output{info} = [{ text => sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc()),
		       type => 'info',
		   }];

    my $comm_mnem_match = ($entry1->comm_mnem() eq $entry2->comm_mnem());

    if ( !$comm_mnem_match ){

	push @{$output{info}}, { text => sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc()),
			   type => 'error',
			     };
	
	push @{$output{info}}, { text => sprintf( "\tBad comm_mnem: " . $entry1->comm_mnem() . " does not match expected " . $entry2->comm_mnem()),
				 type => 'error',
			     };
    }

    my $hex_equal = check_hex_equal($entry1->hex(), $entry2->hex());

    if (defined $hex_equal->{info}){
	push @{$output{info}}, @{$hex_equal->{info}};
    }
#    if (defined $hex_equal->{error}){
#	push @{$output{error}}, sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc());
#	push @{$output{error}}, @{$hex_equal->{error}};
#    }


    if (($comm_mnem_match) and
	($hex_equal->{status})){
	$output{status} = 1;	
    }
    
    return \%output;
    
} 




##***************************************************************************
sub check_hex_equal {
##***************************************************************************

    my %output;
    $output{status} = 1;

    my ($hex_a, $hex_b) = @_;

    if ( scalar(@{$hex_a}) != scalar(@{$hex_b}) ){
	$output{info} = [{ text => "hex commands have different number of entries",
			   type => 'error'}];
	$output{status} = 0;
	return \%output;
    }
    
    for my $i (0 .. scalar(@{$hex_a})-1){
	if ($hex_a->[$i] ne $hex_b->[$i]){
	    $output{info} = [{ text => "\tBad hex: $hex_a->[$i] does not match expected $hex_b->[$i]",
			       type => 'error'}];
	    $output{status} = 0;
	    return \%output;
	}
	push @{$output{info}}, { text => "\thex ok: $hex_a->[$i] matches expected $hex_b->[$i]",
				 type => 'info'};
    }

    return \%output;
 	    
     
}
    


##***************************************************************************
sub strip_whitespace{
##***************************************************************************
    my $hash = shift;
    my %clean_hash;

    while ( my ($key, $value) = each (%{$hash})){
	$value =~ s/\s+$//;
	$value =~ s/^\s+//;
	$clean_hash{$key} = $value;
    }
    return \%clean_hash;
}

##***************************************************************************
sub time{
##***************************************************************************
    my $entry = shift;

    if (@_){
	$entry->{time} = $_[0];
    } elsif (not defined $entry->{time}){
	$entry->{time} = date2time($entry->datestamp);
   }
    return $entry->{time};
}

##***************************************************************************
sub comm_mnem{
# return empty string instead of undef if undefined!
##***************************************************************************
    my $entry = shift;
    if (defined $entry->{comm_mnem}){
	return $entry->{comm_mnem};
    }
    return qq();
}

sub step_rel_time_replica{
	# reset to give replica relative times...
    my $entry = shift;
    if ((defined $entry->previous_entry())
		and (defined $entry->replica())
		and (defined $entry->previous_entry()->replica())
		and ($entry->previous_entry()->replica() == $entry->replica())){
		return ( $entry->time() - $entry->previous_entry()->time());		
	}
    return 0;
}


##***************************************************************************
sub rel_time{
##***************************************************************************
    my $entry = shift;
    return ($entry->time() - $entry->{parent}->first_aca_hw_cmd->time());

}


##***************************************************************************
sub add_hex{
##***************************************************************************
    my ($entry, $hex) = @_;
    push @{$entry->{hex}}, $hex;
}
1;


package TemplateTLREntry;

use strict;
use warnings;
use Carp;

use base 'TLREntry';

our @ISA = qw( TLREntry );
1;


package CandidateTLREntry;
use strict;
use warnings;
use Carp;

use base 'TLREntry';

our @ISA = qw( TLREntry );

sub replica{
	my $self = shift;
	return $self->{replica} if (defined $self->{replica});
	for my $r_idx (0 .. 4){
		# find the indexes in the real tlr and trim to a reduced set of commands to check
		my $r_start = $self->{parent}->begin_replica($r_idx)->index();
		my $r_end = $self->{parent}->end_replica($r_idx)->index();
		if (($self->index() >= $r_start) and ($self->index() <= $r_end)){
			$self->{replica} = $r_idx;
			return $self->{replica};
		}
	}
	return undef;
}

1;


