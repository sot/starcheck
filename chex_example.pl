#!/proj/axaf/bin/perl -w

use Chex;

$date = shift @ARGV || '2000:140:10:12:34.0';

# Create the Chandra Expected state object
$chex = Chex->new;

# You could specify a predicted state file which is different
# from the default by using:
#   $chex = Chex->new('/home/aldcroft/ska/dev/temp_state.rdb');

# Get the predicted state at $date
print "# Getting predicted state at $date\n";
%pred_state = $chex->get($date);

# Find the state variables contained in the predicted state
@state_vars = keys %pred_state;
print "\n# State variables are: @state_vars\n";

# Print the state by looping through each state variable
print "\n# Printing state manually\n";
foreach $sv (@state_vars) {
    # Get the array of values for the state variable.  It is possible
    # that a state has multiple values in order to account for small
    # uncertainties in the timing of spacecraft events

    @state_values = @{$pred_state{$sv}};

    printf "%-10s : ", $sv;
    foreach (@state_values) {
	printf " %-12s", $_;
    }
    print "\n";
}

# Print the state the easy way
print "\n# Printing state using chex->print()\n";
$chex->print();

# Print the state at a new time.
print "\n# Printing state for a different date\n";
$chex->print('2000:141:01:02:03.4');

# Print the state at a new time.
print "\n# Printing state for a different date\n";
$chex->print('2000:120:01:02:03.4');

# Any 'date' argument can also be a time in seconds (where the time is
# expressed in the CXCDS convention ala TSTART, TSTOP, etc)
print "\n# Printing state for a different time\n";
$chex->print(75151787.5);

# Now check if the current values match the predicted

print "\n# Checking for a state match with observed\n";
$obs_simtsc = -99162;
$match = $chex->match(var => 'simtsc', # State variable name
		      val => $obs_simtsc,  # Observed state value
		      tol => 5,	       # OPTIONAL match tolerance (5 steps in this case)
		      date=> $date,    # date is optional if a 'get' or 'print' was done 
		      );
print "\n# Found match=$match : SIMTSC=$obs_simtsc versus predicted @{$chex->{chex}{simtsc}}\n";
