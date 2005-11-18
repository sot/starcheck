#! /usr/bin/env /proj/sot/ska/bin/perlska

##*******************************************************************************
#
#  Starcheck.pl - Check for problems in command load star catalogs, and maintain
#                 the expected state of Chandra file
#
##*******************************************************************************

my $VERSION = '$Id$';  # '
my ($version) = ($VERSION =~ /starcheck.pl,v\s+(\S+)/);

# Set defaults and get command line options

use strict;
use warnings;
use Getopt::Long;
use IO::File;

use English;
use File::Basename;

use Time::JulianDay;
use Time::DayOfYear;
use Time::Local;
use PoorTextFormat;
use Chex;

#use lib '/proj/axaf/simul/lib/perl';
use GrabEnv qw( grabenv );

# Set some global vars with directory locations
my $SKA = $ENV{SKA} || '/proj/sot/ska';
my $Starcheck_Data = "$ENV{SKA_DATA}/starcheck" || "$SKA/data/starcheck";
my $Starcheck_Share = "$ENV{SKA_SHARE}/starcheck" || "$SKA/share/starcheck";

my %par = (dir  => '.',
	plot => 1,
	html => 1,
	text => 1,
	agasc => '1p6',
	chex => undef);

my $log_fh = open_log_file("$SKA/ops/Chex/starcheck.log");

GetOptions( \%par, 
	   'help', 
	   'dir=s',
	   'out=s',
	   'plot!',
	   'html!',
	   'text!',
	   'chex=s',
	   'agasc=s',
	   ) ||
    exit( 1 );

my $STARCHECK   = $par{out} || 'starcheck';

usage( 1 )
    if $par{help};

# If non-trivial run, then load rest of routines
require "${Starcheck_Share}/starcheck_obsid.pl";
require "${Starcheck_Share}/parse_cm_file.pl";

# Find backstop, guide star summary, OR, and maneuver files.  Only backstop is required

my %input_files = ();

my $backstop   = get_file("$par{dir}/*.backstop",'backstop', 'required');
my $guide_summ = get_file("$par{dir}/mps/mg*.sum",   'guide summary');
my $or_file    = get_file("$par{dir}/mps/or/*.or",      'OR');
my $mm_file    = get_file("$par{dir}/mps/mm*.sum", 'maneuver');
my $dot_file   = get_file("$par{dir}/mps/md*.dot",     'DOT', 'required');
my $mech_file  = get_file("$par{dir}/output/TEST_mechcheck.txt", 'mech check');
my $soe_file   = get_file("$par{dir}/mps/soe/ms*.soe", 'SOE');
my $fidsel_file= get_file("$par{dir}/History/FIDSEL.txt*",'fidsel');    
my $dither_file= get_file("$par{dir}/History/DITHER.txt*",'dither');    
my $odb_file   = get_file("$Starcheck_Data/fid_CHARACTERIS_JUL01", 'odb', 'required');
my $manerr_file= get_file("$par{dir}/output/*_ManErr.txt",'manerr');    

my $bad_agasc_file = "$Starcheck_Data/agasc.bad";
my $ACA_bad_pixel_file = "$Starcheck_Data/ACABadPixels";
my $bad_acqs_file = $ENV{'SKA_DATA'}."/acq_stats/bad_acq_stars.rdb";

my ($mp_agasc_version, $ascds_version, $ascds_version_name);

# If making plots, check for mp_get_agasc, and make a plot directory if required

if ($par{plot}) {
    if (`which mp_get_agasc` =~ /no mp_get_agasc/) {
	%ENV = grabenv("tcsh", "source /home/ascds/.ascrc -r release");
	if (`which mp_get_agasc` =~ /no mp_get_agasc/) {
	    die "Cannot find mp_get_agasc to make plots.  Are you in the CXCDS environment?\n";
	}
    }
    
    # If agasc parameter is defined (and looks reasonable) then force that version of AGASC.
    if (defined $par{agasc} and $par{agasc} =~ /\dp\d/) {
	foreach (keys %ENV) {
	    next unless /AGASC/;
	    $ENV{$_} =~ s/agasc(\dp\d)/agasc$par{agasc}/;
	}
    }

    # Check that version is acceptable 
    ($mp_agasc_version) = ($ENV{ASCDS_AGASC} =~ /agasc(\dp\d)/);
    die "Starcheck only supports AGASC 1.4, 1.5, and 1.6.  Found '$mp_agasc_version'\n"
	unless ($mp_agasc_version =~ /(1p4|1p5|1p6)/);
    $mp_agasc_version =~ s/p/./;
    ($ascds_version_name) = ($ENV{ASCDS_BIN} =~ /\/DS\.([^\/]+)/);
    $ascds_version = $ENV{ASCDS_VERSION};
    print STDERR "Configuration:  AGASC $mp_agasc_version   ASCDS $ascds_version_name ($ascds_version)\n"
}


unless (-e $STARCHECK) {
    die "Couldn't make directory $STARCHECK\n" unless (mkdir $STARCHECK, 0777);
    print STDERR "Created plot directory $STARCHECK\n";
    print $log_fh "Created plot directory $STARCHECK\n" if ($log_fh);
}


# First read the Backstop file, and split into components
my $bogus_obsid = 1;
my @bs = Parse_CM_File::backstop($backstop);

my $i = 0;
my (@date, @vcdu, @cmd, @params, @time);
foreach my $bs (@bs) {
    ( $date[$i], $vcdu[$i], $cmd[$i], $params[$i], $time[$i] ) =
	( $bs->{date}, $bs->{vcdu}, $bs->{cmd}, $bs->{params}, $bs->{time} );
    $i++;
#    print STDERR "BS TIME = $bs->{time} \n";
}

# Read DOT, which is used to figure the Obsid for each command
my ($dot_ref, $dot_touched_by_sausage) = Parse_CM_File::DOT($dot_file) if ($dot_file);
my %dot = %$dot_ref;

#foreach my $dotkey (keys  %dot){
#	print STDERR "$dotkey $dot{$dotkey}{cmd_identifier} $dot{$dotkey}{anon_param3} $dot{$dotkey}{anon_param4} \n";
#}

# Read momentum management (maneuvers + SIM move) summary file 
my %mm = Parse_CM_File::MM($mm_file) if ($mm_file);

# Read mech check file and parse
my @mc  = Parse_CM_File::mechcheck($mech_file) if ($mech_file);

# Read SOE file and parse
my %soe  = Parse_CM_File::SOE($soe_file) if ($soe_file);

# Read OR file and integrate into %obs
my %or = Parse_CM_File::OR($or_file) if ($or_file);

# Read FIDSEL (fid light) history file and ODB (for fid
# characteristics) and parse; use fid_time_violation later (when global_warn set up

my ($fid_time_violation, $error, @fidsel) = Parse_CM_File::fidsel($fidsel_file, \@bs) ;

# Set up for global warnings
my @global_warn;
map { warning("$_\n") } @{$error};

# Now that global_warn exists, if the DOT wasn't made/modified by SAUSAGE
# throw an error
if ($dot_touched_by_sausage == 0 ){
	warning("DOT file not modified by SAUSAGE! \n");
}


my %odb = Parse_CM_File::odb($odb_file);
Obsid::set_odb(%odb);

# Read Maneuver error file containing more accurate maneuver errors
my @manerr;
if ($manerr_file) { 
    @manerr = Parse_CM_File::man_err($manerr_file);
} else { warning("Could not find Maneuver Error file in output/ directory\n") };

# Read DITHER history file and backstop to determine expected dither state
my ($dither_time_violation, @dither) = Parse_CM_File::dither($dither_file, \@bs);

# if dither history runs into load
if ($dither_time_violation){
    warning("Dither History runs into load!\n");
} 

# if fidsel history runs into load
if ($fid_time_violation){
    warning("Fidsel History runs into load!\n");
}


# Read in the failed acquisition stars
warning("Could not open ACA bad acquisition stars file $bad_acqs_file\n")
    unless (Obsid::set_bad_acqs($bad_acqs_file));

# Read in the ACA bad pixels
warning("Could not open ACA bad pixel file $ACA_bad_pixel_file\n")
    unless (Obsid::set_ACA_bad_pixels($ACA_bad_pixel_file));

# Read bad AGASC stars
warning("Could not open bad AGASC file $bad_agasc_file\n")
    unless (Obsid::set_bad_agasc($bad_agasc_file));

# Initialize list of "interesting" commands

my (%dot_cmd, %dot_time_offset, %dot_tolerance);
set_dot_cmd();  

# Go through records and set the time of MP_TARGQUAT commands to
# the time of the subsequent cmd with COMMAND_SW | TLMSID= AOMANUVR

fix_targquat_time();

# Now go through records, pull out the interesting things, and assemble
# into structures based on obsid. 

my $obsid;
my %obs;
my @obsid_id;
for my $i (0 .. $#cmd) {
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

foreach my $obsid (@obsid_id) {
    $obs{$obsid}->set_obsid(); # Commanded obsid
    $obs{$obsid}->set_target();
    $obs{$obsid}->set_star_catalog();
    $obs{$obsid}->set_maneuver(%mm) if ($mm_file);
    $obs{$obsid}->set_manerr(@manerr) if (@manerr);
    $obs{$obsid}->set_files($STARCHECK, $backstop, $guide_summ, $or_file, $mm_file, $dot_file);
    $obs{$obsid}->set_fids(@fidsel);
    map { $obs{$obsid}->{$_} = $or{$obsid}{$_} } keys %{$or{$obsid}} if (exists $or{$obsid});
}

# Read guide star summary file $guide_summ.
# This file is the OFLS summary of guide/acq/fid star catalogs for
# each obsid.  In addition to confirming numbers from Backstop, it
# has star id's and magnitudes.  The results are stored in the
# MP_STARCAT cmd, so this processing has to occur after set_star_catalog

my %guidesumm = Parse_CM_File::guide($guide_summ) if (defined $guide_summ);

foreach my $oflsid (keys %guidesumm){
    unless (defined $obs{$oflsid}){
	push @global_warn, sprintf("WARNING: OFLS ID $oflsid in Guide Summ but not in DOT! \n");
    }
}


foreach my $oflsid (@obsid_id){
    if (defined $guidesumm{$oflsid}){
	$obs{$oflsid}->add_guide_summ($oflsid, \%guidesumm);
    }
    else {
	push @{$obs{$oflsid}->{warn}}, sprintf("WARNING: No Guide Star Summary for :$oflsid: \n");			
    }
	
}


# Set up for SIM-Z checking
# Find SIMTSC continuity statement from mech check file
# and find SIMTRANS statements in backstop

my @sim_trans = ();
foreach my $mc (@mc) {
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

# Do main checking

foreach my $obsid (@obsid_id) {
    if ($par{plot}) {
	$obs{$obsid}->get_agasc_stars($mp_agasc_version);
	$obs{$obsid}->identify_stars();
	$obs{$obsid}->plot_stars("$STARCHECK/stars_$obs{$obsid}->{obsid}.gif") ;
    }

    $obs{$obsid}->check_star_catalog();
    $obs{$obsid}->make_figure_of_merit();
    $obs{$obsid}->check_monitor_commanding(\@bs, $or{$obsid});
    $obs{$obsid}->check_sim_position(@sim_trans);
    $obs{$obsid}->check_dither(\@dither);

    # Make sure there is only one star catalog per obsid
    warning ("More than one star catalog assigned to Obsid $obsid\n")
	if ($obs{$obsid}->find_command('MP_STARCAT',2));
}

# Produce final report

my $out = '\fixed_start ';
my $date = `date`;
chomp $date;

$out .= "------------  Starcheck V$version    -----------------\n";
$out .= " Run on $date by $ENV{USER}\n";
$out .= " Configuration:  AGASC $mp_agasc_version  ASCDS $ascds_version_name ($ascds_version)\n"
    if ($mp_agasc_version and $ascds_version_name);
$out .= "\n";

if (%input_files) {
    $out .= "------------  PROCESSING FILES  -----------------\n\n";
    for my $name (keys %input_files) { $out .= "Using $name file $input_files{$name}\n" };
    $out .= "\n";
}


if (@global_warn) {
    $out .= "------------  PROCESSING WARNING  -----------------\n";
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
my $ptf = PoorTextFormat->new();

# Write make_stars file
my $make_stars = "$STARCHECK/make_stars.txt";
open (my $OUT, "> $make_stars") or die "Couldn't open $make_stars for writing\n";
foreach my $obsid (@obsid_id) {
    my $c = $obs{$obsid};
    my $format = ($c->{obsid} =~ /^[0-9]+$/) ? "%05d" : "%s";
    printf $OUT "../make_stars.pl -starcat starcat.dat.$format", $c->{obsid};
    print $OUT " -ra $c->{ra} -dec $c->{dec} -roll $c->{roll} ";
    print $OUT "-sim_z $c->{SIM_OFFSET_Z} " if ($c->{SIM_OFFSET_Z});
    print $OUT "-si $c->{SI} " if ($c->{SI});
    print $OUT "\n";
}

# Write the HTML

if ($par{html}) {
    open (my $OUT, "> $STARCHECK.html") or die "Couldn't open $STARCHECK.html for writing\n";
    print $OUT $ptf->ptf2any('html', $out);
    close $OUT;
    print STDERR "Wrote HTML report to $STARCHECK.html\n";

    my $guide_summ_start = (defined $mp_agasc_version and $mp_agasc_version eq '1.4') ? 
      'PROCESSING SOCKET REQUESTS' : '';
    make_annotated_file('', 'starcat.dat.', ' -ra ', $make_stars);
    make_annotated_file('', ' ID=\s+', ', ', $backstop);
    make_annotated_file($guide_summ_start, '^\s+ID:\s+', '\S\S', $guide_summ);
    make_annotated_file('', '^ ID=', ', ', $or_file) if ($or_file);
    make_annotated_file('', ' ID:\s+', '\S\S', $mm_file);
    make_annotated_file('', 'OBSID,ID=', ',', $dot_file);
}

# Write the TEXT

if ($par{text}) {
    open (my $OUT, "> $STARCHECK.txt") or die "Couldn't open $STARCHECK.txt for writing\n";
    print $OUT $ptf->ptf2any('text', $out);
    close $OUT;
    print STDERR "Wrote text report to $STARCHECK.txt\n";
}

# Update the Chandra expected state file, if desired and possible

if ($mech_file && $mm_file && $dot_file && $soe_file && $par{chex}) {
   print STDERR "Updating Chandra expected state file\n";
   print $log_fh "Updating Chandra expected state file\n" if ($log_fh);
   my $chex = new Chex $par{chex};
   $chex->update(mman         => \%mm,
		 mech_check   => \@mc, 
		 dot          => \%dot,
		 soe          => \%soe,
		 OR           => \%or,
		 backstop     => \@bs,
		 dither       => \@dither,
		);
}

##***************************************************************************
sub make_annotated_file {
##***************************************************************************
# $backstop   = get_file("$par{dir}/*.backstop",'backstop', 'required');
# $guide_summ = get_file("$par{dir}/mg*.sum",   'guide summary');
# $or_file    = get_file("$par{dir}/*.or",      'OR');
# $mm_file    = get_file("$par{dir}/*/mm*.sum", 'maneuver');
# $dot_file   = get_file("$par{dir}/*.dot",     'DOT', 'required');

    my ($start_rexp, $id_pre, $id_post, $file_in) = @_;
    open(my $FILE1, $file_in) or return;
    my @lines = <$FILE1>;
    close $FILE1;

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

    my $file_out = "$STARCHECK/" . basename($file_in) . ".html";

    open(my $FILE2, "> $file_out") or die "Couldn't open $file_out for writing\n";
    print $FILE2 $ptf->ptf2any('html', "\\fixed_start \n" . join('',@lines));
    close $FILE2;
}

##***************************************************************************
sub fix_targquat_time {
##***************************************************************************
# Go through records and set the time of MP_TARGQUAT commands to
# the time of the subsequent cmd with COMMAND_SW | TLMSID= AOMANUVR
    my $manv_time;
    my $set = 0;

    for my $i (reverse (0 .. $#cmd)) {
        if ($cmd[$i] eq 'COMMAND_SW' and $params[$i] =~ /AOMANUVR/) {
#	    print STDERR "First: $cmd[$i], $time[$i], $date[$i] \n";
	    $manv_time = $time[$i];
	    $set = 1;
	}
	if ($cmd[$i] eq 'MP_TARGQUAT') {
#	    print STDERR "Second: $cmd[$i], $time[$i], $date[$i] \n";
	    if ($set eq 1) {
		$time[$i] = $manv_time;
#		undef $manv_time;	# Make sure that each TARGQUAT gets a unique AOMANUVR time
	        $set = 0;   
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
			ATS_OBSID => 90.0,
			);

    %dot_tolerance = (ATS_DTHR  => 200.0,
		      ATS_OBSID => 110.0,
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

    foreach my $obsid_index (keys %dot) {
	next unless ($dot_cmd{ $dot{$obsid_index}{cmd_identifier}});
	my $cmd_identifier = $dot{$obsid_index}{cmd_identifier};
	my $dt        = $dot_time_offset{$cmd_identifier} || 0.0;
	my $tolerance = $dot_tolerance{$cmd_identifier}   || $TIME_TOLERANCE ;
	if ($dot_cmd{$cmd_identifier} eq $cmd
	    && abs($dot{$obsid_index}{time} + $dt - $time) < $tolerance) {
	   if ($obsid_index =~ /\S0*(.+)\d\d\d\d/){
		    return $1; 
	   }
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
sub get_file {
##***************************************************************************
    my $glob = shift;
    my $name = shift;
    my $required = shift;
    my $warning = ($required ? "ERROR" : "WARNING");

    my @files = glob($glob);
    if (@files != 1) {
	print STDERR ((@files == 0) ?
		      "$warning: No $name file matching $glob\n"
		      : "$warning: Found more than one file matching $glob, using none\n");
	die "\n" if ($required);
	return undef;
    } 
    $input_files{$name}=$files[0];
    print STDERR "Using $name file $files[0]\n";
    print $log_fh "Using $name file $files[0]\n" if ($log_fh);
    return $files[0];
}

##***************************************************************************
#sub insert_bogus_obsid {
##***************************************************************************
#    @date = (@date[0..$i-1], $date[$i_last_starcat], @date[$i..$#date]);
#    @vcdu = (@vcdu[0..$i-1], $vcdu[$i_last_starcat]+4, @vcdu[$i..$#vcdu]);
#    @cmd = (@cmd[0..$i-1], 'MP_OBSID', @cmd[$i..$#cmd]);
#    @params = (@params[0..$i-1], "ID= NONE$bogus_obsid", @params[$i..$#params]);
#    warning ("A star catalog does not have an associated obsid, " 
#	. "using bogus obsid NONE$bogus_obsid\n");
#    $bogus_obsid++;
#}
    

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

