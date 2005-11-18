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
##*****************************************************************************************
@EXPORT = qw(make_figure_of_merit);

our $CUM_PROB_LIMIT = -5.2;

sub make_figure_of_merit {
    my $self = shift;
    return unless ($c = find_command($self, "MP_STARCAT"));
    my @probs;
    foreach my $i (1..16) {
	my %acq = ();
	my $type = $c->{"TYPE$i"};
	if ($type =~ /BOT|ACQ/) {
	    $acq->{index} = $i;
	    $acq->{magnitude} = $c->{"GS_MAG$i"};
	    $acq->{warnings} = [grep {/\[\s{0,1}$i\]/} (@{$self->{warn}}, @{$self->{yellow_warn}})];
	    #find the probability of acquiring a star
	    push @probs, star_prob($acq);
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

    my $prob; #initialize the probability   
 
    my $p_normal = .9846; #probability of acquiring any star
    my $p_marsta = .4846; #probability of acquiring a B-V = 0.700 star
    my $p_seaspo = .9241; #probability of acquiring a search spoiled star
    my @c_mag = qw(-1008.50 243.75 -13.41); #polynomial coefficients for magnitudes

    my $j = 0;

    $prob = $p_normal;

    if ($mag > 9.5) {
	my $coeff = ($c_mag[0]+$c_mag[1]*($mag)+$c_mag[2]*($mag**2))/100.0;
	$coeff = 0.0 if ($coeff < 0.0);
        $prob *= $coeff;
    }

    
    foreach $warning (@warnings) {
	if ($warning =~ /B-V = 0.700/) {
	    $prob *= $p_marsta;
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
    
