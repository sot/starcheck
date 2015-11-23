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
##*****************************************************************************************

use strict;
use List::Util qw(min sum);

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

require Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw();
our @EXPORT_OK = qw( make_figure_of_merit set_dynamic_mag_limits );
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

use Inline Python => q{

from chandra_aca.star_probs import acq_success_prob, prob_n_acq, mag_for_p_acq

def _acq_success_prob(date, t_ccd, mag, color, spoiler):
    out = acq_success_prob(date, t_ccd, mag, color, spoiler)
    return out.tolist()

def _prob_n_acq(acq_probs):
    n_acq_probs, n_or_fewer_probs = prob_n_acq(acq_probs)
    return n_acq_probs.tolist(), n_or_fewer_probs.tolist()
};

our $CUM_PROB_LIMIT = 10 ** -5.2;

sub make_figure_of_merit{
    my $c;
    my $self = shift;
    return unless ($c = $self->find_command("MP_STARCAT"));
    return unless (defined $self->{ccd_temp});

    my @probs;
    my %slot_probs;

    my $t_ccd = $self->{ccd_temp};
    my $date = $c->{date};

    foreach my $i (1..16) {
	if ($c->{"TYPE$i"} =~ /BOT|ACQ/) {
	    my $mag = $c->{"GS_MAG$i"};
            my @warnings = grep {/\[\s{0,1}$i\]/} (@{$self->{warn}}, @{$self->{yellow_warn}});
            my $spoiler = grep(/Search Spoiler/, @warnings) ? 1 : 0;
            my $color = $c->{"GS_BV$i"};
            my $star_prob = _acq_success_prob($date, $t_ccd, $mag, $color, $spoiler);
	    push @probs, $star_prob;
            $slot_probs{$c->{"IMNUM$i"}} = $star_prob;
            $c->{"P_SUCC$i"} = $star_prob;
	}
    }
    $self->{acq_probs} = \%slot_probs;

    # Calculate the probability of acquiring n stars
    my ($n_acq_probs, $n_or_fewer_probs) = _prob_n_acq(\@probs);

    $self->{figure_of_merit} = {expected => substr(sum(@probs), 0, 4),
                                cum_prob => [map { log($_) / log(10.0) } @{$n_or_fewer_probs}],
                                cum_prob_bad => ($n_or_fewer_probs->[2] > $CUM_PROB_LIMIT)
                                };
}


sub set_dynamic_mag_limits{
    my $c;
    my $self = shift;
    return unless ($c = $self->find_command("MP_STARCAT"));
    return unless (defined $self->{ccd_temp});

    my $date = $c->{date};
    my $t_ccd = $self->{ccd_temp};
    # Dynamic mag limits based on 75% and 50% chance of successful star acq
    $self->{mag_faint_yellow} = mag_for_p_acq(0.75, $date, $t_ccd);
    $self->{mag_faint_red} = mag_for_p_acq(0.5, $date, $t_ccd);
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
    # Minimum warm fraction seen in fit data
    my $warm_frac_min = 0.0412;
    # Co-efficients from 2013 State of the ACA polynomial fit
    my $scale = 10. ** (0.185 + 0.990 * $mag10 + -0.491 * $mag10 ** 2);
    my $offset = 10. ** (-1.489 + 0.888 * $mag10 + 0.280 * $mag10 ** 2);
    my $prob = 1.0 - ($offset + $scale * ($warm_frac - $warm_frac_min));
    my $max_star_prob = .985;
    # If the star is brighter than 8.5 or has a calculated probability
    # higher than the $max_star_prob, clip it at that value
    if (($mag < 8.5) or ($prob > $max_star_prob)){
        $prob = $max_star_prob;
    }

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
sub parse_bad_acq_warning {
##*****************************************************************************************
    my $warning = shift;

# Example of text to parse    
#>> WARNING: Bad Acquisition Star. [13]: 367673952 has  1 failed out of  3 attempts         

   $warning =~ /Bad Acquisition Star.+has\s*(\d{1,2})\sfailed out of\s*(\d{1,2})\sattempts.*/;
   	my ($failed, $total) = ($1, $2);
	return ($failed,$total);	
}	
    
