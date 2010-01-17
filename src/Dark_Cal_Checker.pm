package Ska::Starcheck::Dark_Cal_Checker;

# part of aca_dark_cal_checker project

use strict;
use warnings;
use Carp;
use IO::All;
use Ska::Convert qw(date2time);
use Quat;
use Config::General;
use Math::Trig;

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
	       );
    
    # Override Defaults as needed from passed parameter hash
    while (my ($key,$value) = each %{$par_ref}) {
	$par{$key} = $value;
    }
    
    
# Create a hash to store all information about the checks as they are performed
    my %feedback = (
		    input_files => [],
		    dark_cal_present => 1,
		    );
	
# %Input files is used by get_file()

    my %config = ParseConfig(-ConfigFile => "$par{app_data}/$par{config}");
    fix_config_hex(\%config);

    my $tlr_file    = get_file("$par{dir}/$par{tlr}", 'tlr', 'required', \@{$feedback{input_files}});

    my $tlr = TLR->new($tlr_file, 'tlr', \%config);

    my $transponder;

    
    eval{
	$feedback{transponder} = identify_transponder($tlr, \%config);
    };
    if ($@){
	my $error = $@;
	if ($error =~ /No ACA commanding found/){
	    $feedback{dark_cal_present} = 0;
	    return \%feedback;
	}
	else{
	    croak($error);
	}
    }


    if ($feedback{transponder}->{status}){
	$transponder = $feedback{transponder}->{transponder};
    } 
    else{
	# identify transponder should croak if problem, but:
	die "Transponder not correctly selected!\n";
    }
    
    if ($par{verbose}){
	print "\n";
    }
    
    my $mm_file = get_file("$par{dir}/$par{mm}", 'Maneuver Management', 'required', \@{$feedback{input_files}});
    my $dot_file = get_file("$par{dir}/$par{dot}", 'DOT', 'required', \@{$feedback{input_files}});
    my @mm = Ska::Parse_CM_File::MM({file => $mm_file, ret_type => 'array'});
    my ($dot_href, $s_touched, $dot_aref) = Ska::Parse_CM_File::DOT($dot_file);
    my $bs_file = get_file("$par{dir}/$par{backstop}", 'Backstop', 'required', \@{$feedback{input_files}});
    my @bs = Ska::Parse_CM_File::backstop($bs_file);
    
    my $template_file = get_file("$par{app_data}/$config{file}{template}{$transponder}", 'template', 'required', \@{$feedback{input_files}} );
    my $template = TLR->new($template_file, 'template', \%config);

#    $feedback{check_mm_vs_backstop} = check_mm_vs_backstop( $mm_file, $bs_file );
    $feedback{check_tlr_sequence} = check_tlr_sequence($tlr);
    $feedback{check_transponder} = check_transponder($tlr, \%config); 
    $feedback{check_dither_disable_before_replica_0} = check_dither_disable_before_replica_0($tlr, \%config);
    $feedback{check_dither_param_before_replica_0} = check_dither_param_before_replica_0($tlr, \%config);
    $feedback{check_for_dither_during} = check_for_dither_during($tlr, \%config);
    $feedback{check_dither_enable_at_end} = check_dither_enable_at_end($tlr, \%config);
    $feedback{check_dither_param_at_end} = check_dither_param_at_end($tlr, \%config);
    $feedback{compare_timingncommanding} = compare_timingncommanding($tlr, $template, \%config);

    if (!$feedback{compare_timingncommanding}->{status}){
	if ($transponder eq 'A'){
#	    print "\tTrying other template\n";
	    my $test_template_file = get_file("$par{app_data}/$config{file}{template}{B}", 'template', 'required', \@{$feedback{input_files}});
	    my $test_template = TLR->new($test_template_file, 'template', \%config);
	    my $test_other = compare_timingncommanding($tlr, $test_template, \%config);
	    if ($test_other->{status}){
		print "--->>>  Matches template for B transponder; check selected transponder.\n";
	    }
	}
	else{
#	    print "\tTrying other template\n";
	    my $test_template_file = get_file("$par{app_data}/$config{file}{template}{A}", 'template', 'required', \@{$feedback{input_files}} );
	    my $test_template = TLR->new($test_template_file, 'template', \%config);
	    my $test_other = compare_timingncommanding($tlr, $test_template, \%config);
	    if ($test_other->{status}){
		print "--->>>  Matches template for A transponder; check selected transponder.\n";
	    }
	    
	}
    }
    $feedback{check_manvr} = check_manvr( \%config, \@bs, $dot_aref);
    $feedback{check_dwell} = check_dwell(\%config, \@bs, $dot_aref);
    $feedback{check_manvr_point} = check_manvr_point( \%config, \@bs, $dot_aref);

    bless \%feedback, $class;
    return \%feedback;

}

# Phasing out use of maneuver processing summary in Jun 2008.
# Eliminating this routine

###***************************************************************************
#sub check_mm_vs_backstop{
###***************************************************************************
## confirm that that maneuver summary times and quaternions match the backstop
#
#    my $ms_file = shift;
#    my $bs_file = shift;
#
#    my %output = (
#		  status => 1,
#		  comment => ['Comparing Backstop maneuvers to those in Maneuver Summary'],
#		  criteria => ['Confirms that each backstop maneuver has a match in maneuver summary',
#			       'Matches start of maneuver at AONMMODE and target quaternion MP_TARGQUAT'],
#		  );
#    eval{
#	Ska::Parse_CM_File::verifyMM($ms_file, $bs_file);
#      };
#    if ($@){
#	print "$@ \n";
#	$output{status} = 0;
#	$output{info} = [{ text =>"$@", type => 'error' }];
#    }
#    return \%output;
#}		      
	    

 
##***************************************************************************
sub check_tlr_sequence{
# This check is not required, but it did assist when some of my "intentionally
# broken" checks did not work, because the datestamp on the line was used as 
# the time point instead of the command's position in the tlr.
##***************************************************************************

    my $tlr = shift;

    # default is ok, unless there is a problem
    my %output = (
		  status => 1,
		  comment => ['Checking TLR to confirm commands are consecutive'],
		  criteria => ['Confirms that each timestamp in the TLR is >= to the previous timestamp'],
		  );
		   
    my @tlr_arr = @{$tlr->{entries}};

    my $last_time;
    
    for my $entry (@tlr_arr){
	if (not defined $last_time){
	    $last_time = $entry->time();
	    next;
	}
	if ($entry->time() < $last_time ){
	    my $string = sprintf("TLR timestamps are non-sequential near TLR index ", $entry->index(), " \n");
	    my @info = [{ text => $string, type => 'error' }];
	    $output{status} = 0;
#	    $output{error} = \@info;
	}
	$last_time = $entry->time();
    }
    return \%output;
}

##***************************************************************************
sub identify_transponder{
##***************************************************************************

    my %output = (
		  criteria => ['Finds last set of transponder commands before first aca hw cmd'],
		  );

    my ($tlr, $config) = @_;
    
    my %cmd_list = map { $_ => $config->{template}{$_}{transponder}} qw( A B);    
    push @{$output{criteria}}, "transponder commands identified by mnemonic as any one of:";
    my $string_cmd_list;
    for my $comm_mnem (map {@$_} @{cmd_list{'A','B'}}){
        $string_cmd_list .= " " . $comm_mnem->{comm_mnem};
    }
    push @{$output{criteria}}, $string_cmd_list;


    my @tlr_arr = @{$tlr->{entries}};
    my $index_0 = $tlr->first_aca_hw_cmd->index();
    push @{$output{criteria}}, sprintf('First aca hw cmd at ' . $tlr->first_aca_hw_cmd->datestamp());

    # find the last transponder commanding before the first aca hw cmd

    my $cmd_cnt = 0;
    my @last_trans_cmd;
    
    push @{$output{criteria}}, sprintf("Searches back from first aca hw cmd until " 
				       . scalar(@{$cmd_list{A}}) . " transponder commands identified");

    for my $tlr_entry (reverse @tlr_arr[0 .. $index_0]){
	last unless ($cmd_cnt < scalar(@{$cmd_list{A}}));
	next unless ( grep { $_->{comm_mnem} eq $tlr_entry->comm_mnem() } (map {@$_} @{cmd_list{'A','B'}}) );
	$cmd_cnt++;
	unshift @last_trans_cmd, $tlr_entry;
    }

    push @{$output{criteria}}, "Last group of commands is then compared to templates for A and B transponder selection";


    # Compare the array of commands to the correct commanding for the A transponder
#    push @{$output{info}}, "Comparing transponder commands to list for transponder A ... ";
    my $A = entry_arrays_match( \@last_trans_cmd, $cmd_list{'A'});
    if ($A->{status}){
	push @{$output{info}}, { text => "Comparing transponder commands to list for transponder A ... ", type => 'info' };
	push @{$output{info}}, @{$A->{info}};
	$output{transponder} = 'A';
	$output{comment} = ["Identifying Transponder: Transponder Selected = A"],
	$output{status} = 1;
	return \%output;
    }
    else{
	push @{$output{criteria}}, "Comparing transponder commands to list for transponder A ... Failed";
	push @{$output{info}}, { text => "Comparing transponder commands to list for transponder A ... Failed", 
				 type => 'error'};
	push @{$output{info}}, @{$A->{info}};
#	push @{$output{criteria}}, @{$A->{info}};
    }
    

    # Compare the array of commands to the correct commanding for the B transponder

    
    my $B = entry_arrays_match( \@last_trans_cmd, $cmd_list{'B'});
    if ($B->{status}){
	push @{$output{info}}, { text => "Comparing transponder commands to list for transponder B ... ", type => 'info'};
	push @{$output{info}}, @{$B->{info}};
	$output{transponder} = 'B';
	$output{comment} = ["Identifying Transponder: Transponder Select = B"],
	$output{status} = 1;
	return \%output;
    }
    else{
	push @{$output{criteria}}, "Comparing transponder commands to list for transponder B ... Failed ";
	push @{$output{info}}, { text => "Comparing transponder commands to list for transponder B ... Failed",
				 type => 'error'};
	push @{$output{info}}, @{$B->{info}};
#	push @{$output{criteria}}, @{$B->{info}};
    }
    return \%output;

#    croak("Transponder not selected correctly before ACA HW commands\n");


}

##***************************************************************************
sub check_transponder{
# this checks to confirm the absence of *additional* transponder commands
# during the aca commanding
##***************************************************************************
    
    my %output = (
		  comment => ['Checking for Additional Transponder Commands'],
		  );

    my ($tlr, $config) = @_;
    my %cmd_list = map { $_ => $config->{template}{$_}{transponder}} qw( A B);

    my @tlr_arr = @{$tlr->{entries}};
    my $index_0 = $tlr->first_aca_hw_cmd->index();
    my $index_1 = $tlr->last_aca_hw_cmd->index();

    # time after last AAC1CCSC to end of template
    my $time_for_wrap_up = $config->{template}{time}{time_for_wrap_up} * 60;
    # the time from end of track to transponder off should be 30 minutes, but again
    # let's take that from the config file
    my $dtime_end_of_track = $config->{template}{time}{dtime_end_of_track} * 60;

    my @trans_cmd_during;

    for my $tlr_entry (@tlr_arr[$index_0 .. (scalar(@tlr_arr)-1)]){
	# ignore CIMODESL (they're in the transponder dictionary, but they aren't unique to 
	# transponder commands)
	next if ($tlr_entry->comm_mnem() eq 'CIMODESL');
	next unless ( grep { $_->{comm_mnem} eq $tlr_entry->comm_mnem() } (map {@$_} @{cmd_list{'A','B'}}) );
	# stop checking when we reach end of track
	last if ($tlr_entry->time() >= ($tlr->last_aca_hw_cmd->time() + $time_for_wrap_up + $dtime_end_of_track));
	push @trans_cmd_during, $tlr_entry;
    }

    push @{$output{criteria}}, sprintf("Searches the TLR for any transponder commands (ignoring CIMODESL) between the first ACA hw cmd");
    push @{$output{criteria}}, sprintf( "and end of track, which we define as the time of the last aca hw cmd at");
    push @{$output{criteria}}, sprintf( $tlr->last_aca_hw_cmd->datestamp() . " + padding of " 
					. $config->{template}{time}{time_for_wrap_up} 
					. " min + time of end of track to end of comm of " 
					. $config->{template}{time}{dtime_end_of_track}
					. " min");

    push @{$output{criteria}}, "Any transponder commands in interval result in error";
    
    # there is a problem/ or the load should be examined by hand if there are any transponder commands
    if (scalar(@trans_cmd_during) == 0){
	$output{status} = 1;
	return \%output;
    }
    else{
	$output{status} = 0;
	$output{info} = [{ text => "Additional transponder commanding discovered during dark cal sequence!",
			   type => 'error'}];
	for my $entry (@trans_cmd_during){
	    my $string = $entry->datestamp . "\t" . $entry->comm_mnem . "\t" . $entry->comm_desc . "\n";
	    push @{$output{info}}, { text => $string,
				     type => 'error'};
	}
	return \%output;
    }


}

##***************************************************************************
sub check_dither_disable_before_replica_0{
##***************************************************************************

    my ($tlr, $config) = @_;    

    my %output = (
		  comment => ['Dither disable before Dark Cal'],
		  );

    my @tlr_arr = @{$tlr->{entries}};

    my %cmd_list = map { $_ => $config->{template}{independent}{$_}} qw( dither_enable dither_disable );

    my $index_0 = $tlr->begin_replica(0)->index();

    my $time_before_replica_0 = $config->{template}{time}{dtime_dither_disable_repl_0};

    push @{$output{criteria}}, sprintf("Steps back through the TLR from the first aca hw command at replica 0");
    push @{$output{criteria}}, sprintf("where replica 0 at " . $tlr->begin_replica(0)->datestamp() );
    push @{$output{criteria}}, sprintf("looks for any dither enable or disable command mnemonics :");

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
	push @{$output{info}}, { text => "No Dither Commands found before Dark Current Calibration",
				 type => 'error'};
	$output{status} = 0;
	return \%output;
    }

    push @{$output{criteria}}, "Compares discovered dither command to correct dither disable command";
    # confirm that the most recent dither command is correct
    my $match = entry_arrays_match( \@last_dith_cmd, $cmd_list{dither_disable} ); 
    $output{status} = $match->{status};
    for my $data qw(info criteria){
	if ($match->{$data}){
	    push @{$output{$data}}, @{$match->{$data}};
	}
    }
    return \%output;
    

}



##***************************************************************************
sub check_for_dither_during{
##***************************************************************************

    my %output = (
		  status => 1,
		  comment => ['Dither changes during Dark Cal'],
		  );
    
    my ($tlr, $config) = @_;    
    
    my @tlr_arr = @{$tlr->{entries}};

    my %cmd_list = map { $_ => $config->{template}{independent}{$_}} qw( dither_enable dither_disable dither_null_param );

    my $string_cmd_list;
    for my $comm_mnem (map {@$_} @{cmd_list{'dither_enable','dither_disable', 'dither_null_param'}}){
        $string_cmd_list .= " " . $comm_mnem->{comm_mnem};
    }

    my $index_start = $tlr->begin_replica(0)->index();
    my $index_end = $tlr->end_replica(4)->index();

    push @{$output{criteria}}, sprintf("Steps through the TLR from the beginning of Replica 0 to the end of Replica 4");
    push @{$output{criteria}}, sprintf("begin replica 0 at " . $tlr->begin_replica(0)->datestamp()
				       . ", end replica 4 at " . $tlr->end_replica(4)->datestamp());
    push @{$output{criteria}}, sprintf("and searches for any dither enable, disable, or parameter commands, those with comm_mnem like: ");
    push @{$output{criteria}}, $string_cmd_list;
    push @{$output{criteria}}, "Any extra dither commanding is an error";

    # find any dither commands during the dark cal
    # create an array of those commands 

    my @dith_cmd_during;

    for my $tlr_entry (@tlr_arr[$index_start .. $index_end]){
	next unless ( grep { $tlr_entry->comm_mnem() eq $_->{comm_mnem} } 
		      (map {@$_} @{cmd_list{'dither_enable','dither_disable','dither_null_param'}}) );
	push @dith_cmd_during, $tlr_entry;
    }

    if (scalar(@dith_cmd_during) == 0){
	push @{$output{info}}, { text => "No extra dither commanding found", type => 'info'};
	return \%output;
    }
    else{
	push @{$output{info}}, { text => "Additional dither commanding discovered during dark cal sequence!", type => 'error'};
	for my $entry (@dith_cmd_during){
	    push @{$output{error}}, { text => sprintf($entry->datestamp . "\t" . $entry->comm_mnem ."\t" . $entry->comm_desc),
				      type => 'error' };
	}
	$output{status} = 0;
	return \%output;
    }

}


##***************************************************************************
sub check_dither_enable_at_end{
##***************************************************************************

    my %output = (
		  comment => ['Dither enabled after Dark Cal'],
		  );

    my ($tlr, $config) = @_;    
    
    my @tlr_arr = @{$tlr->{entries}};

    my %cmd_list = map { $_ => $config->{template}{independent}{$_}} qw( dither_enable dither_disable );

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
    for my $data qw(info  criteria){
	if ($match->{$data}){
	    push @{$output{$data}}, @{$match->{$data}};
	}
    }
    return \%output;
    


}

##***************************************************************************
sub check_dither_param_before_replica_0{
##***************************************************************************

    my ($tlr, $config) = @_;    

    my %output = (
		  comment => ['Dither param before Dark Cal'],
		  );
    
    my @tlr_arr = @{$tlr->{entries}};

    my $dither_null_param = $config->{template}{independent}{dither_null_param}; 
		    
    my %cmd_list;

    for my $cmd (@{$dither_null_param}){
	$cmd_list{$cmd->{comm_mnem}} = 1;
    }

   
    push @{$output{criteria}}, sprintf("Steps back through the TLR from the first aca hw command at replica 0");
    push @{$output{criteria}}, sprintf("where replica 0 at " . $tlr->begin_replica(0)->datestamp() );
    push @{$output{criteria}}, sprintf("looks for any dither parameter command mnemonics :");

    my $string_cmd_list;
    for my $comm_mnem (keys %cmd_list){
        $string_cmd_list .= " " . $comm_mnem;
    }
    push @{$output{criteria}}, $string_cmd_list;
    
    
    my $index_0 = $tlr->begin_replica(0)->index();

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

	push @{$output{info}}, { text => "Dither parameters not set before replica 0", type => 'error'};
 	$output{status} = 0;
	return \%output;
    }

    push @{$output{criteria}}, "Otherwise, goes on and compares dither parameter command to correct dither parameter command";

    # confirm that the most recent dither command is correct
    my $match = entry_arrays_match( \@last_dith_param, $dither_null_param ); 
    $output{status} = $match->{status};
    for my $data qw(info criteria){
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
    for my $data qw(info criteria){
	if ($match->{$data}){
	    push @{$output{$data}}, @{$match->{$data}};
	}
    }
    return \%output;
	

}



##***************************************************************************
sub check_manvr {
##***************************************************************************

    my ($config, $bs, $dot) = @_;
    my @templ_manvr = @{$config->{template}{manvr}{manvr}};

#    use Data::Dumper;
#    print Dumper $dot;

    my %output = (
		  status => 1,
		  comment => ['Maneuver Timing'],
		  );
    

    push @{$output{criteria}}, "Compares the maneuver times from the dot to the config file times";



    my @manvrs;
    for my $dot_entry (@{$dot}){
	if ($dot_entry->{cmd_identifier} =~ /ATS_MANVR/){
	    push @manvrs, $dot_entry;
	}
    }



#
    my $start_m_check = 0;
    my $j = 0;
    my $end_m_check = 1;

    my $templ_n_manvr = scalar(@templ_manvr);

    for my $manvr_idx (1 ... $#manvrs){
	
	my $manvr = $manvrs[$manvr_idx];

	if ($manvr->{oflsid} eq $templ_manvr[0]{final}){
	    $start_m_check = 1;
	}
	
	next unless ($start_m_check and $end_m_check);
	my $t_manvr_min = timestring_to_mins($manvr->{DURATION});

	my $templ_t_manvr = $templ_manvr[$j]{time};
	
	push @{$output{info}}, { text => "Maneuver to $manvr->{oflsid} : time = $t_manvr_min min  ; expected time = $templ_t_manvr min",
				 type => 'info' };
		

	if ($templ_t_manvr != $t_manvr_min){
	    push @{$output{info}}, { text => "Maneuver Time incorrect",
				     type => 'error'};
	    $output{status} = 0;
	    return \%output;
	}
	
	$j++;

	if ($manvrs[$manvr_idx]->{oflsid} eq $templ_manvr[-1]{final}){
	    $end_m_check = 0;
	}

    }

    if ($templ_n_manvr != $j){
	push @{$output{info}}, { text => "$j maneuvers checked ; expected $templ_n_manvr maneuvers",
				 type => 'error'};
    }
    
    
    return \%output;
    
    
}
    

##***************************************************************************
sub check_dwell{
##***************************************************************************

    my ($config, $bs, $dot) = @_;

    my @templ_manvr = @{$config->{template}{manvr}{manvr}};
    my @templ_dwell = @{$config->{template}{manvr}{dwell}};

    my %output = (
		  status => 1,
		  comment => ['Dwell Timing'],
		  );

    push @{$output{criteria}}, "Compares the time between maneuvers in the DOT to the config file dwell times";

    my @manvrs;
    for my $dot_entry (@{$dot}){
	if ($dot_entry->{cmd_identifier} =~ /ATS_MANVR/){
	    push @manvrs, $dot_entry;
	}
    }

    
    my $j = 0;
    my $start_d_check = 0;
    my $end_d_check = 1;

    for my $manvr_idx (0 .. $#manvrs ){
	
	my $manvr = $manvrs[$manvr_idx];

	if ($manvr->{oflsid} eq $templ_dwell[0]{final}){
	    $start_d_check = 1;
	}

	next unless ($start_d_check and $end_d_check);
	
	if ($manvr->{oflsid} ne $templ_dwell[$j]{init}){
	    $output{info} = [{ text => "Dwell Sequence Problem", type => 'error' }];
	    $output{status} = 0;
	    return \%output;
	}

	# how many secs before man start?
	my $t_manvr_delay = timestring_to_secs($manvr->{MANSTART});
	# how long is the maneuver?
	my $t_manvr_dur = timestring_to_secs($manvr->{DURATION});

	# so, we get there at:
	my $t_manvr_stop = $manvr->{time} + $t_manvr_delay + $t_manvr_dur;

	# the next maneuver starts at
	my $t_manvr_next = $manvrs[ $manvr_idx + 1]->{time};

	# dwell time is then
	my $t_dwell_sec = $t_manvr_next - $t_manvr_stop;
	my $templ_t_dwell_sec = $templ_dwell[$j]{time} * 60; # template has minutes
	
	push @{$output{info}}, { text => "Dwell at $manvr->{oflsid} : time = $t_dwell_sec secs  ; expected time = $templ_t_dwell_sec secs",
				 type => 'info' };

	my $dwell_tolerance = 1; # second
	if (abs($t_dwell_sec - $templ_t_dwell_sec) > $dwell_tolerance ){
	    push @{$output{info}}, { text => "Dwell Time incorrect", type => 'error' };
	    $output{status} = 0;
	}
	
	$j++;

	if ($manvrs[$manvr_idx]{oflsid} eq $templ_manvr[-1]{final}){
	    $end_d_check = 0;
	}

    }
    
    return \%output;
    
    
}


sub timestring_to_secs {
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

sub timestring_to_mins {
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
sub check_manvr_point{
##***************************************************************************
    
    my ($config, $bs, $dot) = @_;

    my %output = (
		  comment => ['Maneuver Pointing'],
		  status => 1,
		  );

    push @{$output{criteria}}, "Confirms that the delta positions for each of the dark cal pointings",
                               "match the expected delta positions listed in the config file";

    my @point_order = @{$config->{template}{manvr}{point_order}{oflsid}};
    my %point_delta = %{$config->{template}{manvr}{point_delta_pos}};

    # grab just the maneuvers from the dot
    my @manvrs;
    for my $dot_entry (@{$dot}){
	if ($dot_entry->{cmd_identifier} =~ /ATS_MANVR/){
	    push @manvrs, $dot_entry;
	}
    }


    my @points;
    my $center;
    my $start_pt;

    my $start_check;
    my $as_slop = $config->{template}{manvr}{arcsec_slop};

    # Step through the dot maneuvers until we reach ones that match the template
    # check the maneuver quaternions on those to make sure the offsets are the same
    # as the template

    for my $manvr (@manvrs){

	my $dest_obsid = $manvr->{oflsid};

	if ($dest_obsid eq $point_order[0]){
	    $start_check = 1;
	}

	next unless ($start_check);

	# find the first matching backstop target quaternion after the maneuver command
	# time
	my $bs_match;
	for my $bs_entry (@{$bs}) {
	    next unless ($bs_entry->{time} > $manvr->{time});
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

	
	if ($dest_obsid =~ /DFC_0/){
	    $center = \%target;
	}

	push @points, \%target;
	
	last if ($dest_obsid eq $point_order[-1]);
       
    }

    # store the quaternion for the field center

    my $center_quat = $center->{quat};

    # step through the array of maneuvers and verify the match with the expected positions


    for my $i (0 .. scalar(@points)-1){
		
	my $point = $points[$i];
	if ( $point->{obsid} ne $point_order[$i]){
	    push @{$output{info}}, { text => sprintf("Obsid incorrect " . $point->{obsid} . " ne " . $point_order[$i]),
				     type => 'error' };
	    $output{status} = 0;
	    return \%output;
	}
	my $delta = ($point->{quat})->divide($center_quat);
	my $x = sprintf( "%5.2f", rad_to_arcsec($delta->{q}[1]*2));
	my $y = sprintf( "%5.2f", rad_to_arcsec($delta->{q}[2]*2));

	# Define where the point should really be using the relative positions in the config file
	my $temp_delta = ($point->{quat})->divide($center_quat);
	$temp_delta->{q}[1] = arcsec_to_rad($point_delta{$point_order[$i]}->{dx})/2;
	$temp_delta->{q}[2] = arcsec_to_rad($point_delta{$point_order[$i]}->{dy})/2;
	my $pred_point = $temp_delta->multiply($center_quat);
	
	if ( !quat_near($point->{quat}, $pred_point, $as_slop) ){
	    push @{$output{info}}, { text => sprintf("Delta position of " . $point->{obsid} . " relative to DFC of ($x, $y) is incorrect"),
				      type => 'error' };
	    $output{status} = 0;
	    return \%output;

	}
	
	push @{$output{info}}, { text => sprintf("Delta position of " . $point->{obsid} . " relative to DFC is (% 7.2f, % 7.2f) : Correct", $x, $y),
				 type => 'info' };
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

    my $tlr = shift;
    my $template = shift;
    my $config = shift;

    my %output = (
		  status => 1,
		  comment => ['Strict Timing Checks: Timing and Hex Commanding'],
		  );
    

    my @tlr_arr = @{ trim_tlr( $tlr, $config ) };
    my %command_dict = %{$config->{dict}{TLR}{comm_mnem}};
 #   my @tlr_arr = @{$tlr->{entries}};
    my @templ_arr = @{$template->{entries}};
    
    my @match_tlr_arr;
    
    push @{$output{criteria}}, "Steps through the TLR looking for entries which occur on or after the time of the",
    "first ACA hw commanding and which have command mnemonics that are in the config file list";
    my $string_cmd_dict = join(" ", (keys %command_dict));
    push @{$output{criteria}}, $string_cmd_dict;
    push @{$output{criteria}}, "Stops looking for new entries when n entries have been found, where n is the ",
    "number of entries in the template (one exception: AAC1CCSC commands will be added",
    "even if n has been reached)";

    for my $entry (@tlr_arr){
	next unless( defined $entry->rel_time() );
	next unless( $entry->rel_time() >= 0);
#	next unless( defined $command_dict{$entry->comm_mnem()} );
	next if ($entry->comm_mnem() ne 'AAC1CCSC' and scalar(@match_tlr_arr) >= scalar(@templ_arr));
#	print $entry->rel_time(), " ", $entry->comm_mnem(), "\n";
	push @match_tlr_arr, $entry;
    }


    push @{$output{criteria}}, "Checks each entry against template entry for matching timing, comm_mnem, and hex.";
    for my $i (0 .. scalar(@match_tlr_arr)-1){
	if ((defined $match_tlr_arr[$i]) and (defined $templ_arr[$i])){
	    my $match = $match_tlr_arr[$i]->matches_entry($templ_arr[$i]);
	    push @{$output{info}}, @{$match->{info}};
	    if ( $match->{status} ){
		next;
	    }
	    else{
		$output{status} = 0;	
		next;
	    }
	}
	else{
	    push @{$output{error}}, "Mismatch in number of entries" ;
	    $output{status} = 0;
	}
    }

    push @{$output{criteria}}, "Error if too many AAC1CCSC entries found.";
    if (scalar(@match_tlr_arr) > scalar(@templ_arr)){
	push @{$output{info}} , { text => "Too many AAC1CCSC hardware commands!", type => 'error'} ;
	$output{status} = 0;
    }
    push @{$output{criteria}}, "Error if too few dark cal commands found";
    if (scalar(@match_tlr_arr) < scalar(@templ_arr)){
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

    my @transponders = ( 'A','B', 'independent' );
    
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


package TLR;

use strict;
use warnings;
use IO::All;
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
	if (defined $entry->{comm_mnem}){
	    if (($entry->{comm_mnem} eq 'AAC1CCSC') and ( $entry->trace_id() =~ /ADC_R$replica/)) {
		push @aca_hw_cmds, $entry;
	    }
	}
    }

    $self->{begin_replica}->{$replica} = $aca_hw_cmds[0];

    die "No ACA commanding found.  Could not define reference entry"
	unless defined $self->{begin_replica}->{$replica};


    return $self->{begin_replica}->{$replica};

}

##***************************************************************************
sub end_replica{
##***************************************************************************
    my $self = shift;
    my $replica = shift;
    return $self->{end_replica}->{$replica} if (defined $self->{end_replica}->{$replica});
    
    my @aca_hw_cmds;
        
    for my $entry (@{$self->{entries}}){
	if (defined $entry->{comm_mnem}){
	    if (($entry->{comm_mnem} eq 'AAC1CCSC') and ( $entry->trace_id() =~ /ADC_R$replica/)) {
		push @aca_hw_cmds, $entry;
	    }
	}
    }

    $self->{end_replica}->{$replica} = $aca_hw_cmds[-1];

    die "No ACA commanding found.  Could not define reference entry"
	unless defined $self->{end_replica}->{$replica};


    return $self->{end_replica}->{$replica};

}

##***************************************************************************
sub last_aca_hw_cmd{
##***************************************************************************
    my $self = shift;
    return $self->{last_aca_hw_cmd} if (defined $self->{last_aca_hw_cmd});
   
    $self->{last_aca_hw_cmd} = $self->end_replica(4);
   

    die "No ACA commanding found.  Could not define reference entry"
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

    die "Error finding maneuver away from DFC. "
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
					 scalar => [ qw(
							comm_desc
							datestamp
							hex
							index
							trace_id
							previous_entry
							)
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

    my $step_rel_time_match = ($entry1->step_rel_time() == $entry2->step_rel_time());
    if ( !$step_rel_time_match ){
#	push @{$output{error}} ,sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc());
#	push @{$output{error}}, sprintf("step relative time mismatch: " . $entry1->step_rel_time() . " secs tlr, " . $entry2->step_rel_time() . " secs template ");
	push @{$output{info}}, { text =>  sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc()),
			 type => 'error'};

	push @{$output{info}}, { text => sprintf("step relative time mismatch: " . $entry1->step_rel_time() . " secs tlr, " . $entry2->step_rel_time() . " secs template "),
				 type => 'error'};
    }
    else{
	push @{$output{info}}, { text => sprintf("step relative time match : " . $entry1->step_rel_time() . " secs "),
				 type => 'info' };
    }

    my $rel_time_match = ($entry1->rel_time() == $entry2->rel_time());

    if ( !$rel_time_match ){
#	push @{$output{info}} ,sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc());
#	push @{$output{info}}, { text =>  sprintf($entry1->datestamp() . "\t" . $entry1->comm_mnem() . "\t" . $entry1->comm_desc()),
#			 type => 'error'};

	push @{$output{info}}, { text => sprintf( "Bad rel time from start: " . $entry1->rel_time() . " does not match expected " . $entry2->rel_time()),
				 type => 'info'};
    }
    else{
	push @{$output{info}}, { text => sprintf("Good rel time from start: " . $entry1->rel_time() . " secs "),
				 type => 'info'};
    }

    my $hex_equal = check_hex_equal($entry1->hex(), $entry2->hex());
    if (defined $hex_equal->{info}){
	push @{$output{info}}, @{$hex_equal->{info}};
    }
    if (($entry1->comm_mnem() eq $entry2->comm_mnem()) and
	($entry1->step_rel_time() == $entry2->step_rel_time()) and
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

sub step_rel_time{
    my $entry = shift;
    if (defined $entry->previous_entry()){
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

1;


