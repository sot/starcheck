#!/proj/axaf/bin/perl  -w

##*******************************************************************************
#
#  Starcheck.pl - Check for problems in command load star catalogs, and maintain
#                 the expected state of Chandra file
#
#  HISTORY  (See NOTES.release)
#     Jul 3, 2001:  Put under CVS
#
##*******************************************************************************

$version = "3.332";

# Set defaults and get command line options

use Getopt::Long;
use IO::File;
$par{dir}   = '.';
$par{plot}  = 1;
$par{html}  = 1;
$par{text}  = 1;
$par{chex}  = ($ENV{USER} eq 'aldcroft' or $ENV{USER} eq 'rac') ?
    undef : '/proj/sot/ska/ops/Chex/pred_state.rdb';

$log_fh = open_log_file("/proj/sot/ska/ops/Chex/starcheck.log");

GetOptions( \%par, 
	   'help', 
	   'dir=s',
	   'out=s',
	   'plot!',
	   'html!',
	   'text!',
	   'chex=s',
	   ) ||
    exit( 1 );

$STARCHECK   = $par{out} || 'starcheck';

usage( 1 )
    if $par{help};

# If non-trivial run, then load rest of libraries

use English;
use File::Basename;

use lib '/proj/rad1/ska/lib/perl5/local';
use Time::JulianDay;
use Time::DayOfYear;
use Time::Local;
use PoorTextFormat;
use TomUtil;

$dir  = dirname($PROGRAM_NAME);
require "$dir/starcheck_obsid.pl";
require "$dir/parse_cm_file.pl";

# Find backstop, guide star summary, OR, and maneuver files.  Only backstop is required

$backstop   = get_file("$par{dir}/*.backstop",'backstop', 'required');
$guide_summ = get_file("$par{dir}/mg*.sum",   'guide summary');
$or_file    = get_file("$par{dir}/*.or",      'OR');
$mm_file    = get_file("$par{dir}/mps/mm*.sum", 'maneuver');
$dot_file   = get_file("$par{dir}/md*:*.dot",     'DOT', 'required');
$mech_file  = get_file("$par{dir}/TEST_mechcheck.txt", 'mech check');
$soe_file   = get_file("$par{dir}/ms*.soe", 'SOE');
$bad_agasc_file = "/proj/sot/ska/ops/SFE/agasc.bad";

# If making plots, check for mp_get_agasc, and make a plot directory if required

if ($par{plot}) {
    die "Cannot find mp_get_agasc to make plots.  Are you in the CXCDS environment?\n"
	if (`which mp_get_agasc` =~ /no mp_get_agasc/);

    unless (-e $STARCHECK) {
	die "Couldn't make directory $STARCHECK\n" unless (mkdir $STARCHECK, 0777);
	print STDERR "Created plot directory $STARCHECK\n";
	print $log_fh "Created plot directory $STARCHECK\n" if ($log_fh);
    }
}


# First read the Backstop file, and split into components

$bogus_obsid = 1;
@bs = Parse_CM_File::backstop($backstop);
$i = 0;
foreach $bs (@bs) {
    ( $date[$i], $vcdu[$i], $cmd[$i], $params[$i], $time[$i] ) =
	( $bs->{date}, $bs->{vcdu}, $bs->{cmd}, $bs->{params}, $bs->{time} );
    $i++;
}

# Read DOT, which is used to figure the Obsid for each command

%dot = Parse_CM_File::DOT($dot_file) if ($dot_file);

# Read momentum management (maneuvers + SIM move) summary file 

%mm = Parse_CM_File::MM($mm_file) if ($mm_file);

# Read mech check file and parse

@mc  = Parse_CM_File::mechcheck($mech_file) if ($mech_file);

# Read mech check file and parse

%soe  = Parse_CM_File::SOE($soe_file) if ($soe_file);

# Read bad AGASC stars

warning("Could not open bad AGASC file $bad_agasc_file\n")
    unless (Obsid::set_bad_agasc($bad_agasc_file));

# Initialize list of "interesting" commands

set_dot_cmd();  

# Go through records and set the time of MP_TARGQUAT commands to
# the time of the subsequent cmd with COMMAND_SW | TLMSID= AOMANUVR

fix_targquat_time();

# Now go through records, pull out the interesting things, and assemble
# into structures based on obsid. 

for $i (0 .. $#cmd) {
    # Get obsid for this cmd by matching up with corresponding commands
    # from DOT.   Returns undef if it isn't "interesting"

    next unless ($obsid = get_obsid ($time[$i], $cmd[$i], $date[$i]));

    # If obsid hasn't been seen before, create obsid object

    unless ($obs{$obsid}) {
	push @obsid_id, $obsid;
	$obs{$obsid} = Obsid->new($obsid, $date[$i]);
    }

    # Add the command to the correct obs object

    $obs{$obsid}->add_command( { Parse_CM_File::parse_params($params[$i]),
				 vcdu => $vcdu[$i],
				 date => $date[$i],
				 time => $time[$i],
				 cmd  => $cmd[$i] } );
}

# After all commands have been added to each obsid, set some global
# object parameters based on commands

foreach $obsid (@obsid_id) {
    $obs{$obsid}->set_obsid(); # Commanded obsid
    $obs{$obsid}->set_target();
    $obs{$obsid}->set_star_catalog();
    $obs{$obsid}->set_maneuver(%mm) if ($mm_file);
    $obs{$obsid}->set_files($STARCHECK, $backstop, $guide_summ, $or_file, $mm_file, $dot_file);
}

# Read guide star summary file $guide_summ.
# This file is the OFLS summary of guide/acq/fid star catalogs for
# each obsid.  In addition to confirming numbers from Backstop, it
# has star id's and magnitudes.  The results are stored in the
# MP_STARCAT cmd, so this processing has to occur after set_star_catalog

read_guide_summary() if ($guide_summ);


# Do checking

foreach $obsid (@obsid_id) {
    if ($par{plot}) {
	$obs{$obsid}->get_agasc_stars();
	$obs{$obsid}->identify_stars();
	$obs{$obsid}->plot_stars("$STARCHECK/stars_$obs{$obsid}->{obsid}.gif") ;
    }
    $obs{$obsid}->check_star_catalog();
}

# Pull out backstop commands which are a SIM translation command

@sim_trans = ();
# Find SIMTSC continuity statement from mech check file
foreach $mc (@mc) {
    if ($mc->{var} eq 'simtsc_continuity') {
	push @sim_trans, { cmd  => 'SIMTRANS',
			   time => $mc->{time},
			   params=> "POS= $mc->{val}, SCS= 129, STEP= -999"};
	last;
    }
}
foreach (@bs) {
    push @sim_trans, $_ if ($_->{cmd} eq 'SIMTRANS');
}

# Read OR file and integrate into %obs, and check SIM positions if possible

%or = Parse_CM_File::OR($or_file) if ($or_file);

foreach $obsid (@obsid_id) {
    if (exists $or{$obsid}) {
	foreach (keys %{$or{$obsid}}) {
	    $obs{$obsid}->{$_} = $or{$obsid}{$_};
	}
	$obs{$obsid}->check_sim_position(@sim_trans);
    }
}

# Make sure there is only one star catalog per obsid

foreach $obsid (@obsid_id) {
    warning ("More than one star catalog assigned to Obsid $obsid\n")
	if ($obs{$obsid}->find_command('MP_STARCAT',2));
}

# Produce final report

$out = '\fixed_start ';
$date = `date`;
chomp $date;

$out .= "------------  Starcheck V$version    -----------------\n";
$out .= " Run on $date by $ENV{USER}\n\n";

if (@global_warn) {
    $out .= "------------  PROCESSING WARNINGS -----------------\n";
    $out .= "\\red_start\n";
    foreach (@global_warn) {
	$out .= $_;
    }
    $out .= "\\red_end\n";
}

# Summary of obsids

$out .= "------------  SUMMARY OF OBSIDS -----------------\n\n";
foreach $obsid (@obsid_id) {
    $out .= sprintf "\\link_target{#obsid$obs{$obsid}->{obsid},OBSID = %5s}", $obs{$obsid}->{obsid};
    $out .= sprintf " at $obs{$obsid}->{date}   ";
    if (@{$obs{$obsid}->{warn}}) {
	$out .= "\\red_start WARNINGS \\red_end";
    } elsif (@{$obs{$obsid}->{yellow_warn}}) {
	$out .= "\\yellow_start WARNINGS \\yellow_end";
    }
    $out .= "\n";
}
$out .= "\\page_break\n";

# For each obsid, print star report, errors, and generate star plot

foreach $obsid (@obsid_id) {
    $out .= $obs{$obsid}->print_report();
    $out .= "\\image $obs{$obsid}->{plot_file}\n" if ($obs{$obsid}->{plot_file});
    $out .= "\\page_break\n";
}

# Finish up and format it

$out .= '\fixed_end ';
$ptf = PoorTextFormat->new();

# Write make_stars file
$make_stars = "$STARCHECK/make_stars.txt";
open (OUT, "> $make_stars") or die "Couldn't open $make_stars for writing\n";
foreach $obsid (@obsid_id) {
    my $c = $obs{$obsid};
    printf OUT "../make_stars.pl -starcat starcat.dat.%05d", $c->{obsid};
    print OUT " -ra $c->{ra} -dec $c->{dec} -roll $c->{roll} ";
    print OUT "-sim_z $c->{SIM_OFFSET_Z} " if ($c->{SIM_OFFSET_Z});
    print OUT "-si $c->{SI} " if ($c->{SI});
    print OUT "\n";
}

# Write the HTML

if ($par{html}) {
    open (OUT, "> $STARCHECK.html") or die "Couldn't open $STARCHECK.html for writing\n";
    print OUT $ptf->ptf2any('html', $out);
    close OUT;
    print STDERR "Wrote HTML report to $STARCHECK.html\n";

    make_annotated_file('', 'starcat.dat.', ' -ra ', $make_stars);
    make_annotated_file('', ' ID=\s+', ', ', $backstop);
    make_annotated_file('PROCESSING SOCKET REQUESTS', '^\s+ID:\s+', '\S\S', $guide_summ);
    make_annotated_file('', '^ ID=', ', ', $or_file);
    make_annotated_file('', ' ID:\s+', '\S\S', $mm_file);
    make_annotated_file('', 'OBSID,ID=', ',', $dot_file);
}

# Write the TEXT

if ($par{text}) {
    open (OUT, "> $STARCHECK.txt") or die "Couldn't open $STARCHECK.txt for writing\n";
    print OUT $ptf->ptf2any('text', $out);
    close OUT;
    print STDERR "Wrote text report to $STARCHECK.txt\n";
}

# Update the Chandra expected state file, if desired and possible

if ($mech_file && $mm_file && $dot_file && $soe_file && $par{chex}) {
#   use lib '/proj/rad1/ska/dev/Backstop';
   use Chex;
   print STDERR "Updating Chandra expected state file\n";
   print $log_fh "Updating Chandra expected state file\n" if ($log_fh);
   $chex = new Chex $par{chex};
   $chex->update(mman         => \%mm,
		 mech_check   => \@mc, 
		 dot          => \%dot,
		 soe          => \%soe,
		 OR           => \%or,
		 backstop     => \@bs);
}

##***************************************************************************
sub make_annotated_file {
##***************************************************************************
# $backstop   = get_file("$par{dir}/*.backstop",'backstop', 'required');
# $guide_summ = get_file("$par{dir}/mg*.sum",   'guide summary');
# $or_file    = get_file("$par{dir}/*.or",      'OR');
# $mm_file    = get_file("$par{dir}/*/mm*.sum", 'maneuver');
# $dot_file   = get_file("$par{dir}/*.dot",     'DOT', 'required');

    ($start_rexp, $id_pre, $id_post, $file_in) = @_;
    open(FILE, $file_in) or return;
    my @lines = <FILE>;
    close FILE;

    my $obsid;
    my $start = $start_rexp ? 1 : 0;

    foreach (@lines) {
	$start = 0 if ($start && /$start_rexp/);
	next if ($start);
	if (/$id_pre(\S+)$id_post/) {
	    my $pre = "$PREMATCH\\target{";
	    my $post = "}\\red_start $MATCH\\red_end $POSTMATCH";
	    ($obsid = $1) =~ s/^0+//;
	    $_ = "$pre$obsid$post";
	}
    }

    $file_out = "$STARCHECK/" . basename($file_in) . ".html";

    open(FILE, "> $file_out") or die "Couldn't open $file_out for writing\n";
    print FILE $ptf->ptf2any('html', "\\fixed_start \n" . join('',@lines));
    close FILE;
}

##***************************************************************************
sub fix_targquat_time {
##***************************************************************************
# Go through records and set the time of MP_TARGQUAT commands to
# the time of the subsequent cmd with COMMAND_SW | TLMSID= AOMANUVR
    for $i (reverse (0 .. $#cmd)) {
	if ($cmd[$i] eq 'COMMAND_SW' and $params[$i] =~ /AOMANUVR/) {
	    $manv_time = $time[$i];
	}
	if ($cmd[$i] eq 'MP_TARGQUAT') {
	    if ($manv_time) {
		$time[$i] = $manv_time;
		undef $manv_time;	# Make sure that each TARGQUAT gets a unique AOMANUVR time
	    } else {
		warning ("Found MP_TARGQUAT at $date[$i] without corresponding AOMANUVR\n");
	    }
	}
    }
}


##***************************************************************************
sub set_dot_cmd {
##***************************************************************************
    %dot_cmd    = (ATS_MANVR  =>  'MP_TARGQUAT',
#		   SIMPKT_SIM  => 'SIMFOCUS'  ,
		   ATS_DTHR    => 'MP_DITHER' ,
		   ATS_ACQ     => 'MP_STARCAT',
		   ATS_OBSID   => 'MP_OBSID',
		   );

    %dot_time_offset = (ATS_DTHR  => -120.0,
			ATS_OBSID => +180.0,
			);

    %dot_tolerance = (ATS_DTHR  => 200.0,
			);
}

##***************************************************************************
sub get_obsid {
##***************************************************************************
    my $TIME_TOLERANCE = 20;	# seconds
    my $time = shift;
    my $cmd = shift;
    my $date = shift;
    my ($obsid, $dt, $tolerance, $cmd_identifier);

    # Return undef if the command is not one of the 'interesting' DOT commands

    return () unless grep /$cmd/, values %dot_cmd;

    # Match (by time) the input command to corresponding command in the DOT

    foreach $obsid_index (keys %dot) {
	next unless ($dot_cmd{ $dot{$obsid_index}{cmd_identifier}});
	$cmd_identifier = $dot{$obsid_index}{cmd_identifier};

	$dt        = $dot_time_offset{$cmd_identifier} || 0.0;
	$tolerance = $dot_tolerance{$cmd_identifier}   || $TIME_TOLERANCE ;

	if ($dot_cmd{$cmd_identifier} eq $cmd
	    && abs($dot{$obsid_index}{time} + $dt - $time) < $tolerance) {
	    return $1 if ($obsid_index =~ /\S0*(.+)\d\d\d\d/);
	    die "Couldn't parse obsid_index = '$obsid_index' in get_obsid()\n";
	}
    }

    warning("Could not find an match in DOT for $cmd at $date\n");

    # Couldn't match input command to DOT.  For TARGQUAT or STARCAT, force
    # processing by making a bogus obsid 

    if ($cmd =~ /MP_(TARGQUAT|STARCAT)/) {
	$obsid = "NONE$bogus_obsid" ;
	warning("Creating bogus obsid $obsid\n") unless ($obs{$obsid});
	$bogus_obsid++ if ($cmd eq 'MP_STARCAT');
    }
	

    return ($obsid);
}    


##***************************************************************************
sub read_guide_summary {
##***************************************************************************

# **** PROCESSING REQUEST ****
#      ID:         0008700
#      TARGET RA:  326.184708 DEG.
#      TARGET DEC: 38.300091 DEG.
# 
# ROLL (DEG):  85.6468               FOM (ARCSEC^2):  0.597854E-03
# 
# STARS/FIDUCIAL LIGHTS                           AC COORDINATES (RAD)
# TYPE      ID       RA (DEG)  DEC (DEG)  MAG     Y-ANGLE       Z-ANGLE
# **************************************************************************
# FID             8  --------  --------    7.083   0.41300E-02  -0.58742E-02
# FID             9  --------  --------    7.116  -0.57631E-02   0.53086E-02
# FID            10  --------  --------    7.081   0.62139E-02   0.52960E-02
# BOT     417339000  325.7338   37.9049    7.595  -0.73335E-02   0.56697E-02
# BOT     417348280  327.0051   38.9013    8.814   0.11358E-01  -0.10312E-01
# BOT     417343224  325.3579   37.7705    9.047  -0.10033E-01   0.10677E-01
# BOT     417334592  326.0789   38.8836    9.645   0.10047E-01   0.22062E-02
# BOT     417347416  326.6022   38.0951    9.671  -0.31185E-02  -0.59885E-02

    return unless ($guide_summ);

    open (GUIDE_SUMM, $guide_summ) || die "Couldn't open guide star summary file $guide_summ for reading\n";

    while (<GUIDE_SUMM>) {
	# Look for an obsid, ra, dec, or roll
	if (/\s+ID:\s+(.+)00/) {
	    ($obsid = $1) =~ s/^0*//;
	    $first = 0;
	}
	$ra = $1 if (/\s+TARGET RA:\s*([^ ]+) DEG/);
	$dec = $1 if (/\s+TARGET DEC:\s*([^ ]+) DEG/);
	$roll = $1 if (/ROLL \(DEG\):\s*([^ ]+) /);

	# Look for a star catalog entry, which must have been preceeded by obsid, ra, dec, and roll
	if (/^(FID|ACQ|GUI|BOT)/) {
	    if (exists $obs{$obsid}) {  # Make sure there is a corresponding obsid object from backstop
		$obs{$obsid}->add_guide_summ($ra, $dec, $roll, $_);
	    } else {
		if ($first++ == 0) {
		    warning ("Obsid $obsid is in guide star summary but not backstop\n")
			unless ($obsid =~ /[^\d]/);
		}
	    }
	}
    }
    close GUIDE_SUMM;
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
    print $log_fh "Using $name file $files[0]\n" if ($log_fh);
    return $files[0];
}

##***************************************************************************
sub insert_bogus_obsid {
##***************************************************************************
    @date = (@date[0..$i-1], $date[$i_last_starcat], @date[$i..$#date]);
    @vcdu = (@vcdu[0..$i-1], $vcdu[$i_last_starcat]+4, @vcdu[$i..$#vcdu]);
    @cmd = (@cmd[0..$i-1], 'MP_OBSID', @cmd[$i..$#cmd]);
    @params = (@params[0..$i-1], "ID= NONE$bogus_obsid", @params[$i..$#params]);
    warning ("A star catalog does not have an associated obsid, " 
	. "using bogus obsid NONE$bogus_obsid\n");
    $bogus_obsid++;
}
    

##***************************************************************************
sub warning {
##***************************************************************************
    my $text = shift;
    push @global_warn, $text;
    print STDERR $text;
}

##***************************************************************************
sub open_log_file {
##***************************************************************************
    my $log_file = shift;
    my $log_fh;

    if ($log_fh = new IO::File ">> $log_file") {
	my $date = `date`;
	chomp $date;
	print $log_fh "\nStarcheck run at $date by $ENV{USER}\n";
	print $log_fh "DIR: $ENV{PWD}\n";
	print $log_fh "CMD: $0 @ARGV\n\n";
    } else {
	warn "Couldn't open $log_file for appending\n";
    }
    return $log_fh;
}

##***************************************************************************
sub usage
##***************************************************************************
{
  my ( $exit ) = @_;

  local $^W = 0;
  require Pod::Text;
  Pod::Text::pod2text( '-75', $0 );
  exit($exit) if ($exit);
}

=pod

=head1 NAME

starcheck.pl - Check for problems in command load star catalogs 

=head1 SYNOPSIS

B<starcheck.pl>  [I<options>]

=head1 OPTIONS

=over 4

=item B<-help>

Print this help information.

=item B<-dir <dir>>

Look for backstop and (optionally) guide star summary files in <dir>.
Default is '.'.

=item B<-out <out>>

Output reports will be <out>.html, <out>.txt.  Star plots will be 
<out>/stars_<obsid>.gif.  The default is <out> = 'STARCHECK'.

=item B<-[no]plot>

Enable (or disable) generation of star/fid plots.  These plots require
the tool mp_get_agasc and the AGASC catalog online.  Default is plotting 
enabled.

=item B<-[no]html>

Enable (or disable) generation of report in HTML format.  Default is HTML enabled.

=item B<-[no]text>

Enable (or disable) generation of report in TEXT format.  Default is TEXT enabled.

=back

=head1 DESCRIPTION

B<Starcheck.pl> checks for problems in ACA star catalogs produced by the 
OFLS, relying primarily on the output of Backstop.  In addition,
if a guide star summary file is available, that information is
used to determine star/fid IDs and magnitudes.  A report summarizing
the star catalogs is generated in HTML and/or plain text formats.

The output reports are named <out>.html, <out>.txt, and star plots are
named <out>/stars_<obsid>.gif.  If not specified on the command line,
<out> is 'STARCHECK'.

Starcheck.pl looks in <dir> for a single Backstop file with the name '*.backstop'.
Zero matches or multiple matches of this name results in a fatal error.
The guide star summary file is assumed to be named 'mg*.sum'.  If no file 
is found, a warning is produced but processing continues.  Multiple matches
results in a fatal error, however.


=head1 AUTHOR

Tom Aldcroft ( taldcroft@cfa.harvard.edu )

=cut

