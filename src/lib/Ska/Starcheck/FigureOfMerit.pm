package Ska::Starcheck::FigureOfMerit;
##*****************************************************************************************
#figure_of_merit.pm - Generates a probabilistic figure of merit for star catalogs 
#                     within starcheck. 
#
#                     Outputs an array of:
#                            the log probability of bright star hold
#                            the expected number of acquisition stars identified
#
#                     Individual star probabilities are hard coded and will need
#                     regular updates.
#                            
#Last Updated - 3/20/03 Brett Unks
#
# Part of the starcheck cvs project
#
##*****************************************************************************************

use strict;
use List::Util qw(min);

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

require Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw();
our @EXPORT_OK = qw( make_figure_of_merit );
our %EXPORT_TAGS = ( all => \@EXPORT_OK );


our $CUM_PROB_LIMIT = -5.2;


sub make_figure_of_merit{
    my $c;
    my $self = shift;
    return unless ($c = $self->find_command("MP_STARCAT"));
    my @probs;
    foreach my $i (1..16) {
	my %acq = ();
	my $type = $c->{"TYPE$i"};
	if ($type =~ /BOT|ACQ/) {
	    $acq{index} = $i;
	    $acq{magnitude} = $c->{"GS_MAG$i"};
	    $acq{warnings} = [grep {/\[\s{0,1}$i\]/} (@{$self->{warn}}, @{$self->{yellow_warn}})];
            $acq{n100_warm_frac} = $self->{n100_warm_frac} || $self->{config}{n100_warm_frac_default};
	    #find the probability of acquiring a star
	    push @probs, star_prob(\%acq);
	}
    }
#    push @{$self->{yellow_warn}}, "Probs = " .  join(" ",  map{ sprintf("%.4f",$_) } @probs) . "\n";

    #calculate the probability of acquiring n stars
    my $n_slot = $#probs+1;
    my @nacq_probs = prob_nstars($n_slot, @probs);
    #calculate the probability of acquiring at least n stars
    $self->{figure_of_merit} = cum_prob($n_slot, @nacq_probs);



}
	        
##*****************************************************************************************
sub star_prob {
##*****************************************************************************************
    my ($acq) = @_;
    my @warnings = @{ $acq->{warnings} };
    my $mag = $acq->{magnitude};
    my $warm_frac = $acq->{n100_warm_frac};

    my $p_0p7color = .4294; #probability of acquiring a B-V = 0.700 star
    my $p_1p5color = 0.9452; #probability of acquiring a B-V = 1.500 star
    my $p_seaspo = .9241; #probability of acquiring a search spoiled star

    my $mag10 = $mag - 10.0;
    my $scale = 10. ** (0.185 + 0.990 * $mag10 + -0.491 * $mag10 ** 2);
    my $offset = 10. ** (-1.489 + 0.888 * $mag10 + 0.280 * $mag10 ** 2);
    my $prob = 1.0 - ($offset + $scale * $warm_frac);
    # Clip the individual star probability at $max_star_prob
    my $max_star_prob = .985;
    $prob = min($max_star_prob, $prob);

    foreach my $warning (@warnings) {
	if ($warning =~ /B-V = 0.700/) {
	    $prob *= $p_0p7color;
	}
        if ($warning =~ /B-V = 1.500/) {
            $prob *= $p_1p5color;
        }
	if ($warning =~ /Search Spoiler/) {
	    $prob *= $p_seaspo;
	}
	if ($warning =~ /Bad Acquisition Star/){
	    my ($failed, $total) = parse_bad_acq_warning($warning);
	    $prob = ($total - $failed) / $total;
            last;
	}
    }
    return $prob;
}

##*****************************************************************************************
sub prob_nstars {
##*****************************************************************************************
    my ($n_slot, @p) = @_;
    my @acq_prob = ();
    for my $i (0.. 2**$n_slot-1) {
	my $total_prob = 1.0;
        my $n_acq = 0;
	my $prob;
	for my $slot (0..$n_slot-1) { # cycle through slots 
	    if (($i & 2**$slot) >= 1) {
		$prob = $p[$slot]; 
		$n_acq = $n_acq + 1;
	    }
	    else {
		$prob = (1-$p[$slot]);
	    }
	    $total_prob = $total_prob * $prob;
	}
	$acq_prob[$n_acq] += $total_prob;
    }
    return @acq_prob;
}
    
##*****************************************************************************************
sub cum_prob {
##*****************************************************************************************
    my ($n_slot, @acq_prob) = @_;
    my @cum_prob = ();
    my @fom = ();
    my $exp = 0;
    for my $i (1.. $n_slot) {
	$exp += $i*$acq_prob[$i];
	for my $j ($i.. $n_slot) { $cum_prob[$i] += $acq_prob[$j] };
    }
    for my $i (1.. $n_slot) { $cum_prob[$i] = substr(log(1.0 - $cum_prob[$i])/log(10.0),0,6) };


    return {expected => substr($exp,0,4),
	    cum_prob => [ @cum_prob ],
	    cum_prob_bad => ($cum_prob[2] > $CUM_PROB_LIMIT)
	    };
}


##*****************************************************************************************
sub parse_bad_acq_warning {
##*****************************************************************************************
    my $warning = shift;

# Example of text to parse    
#>> WARNING: Bad Acquisition Star. [13]: 367673952 has  1 failed out of  3 attempts         

   $warning =~ /Bad Acquisition Star.+has\s*(\d{1,2})\sfailed out of\s*(\d{1,2})\sattempts.*/;
   	my ($failed, $total) = ($1, $2);
	return ($failed,$total);	
}	
    
