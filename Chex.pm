##*******************************************************************************
#
#  Chex.pm - Package for predicting the expected state of Chandra
#
#  HISTORY (See NOTES.release)
#     Sep 15, 2000 -  Created (TLA)
#
##*******************************************************************************
package Chex;

use RDB;
use English;
use lib '/proj/rad1/ska/lib/perl5/local';
use TomUtil;

@state_var   = qw(date obsid simtsc simfa gratings ra dec roll);
@state_format= qw(14S   5N    6N      5N  5S       10S 9S  9S);
@state_tol   = qw( 1    300    360   360  300      300 300 300);
$UNDEF = "undef";

%match_tol = (obsid  => 0.001,
	      simtsc => 5,
	      simfa  => 5
	      );

@ISA = qw(Exporter);

#print "Using local Chex.pm\n";
$loud = 0;
$chex_file = '/proj/gads6/ops/Chex/pred_state.rdb';
#$chex_file = '/home/aldcroft/ska/dev/Backstop/temp_state.rdb';

1;

####################################################################################		     	    
sub new {
####################################################################################		     	    
    my $classname = shift;
    my $self = {};
    bless ($self);
    $self->{chex_file} = @_ ? shift : $chex_file;
    $self->{time} = -1.0;
    @states = ();

    return $self;
}
####################################################################################		     	    
sub print {
####################################################################################		     	    
    my $self = shift;
    
    # Optional second argument is a new date or time
    get($self, shift) if (@_);

    %pred_state = %{$self->{chex}};
    foreach $sv (@state_var) {
	next if ($sv eq 'date');
	printf "%-10s : ", $sv;
	foreach (@{$pred_state{$sv}}) {
	    printf " %-12s", $_;
	}
	print "\n";
    }
}

####################################################################################		     	    
sub match {
####################################################################################		     	    
    my $self = shift;
    my %par = @_;

    my $sv = $par{var} || die "Chex::match: var parameter is undefined\n";
    my $obs_val  = $par{val} || die "Chex::match:  val parameter is undefined\n";
    $par{tol} = $par{tol} || $match_tol{$sv};

    get($self, $par{date}) if ($par{date});
    get($self, $par{time}) if ($par{time});

    my %chex = %{$self->{chex}};
    my @pred_val = @{$chex{$sv}};

    foreach $pred_val (@pred_val) {
	return 2 if ($pred_val eq 'undef');
	if ($par{tol} eq 'MATCH') {
	    return 1 if ($pred_val eq $obs_val);
	} else {
	    return 1 if (abs($pred_val - $obs_val) <= $par{tol});
	    if ($par{var} eq 'ra' || $par{var} eq 'roll') {
		return 1 if (abs($pred_val - $obs_val) >= 360 - $par{tol});
	    }
	}
    }

    return 0;
}

####################################################################################		     	    
sub get {
####################################################################################		     	    
    my $self = shift;
    my $datetime = shift;

    # If argument looks like a date, then convert it
    $time = ($datetime =~ /\d\d\d\d:\d/) ? date2time($datetime) : $datetime;

    # Check if we already have the predicted state
    return %{$self->{chex}} if ($time == $self->{time});  

    undef @match;
    
    # If chex_file was already read, force a re-read if @states in memory
    # do not contain match time

    undef @states if (@states && $states[0]->{time} >= $time);
	
    # Read in chex_file up to the point just before match time.  Chex file is
    # written in reverse chronological order

    unless (@states) {
	my $rdb = new RDB $self->{chex_file}
	    or die "Couldn't open input Chandra predicted state $self->{chex_file}\n";
	while ($rdb->read(\%state)) {
	    $state_time = date2time($state{date});
	    unshift @states, { %state,
			       time => $state_time };
	    last if ($state_time < $time);
	}
    }

    # Find first state with time greater than match time
    $i0 = 0;
    $i1 = $#states;
    while ($i1 - $i0 > 4) {
	$i = sprintf "%d", ($i0+$i1)/2;
	if ($states[$i]->{time} > $time) {  $i1 = $i; }
	else                             {  $i0 = $i; }
    }
	    
    for ($i0 .. $i1) {
	$i = $_;
	last if ($states[$i]->{time} > $time);
    }

    if ($i == 0 or $i == $#states+1) {
	print STDERR "Chandra predicted state file '$self->{chex_file}' doesn't contain search time $time (" .
	    time2date($time) . ")\n";
	return;
    }

    
    # Start accumulating matches within time tolerance for each state variable.
    # The last record with time <= search time is automatically a match for all
    # state variables

    foreach (@state_var) {
	undef %{$match{$_}};
	$match{$_}{$states[$i-1]->{$_}} = 1;
    }

    # Search forward from the current record, accumulating only matches for
    # state variables within the time tolerance for that variable.
    # Quit when no variables match
    
    $done = 0;
    $i_match = $i-1;
    while ($i <= $#states && ! $done) {
	$done = 1;
	foreach $i_sv (0 .. $#state_var) {
	    $sv = $state_var[$i_sv];
	    if ($time + $state_tol[$i_sv] > $states[$i]->{time}) {
		$match{$sv}{$states[$i]->{$sv}} = 1;
		$done = 0;
	    }
	}
	$i++;
    }
	
    # Search backwards from the current record, accumulating only matches for
    # state variables within the time tolerance for that variable.
    # Quit when no variables match
    
    $i = $i_match-1;
    $done = 0;
    while ($i >= 0 && ! $done) {
	$done = 1;
	foreach $i_sv (0 .. $#state_var) {
	    $sv = $state_var[$i_sv];
	    if ($time - $state_tol[$i_sv] < $states[$i+1]->{time}) {
		$match{$sv}{$states[$i]->{$sv}} = 1;
		$done = 0;
	    }
	}
	$i--;
    }


    $LIST_SEPARATOR = ", ";
    foreach $sv (@state_var) {
	$m{$sv} = [ keys %{$match{$sv}} ];
    }
    $LIST_SEPARATOR = " ";

    
    $self->{time} = $time;
    %{$self->{chex}} = %m;
    return %m;
}
    

####################################################################################		     	    
sub update {
####################################################################################		     	    
    my $self = shift;

    %par = (continuity => 0,
	    loud       => 0,
	    @_
	    );

    # Take pointer to mech_check array, or else parse mech_check_file
    $p_mc = $par{mech_check};
    $p_dot = $par{dot};
    $p_mm = $par{mman};
    $p_or = $par{OR};
    $p_soe = $par{soe};
    $p_bs  = $par{backstop};

# Put the events from the mech check file into the master event list

    foreach $mc (@{$p_mc}) {
	next if ($mc->{var} =~ /continuity/);
	push @evt, { var  => $mc->{var},
		     val  => $UNDEF,
		     time => $mc->{time} } if ($mc->{dur} > 0.0);
	
	push @evt, { var  => $mc->{var},
		     val  => $mc->{val},
		     time => $mc->{time} + $mc->{dur} };
    }
    
# Put events from MMAN file into master event list

    %mm_format = ('ra' => '%10.6f',
		  'dec' => '%9.5f',
		  'roll' => '%9.3f');

    foreach $mm (values %{$p_mm}) {
	foreach $q (qw(ra dec roll)) {
	    push @evt, { var  => $q,
			 val  => $UNDEF,
			 time => $mm->{tstart} };
	    push @evt, { var  => $q,
			 val  => sprintf($mm_format{$q}, $mm->{$q}),
			 time => $mm->{tstop} };
	}
    }

# Put events from backstop into master event list

    foreach $bs (@{$p_bs}) {
	if ($bs->{cmd} eq "MP_OBSID") {
	    my %param = parse_params($bs->{params});
	    $param{ID} =~ s/ //g;
	    push @evt, { var  => "obsid",
			 val  => $param{ID},
			 time => $bs->{time} };
	}
    }
	    
# Put events from OR list into master event list

    foreach $obsid (keys %{$p_or}) {
	if (exists $p_soe->{$obsid}) {
	    push @evt, { var  => "gratings",
			 val  => $p_or->{$obsid}{GRATING},
			 time => date2time($p_soe->{$obsid}{odb_obs_start_time}) };
	    push @evt, { var  => "gratings",
			 val  => $UNDEF,
			 time => date2time($p_soe->{$obsid}{odb_obs_end_time}) };
	}
    }

# Put events from DOT file into master event list

# Sort event list by time

    @order = sort { $evt[$a]->{time} <=> $evt[$b]->{time} } (0 .. $#evt);
    @evt = @evt[@order];
    $evt_tstart = $evt[0]->{time};
    $evt_tstop  = $evt[-1]->{time};

# Initialize Chandra expected state

    foreach $var (@state_var) {
	$state{$var} = "";
    }

# Read input events

    print "Reading existing state file..\n" if ($loud);
    $in_rdb = new RDB $self->{chex_file}
        or die "Couldn't open input Chandra predicted state '$self->{chex_file}'\n";
    while ($in_rdb->read(\%in_state)) {
	push @in_states, { %in_state };
    }
    foreach $in_state_p (reverse @in_states) {
	foreach $var (@state_var) {
	    next if ($var eq 'date');
	    if ($state{$var} ne $in_state_p->{$var}) { # Change in state -> an event
		$state{$var} = $in_state_p->{$var};
		# But only add events that are outside the time window defined by current processing
		$state_time = date2time($in_state_p->{date});
		if ($state_time lt $evt_tstart || $state_time gt $evt_tstop) {
		    push @evt, { var  => $var,
				 val  => $in_state_p->{$var},
				 time => $state_time };
		}
	    }
	}
    }

# Sort event list by time again

    print "Sorting events by time\n" if ($loud);
    @order = sort { $evt[$a]->{time} <=> $evt[$b]->{time} } (0 .. $#evt);
    @evt = @evt[@order];

# Mark events that are at a common time

    print "Marking common time events\n" if ($loud);
    for $i (0 .. $#evt-1) {
	$evt[$i]->{common_time} = 1 if ($evt[$i]->{time} == $evt[$i+1]->{time});
    }


# Output complete history of Chandra Expected state
    $tmp_out_file = "XXXQQQ_chex_tmp.rdb";
    $out_rdb = new RDB;
    $out_rdb->open($tmp_out_file, ">") or die "Couldn't open $tmp_out_file\n";
    $out_rdb->init($in_rdb);
    @new_states = ();

    print "Collecting new events..\n" if ($loud);
    # First collect all the new states in reverse order
    foreach $evt (@evt) {
	$state{$evt->{var}} = $evt->{val};
	next if ($evt->{common_time}); # Don't output multiple transitions at common time

	$state{date} = time2date($evt->{time});
#	unshift @new_states, { %state };# collect new states in reverse order
	push @new_states, { %state };# collect new states in reverse order
    }

    # Then actually write out file
    print "Writing file..\n" if ($loud);
    foreach $state (reverse @new_states) {
	$out_rdb->write($state) or die "Problem writing to temporary output file\n";
    }

    system("cp $self->{chex_file} $self->{chex_file}~");
    undef $out_rdb;		# Force closure of file
    system("cp $tmp_out_file $self->{chex_file}");
    unlink $tmp_out_file;
    print STDERR "Wrote predicted state of Chandra to $self->{chex_file}\n";
}

##***************************************************************************
sub get_file {
##***************************************************************************
    my $glob = shift;
    my $name = shift;
    my $required = shift;
    my $warning = ($required ? "ERROR" : "WARNING");

    @files = glob($glob);
    if (@files != 1) {
	print STDERR ((@files == 0) ?
		      "$warning: No $name file matching $glob\n"
		      : "$warning: Found more than one file matching $glob, using none\n");
	die "\n" if ($required);
	return undef;
    } 

    print STDERR "Using $name file $files[0]\n";
    return $files[0];
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

