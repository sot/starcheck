#!/proj/axaf/bin/perl -w

use Chex;

$t1998 = 883612800;

$date = shift @ARGV || time - $t1998;

# Create the Chandra Expected state object
$chex = Chex->new;

# Get the predicted state at $date
$chex->print($date);


