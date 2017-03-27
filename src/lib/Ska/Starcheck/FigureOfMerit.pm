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

def _acq_success_prob(date, t_ccd, mag, color, spoiler, halfwidth):
    out = acq_success_prob(date, float(t_ccd), float(mag), float(color), spoiler, int(halfwidth))
    return out.tolist()

def _prob_n_acq(acq_probs):
    n_acq_probs, n_or_fewer_probs = prob_n_acq(acq_probs)
    return n_acq_probs.tolist(), n_or_fewer_probs.tolist()
};

our $CUM_PROB_LIMIT = 8e-3;

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
            my $spoiler = grep(/Search spoiler/i, @warnings) ? 1 : 0;
            my $color = $c->{"GS_BV$i"};
            my $hw = $c->{"HALFW$i"};
            my $star_prob = _acq_success_prob($date, $t_ccd, $mag, $color, $spoiler, $hw);
            if (grep(/Bad Acquisition Star/i, @warnings)){
                my @w = grep(/Bad Acquisition Star/i, @warnings);
                my ($failed, $total) = parse_bad_acq_warning($w[0]);
                if ($star_prob > (($total - $failed) / $total)){
                    $star_prob = ($total - $failed) / $total;
                }
            }
	    push @probs, $star_prob;
            $slot_probs{$c->{"IMNUM$i"}} = $star_prob;
            $c->{"P_ACQ$i"} = $star_prob;
	}
    }
    $self->{acq_probs} = \%slot_probs;

    # Calculate the probability of acquiring n stars
    my ($n_acq_probs, $n_or_fewer_probs) = _prob_n_acq(\@probs);

    $self->{figure_of_merit} = {expected => substr(sum(@probs), 0, 4),
                                cum_prob => [map { log($_) / log(10.0) } @{$n_or_fewer_probs}],
                                cum_prob_bad => ($n_or_fewer_probs->[2] > $CUM_PROB_LIMIT)
                                };
    if ($n_or_fewer_probs->[2] > $CUM_PROB_LIMIT){
        push @{$self->{warn}}, ">> WARNING: Probability of 2 or fewer stars > $CUM_PROB_LIMIT\n";
    }

}


sub set_dynamic_mag_limits{
    my $c;
    my $self = shift;
    return unless ($c = $self->find_command("MP_STARCAT"));

    my $date = $c->{date};
    my $t_ccd = $self->{ccd_temp};
    # Dynamic mag limits based on 75% and 50% chance of successful star acq
    # Maximum limits of 10.3 and 10.6
    $self->{mag_faint_yellow} = min(10.3, mag_for_p_acq(0.75, $date, $t_ccd));
    $self->{mag_faint_red} = min(10.6, mag_for_p_acq(0.5, $date, $t_ccd));
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
    
