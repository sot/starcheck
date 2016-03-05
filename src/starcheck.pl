#!/usr/bin/env /proj/sot/ska/bin/perl

##*******************************************************************************
#
#  Starcheck.pl - Check for problems in command load star catalogs, and maintain
#                 the expected state of Chandra file
#
##*******************************************************************************


my $version = '11.7dev';

# Set defaults and get command line options

use strict;
use warnings;
use Getopt::Long;
use IO::File;
use IO::All;
use Sys::Hostname;
use English;
use File::Basename;
use File::Copy;
use Scalar::Util qw(looks_like_number);

use Time::JulianDay;
use Time::DayOfYear;
use Time::Local;
use PoorTextFormat;

#use lib '/proj/axaf/simul/lib/perl';
#use GrabEnv qw( grabenv );
#use Shell::GetEnv;

use Ska::Starcheck::Obsid;
use Ska::Parse_CM_File;
use Carp;
use YAML;
use JSON ();

use Ska::Convert qw( date2time );
use Cwd qw( abs_path );

use HTML::TableExtract;

use Ska::AGASC;


use Inline Python => q{

from starcheck.pcad_att_check import make_pcad_attitude_check_report, check_characteristics_date
from starcheck.calc_ccd_temps import get_ccd_temps

def ccd_temp_wrapper(kwargs):
    return get_ccd_temps(**kwargs)

def plot_cat_wrapper(kwargs):
    try:
        from starcheck.plot import make_plots_for_obsid
    except ImportError as err:
        # write errors to starcheck's global warnings and STDERR
        perl.warning("Error with Inline::Python imports {}\n".format(err))
    return make_plots_for_obsid(**kwargs)

};

# cheat to get the OS (major)
my $OS = `uname`;
chomp($OS);


# Set some global vars with directory locations
my $SKA = $ENV{SKA} || '/proj/sot/ska';

my %par = (dir  => '.',
		   plot => 1,
		   html => 1,
		   text => 1,
		   yaml => 1,
		   config_file => "characteristics.yaml",
		   fid_char => "fid_CHARACTERISTICS",
		   );

my $agasc_parent_dir = '/proj/sot/ska/data/agasc';
my $default_agasc_dir = '/proj/sot/ska/data/agasc1p6/';

GetOptions( \%par, 
			'help', 
			'dir=s',
			'out=s',
			'plot!',
			'html!',
			'text!',
			'yaml!',
			'vehicle!',
			'agasc=s',
			'agasc_dir=s',
			'sc_data=s',
			'fid_char=s',
			'config_file=s',
			) ||
    exit( 1 );


my $Starcheck_Data = $par{sc_data} || "$ENV{SKA_DATA}/starcheck" || "$SKA/data/starcheck";

my $STARCHECK   = $par{out} || ($par{vehicle} ? 'v_starcheck' : 'starcheck');



my $empty_font_start = qq{<font>};
my $red_font_start = qq{<font color="#FF0000">};
my $yellow_font_start = qq{<font color="#009900">};
my $blue_font_start = qq{<font color="#0000FF">};
my $font_stop = qq{</font>};

usage( 1 )
    if $par{help};

# Find backstop, guide star summary, OR, and maneuver files.
my %input_files = ();

# for split loads directory and prefix configuration 
my $sosa_dir_slash = $par{vehicle} ? "vehicle/" : "";
my $sosa_prefix = $par{vehicle} ? "V_" : "";


# Set up for global warnings
my @global_warn;

# asterisk only include to make globs work correctly
my $backstop   = get_file("$par{dir}/${sosa_dir_slash}*.backstop", 'backstop', 'required');
my $guide_summ = get_file("$par{dir}/mps/mg*.sum",   'guide summary');
my $or_file    = get_file("$par{dir}/mps/or/*.or",      'OR');
my $mm_file    = get_file("$par{dir}/mps/mm*.sum", 'maneuver');
my $dot_file   = get_file("$par{dir}/mps/md*.dot",     'DOT', 'required');
my $mech_file  = get_file("$par{dir}/${sosa_dir_slash}output/${sosa_prefix}TEST_mechcheck.txt*", 'mech check');
my $soe_file   = get_file("$par{dir}/mps/soe/ms*.soe", 'SOE');
my $fidsel_file= get_file("$par{dir}/History/FIDSEL.txt*",'fidsel');    
my $dither_file= get_file("$par{dir}/History/DITHER.txt*",'dither'); 
my $radmon_file= get_file("$par{dir}/History/RADMON.txt*", 'radmon');
my $simtrans_file= get_file("$par{dir}/History/SIMTRANS.txt*", 'simtrans');
my $simfocus_file= get_file("$par{dir}/History/SIMFOCUS.txt*", 'simfocus');

# Check for characteristics.  Ignore the get_file required vs not API and just pre-check
# to see if there is characteristics
my $char_file;
for my $char_glob ("$par{dir}/mps/ode/characteristics/L_*_CHARACTERIS*",
                   "$par{dir}/mps/ode/characteristics/CHARACTERIS*"){
    if (glob($char_glob)){
        $char_file  = get_file($char_glob, 'characteristics');
        last;
    }
}


my $config_file = get_file("$Starcheck_Data/$par{config_file}*", 'config', 'required');

my $config_ref = YAML::LoadFile($config_file);
my $mp_top_link = guess_mp_toplevel({ path => abs_path($par{dir}), 
									  config => $config_ref });


my $odb_file = get_file("$Starcheck_Data/$par{fid_char}*", 'odb', 'required');


my $agasc_dir = $default_agasc_dir;
if ( defined $par{agasc} or defined $par{agasc_dir}){
    if ( defined $par{agasc} and defined $par{agasc_dir}){
	print STDERR "Option 'agasc_dir' overrides 'agasc' \n";
	$agasc_dir = $par{agasc_dir};
    }
    else{
	if ( defined $par{agasc} ){
	    if ( $par{agasc} =~ /^(1p4|1p5|1p6)$/ ){
		$agasc_dir = $agasc_parent_dir . $par{agasc} . '/';
	    }
	    else{
		croak("Problem with command line: if 'agasc' specified, choice must be '1p4', '1p5', or '1p6'");
	    }
	}
	if ( defined $par{agasc_dir} ){
	    $agasc_dir = $par{agasc_dir};
	}
    }
}
print STDERR "Using AGASC from $agasc_dir \n";



my $manerr_file= get_file("$par{dir}/output/*_ManErr.txt",'manerr');    
my $ps_file    = get_file("$par{dir}/mps/ms*.sum", 'processing summary');
my $tlr_file   = get_file("$par{dir}/${sosa_dir_slash}*.tlr", 'TLR', 'required');

my $bad_agasc_file = get_file("$Starcheck_Data/agasc.bad", 'banned_agasc');
my $ACA_bad_pixel_file = get_file("$Starcheck_Data/ACABadPixels", 'bad_pixel');
my $bad_acqs_file = get_file( "$Starcheck_Data/bad_acq_stars.rdb", 'acq_star_rdb');
my $bad_gui_file = get_file( "$Starcheck_Data/bad_gui_stars.rdb", 'gui_star_rdb');


# Let's find which dark current made the current bad pixel file

my $ACA_badpix_date;
my $ACA_badpix_firstline =  io($ACA_bad_pixel_file)->getline;

if ($ACA_badpix_firstline =~ /Bad Pixel.*\d{7}\s+\d{7}\s+(\d{7}).*/ ){
    $ACA_badpix_date = $1;
    print STDERR "Using ACABadPixel file from $ACA_badpix_date Dark Cal \n";
}


unless (-e $STARCHECK) {
    die "Couldn't make directory $STARCHECK\n" unless (mkdir $STARCHECK, 0777);
    print STDERR "Created plot directory $STARCHECK\n";
}

# copy over the up and down gifs and overlib
for my $data_file ('up.gif', 'down.gif', 'overlib.js'){
    copy( "${Starcheck_Data}/${data_file}", "${STARCHECK}/${data_file}")
	or print STDERR "copy(${Starcheck_Data}/${data_file}, ${STARCHECK}/${data_file}) failed: $! \n";
}





# First read the Backstop file, and split into components
my $bogus_obsid = 1;
my @bs = Ska::Parse_CM_File::backstop($backstop);

my $i = 0;
my (@date, @vcdu, @cmd, @params, @time);
foreach my $bs (@bs) {
    ( $date[$i], $vcdu[$i], $cmd[$i], $params[$i], $time[$i] ) =
	( $bs->{date}, $bs->{vcdu}, $bs->{cmd}, $bs->{params}, $bs->{time} );
    $i++;
#    print STDERR "BS TIME = $bs->{time} \n";
}

# Read DOT, which is used to figure out the Obsid for each command
my ($dot_ref, $dot_touched_by_sausage) = Ska::Parse_CM_File::DOT($dot_file) if ($dot_file);
my %dot = %{$dot_ref};


#foreach my $dotkey (keys  %dot){
#	print STDERR "$dotkey $dot{$dotkey}{cmd_identifier} $dot{$dotkey}{anon_param3} $dot{$dotkey}{anon_param4} \n";
#}

my @load_segments = Ska::Parse_CM_File::TLR_load_segments($tlr_file);

# Read momentum management (maneuvers + SIM move) summary file 
my %mm = Ska::Parse_CM_File::MM({file => $mm_file, ret_type => 'hash'}) if ($mm_file);

# Read maneuver management summary for handy obsid time checks
my @ps = Ska::Parse_CM_File::PS($ps_file) if ($ps_file);

# Read mech check file and parse
my @mc  = Ska::Parse_CM_File::mechcheck($mech_file) if ($mech_file);

# Read SOE file and parse
my %soe  = Ska::Parse_CM_File::SOE($soe_file) if ($soe_file);

# Read OR file and integrate into %obs
my %or = Ska::Parse_CM_File::OR($or_file) if ($or_file);

# Read FIDSEL (fid light) history file and ODB (for fid
# characteristics) and parse; use fid_time_violation later (when global_warn set up

my ($fid_time_violation, $error, $fidsel) = Ska::Parse_CM_File::fidsel($fidsel_file, \@bs) ;
map { warning("$_\n") } @{$error};


# do a tiny AGASC search to see which method will be used
my $tiny_agasc_search = Ska::AGASC->new({ra=>0,dec=>0,w=>0.001}); 
my $agasc_method = $Ska::AGASC::access_method;
if ($agasc_method =~ /cfitsio/){
    warning("Ska::AGASC call to mp_get_agasc failed.  Output not approved for authoritative load review. \n");
} 

## Warn if we are on Solaris
if ($OS eq 'SunOS'){
    warning("uname == SunOS; starcheck is only approved on Linux \n");
}


# See if we have database access
my $db_handle;
eval{
    eval 'use Ska::DatabaseUtil';
    $db_handle = Ska::DatabaseUtil::sql_connect( 'sybase-aca-aca_read' );

};
if (($@) or (not defined $db_handle)){
    warning("Unable to connect to Sybase server; links generated for all AGASC ids by default \n");
}
else{
    Ska::Starcheck::Obsid::set_db_handle($db_handle);
  }

# Dark Cal Checker Section
use Ska::Starcheck::Dark_Cal_Checker;
my $dark_cal_checker;
eval{
    $dark_cal_checker = Ska::Starcheck::Dark_Cal_Checker->new({ dir => $par{dir},
                                                                app_data => $Starcheck_Data});
};
if ($@){
	unless ($@ =~ /No ACA commanding found/){
		warning("Dark Cal Checker Failed $@ \n");
	}
}



# Now that global_warn exists, if the DOT wasn't made/modified by SAUSAGE
# throw an error
if ($dot_touched_by_sausage == 0 ){
	warning("DOT file not modified by SAUSAGE! \n");
}



Ska::Starcheck::Obsid::setcolors({ red => $red_font_start,
				   blue => $blue_font_start,
				   yellow => $yellow_font_start, 
				   });

my %odb = Ska::Parse_CM_File::odb($odb_file);
Ska::Starcheck::Obsid::set_odb(%odb);


Ska::Starcheck::Obsid::set_config($config_ref);




# Read Maneuver error file containing more accurate maneuver errors
my @manerr;
if ($manerr_file) { 
    @manerr = Ska::Parse_CM_File::man_err($manerr_file);
} else { warning("Could not find Maneuver Error file in output/ directory\n") };

# Read DITHER history file and backstop to determine expected dither state
my ($dither_time_violation, $dither) = Ska::Parse_CM_File::dither($dither_file, \@bs);

my ($radmon_time_violation, $radmon) = Ska::Parse_CM_File::radmon($radmon_file, \@bs);

# if dither history runs into load
if ($dither_time_violation){
    warning("Dither History runs into load\n");
} 

# if radmon history runs into load
if ($radmon_time_violation){
  warning("Radmon History runs into load\n");
}

# if fidsel history runs into load
if ($fid_time_violation){
    warning("Fidsel History runs into load\n");
}


# Read in the failed acquisition stars
warning("Could not open ACA bad acquisition stars file $bad_acqs_file\n")
    unless (Ska::Starcheck::Obsid::set_bad_acqs($bad_acqs_file));


# Read in the troublesome guide stars
warning("Could not open ACA bad guide star file $bad_gui_file\n")
    unless (Ska::Starcheck::Obsid::set_bad_gui($bad_gui_file));


# Read in the ACA bad pixels
warning("Could not open ACA bad pixel file $ACA_bad_pixel_file\n")
    unless (Ska::Starcheck::Obsid::set_ACA_bad_pixels($ACA_bad_pixel_file));

# Read bad AGASC stars
warning("Could not open bad AGASC file $bad_agasc_file\n")
    unless (Ska::Starcheck::Obsid::set_bad_agasc($bad_agasc_file));

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
    # Get obsid (aka ofls_id) for this cmd by matching up with corresponding
    # commands from DOT.  Returns undef if it isn't "interesting"
    next unless ($obsid = get_obsid ($time[$i], $cmd[$i], $date[$i]));
    
    # If obsid hasn't been seen before, create obsid object

    unless ($obs{$obsid}) {
	push @obsid_id, $obsid;	
	$obs{$obsid} = Ska::Starcheck::Obsid->new($obsid, $date[$i]);
    }

    # Add the command to the correct obs object

    $obs{$obsid}->add_command( { Ska::Parse_CM_File::parse_params($params[$i]),
				 vcdu => $vcdu[$i],
				 date => $date[$i],
				 time => $time[$i],
				 cmd  => $cmd[$i] } );
}

# Read guide star summary file $guide_summ.  This file is the OFLS summary of
# guide/acq/fid star catalogs for each obsid.  In addition to confirming
# numbers from Backstop, it has star id's and magnitudes.

my %guidesumm = Ska::Parse_CM_File::guide($guide_summ) if (defined $guide_summ);

# After all commands have been added to each obsid, set some global
# object parameters based on commands

foreach my $obsid (@obsid_id) {
    $obs{$obsid}->set_obsid(\%guidesumm); # Commanded obsid
    $obs{$obsid}->set_ok_no_starcat();
    $obs{$obsid}->set_target();
    $obs{$obsid}->set_star_catalog();
    $obs{$obsid}->set_maneuver(%mm) if ($mm_file);
    $obs{$obsid}->set_manerr(@manerr) if (@manerr);
    $obs{$obsid}->set_files($STARCHECK, $backstop, $guide_summ, $or_file, $mm_file, $dot_file, $tlr_file);
    $obs{$obsid}->set_fids($fidsel);
    $obs{$obsid}->set_ps_times(@ps) if ($ps_file);
    map { $obs{$obsid}->{$_} = $or{$obsid}{$_} } keys %{$or{$obsid}} if (exists $or{$obsid});
}

# Create pointers from each obsid to the previous obsid (except the first one)
# and the next obsid
for my $obsid_idx (0 .. ($#obsid_id)){
    $obs{$obsid_id[$obsid_idx]}->{prev} = ( $obsid_idx > 0 ) ? $obs{$obsid_id[$obsid_idx-1]} : undef;
    $obs{$obsid_id[$obsid_idx]}->{next} = ( $obsid_idx < $#obsid_id) ? $obs{$obsid_id[$obsid_idx+1]} : undef;
}

# Set the NPM times.  This requires the PREV/NEXT entries
foreach my $obsid (@obsid_id) {
    $obs{$obsid}->set_npm_times();
}

# Check that every Guide summary OFLS ID has a matching OFLS ID in DOT

foreach my $oflsid (keys %guidesumm){
    unless (defined $obs{$oflsid}){
	warning("OFLS ID $oflsid in Guide Summ but not in DOT! \n");
    }
}

# Add guide_summary data to MP_STARCAT cmd for each obsid.  

HAS_GUIDE:
foreach my $oflsid (@obsid_id){
    if (defined $guidesumm{$oflsid}){
		$obs{$oflsid}->add_guide_summ($oflsid, \%guidesumm);
    }
    else {
		my $obsid = $obs{$oflsid}->{obsid};
		if (defined $obs{$oflsid}->{ok_no_starcat}){
			my $ofls_string = $obs{$oflsid}->{ok_no_starcat};
			push @{$obs{$oflsid}->{fyi}}, 
			sprintf(">> INFO   : No Guide Star Summary for obsid $obsid ($oflsid). OK for '$ofls_string' ER. \n");
			next HAS_GUIDE;
		}
		push @{$obs{$oflsid}->{warn}}, sprintf(">> WARNING: No Guide Star Summary for obsid $obsid ($oflsid). \n");			
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

# Take the MP_STARCAT hash from find_command and convert it into an array with
# a record for each catalog index.  This is used for the Python plotting of the
# catalog
sub catalog_array{
    my $cat = shift;
    my @catarr;
    for $i (1 .. 16){
        if (not exists $cat->{"TYPE$i"}){
            next;
        }
        if ($cat->{"TYPE$i"} eq 'NUL'){
            next;
        }
        my %catrow = ('yang'=>$cat->{"YANG$i"},
                      'zang'=>$cat->{"ZANG$i"},
                      'halfw'=>$cat->{"HALFW$i"},
                      'type'=>$cat->{"TYPE$i"},
                      'idx'=>$i);
        push @catarr, \%catrow;
    }
    return \@catarr;
}


# Write out Obsid objects as JSON
# include a routine to change the internal context to a float/int
# for everything that looks like a number
sub force_numbers {
    if (ref $_[0] eq ""){
        if ( looks_like_number($_[0]) ){
            $_[0] += 0;
        }
    } elsif ( ref $_[0] eq 'ARRAY' ){
        force_numbers($_) for @{$_[0]};
    } elsif ( ref $_[0] eq 'HASH' ) {
        force_numbers($_) for values %{$_[0]};
    }
    return $_[0];
}


sub json_obsids{

    my @all_obs;
    my %exclude = ('next' => 1, 'prev' => 1, 'agasc_hash' => 1);
    foreach my $obsid (@obsid_id){
        my %obj = ();
        for my $tkey (keys(%{$obs{$obsid}})){
            if (not defined $exclude{$tkey}){
                $obj{$tkey} = $obs{$obsid}->{$tkey};
            }
        }
        push @all_obs, \%obj;
    }

    return JSON::to_json(force_numbers(\@all_obs), {pretty => 1});
}


my $json_text = json_obsids();
my $obsid_temps;
eval{
    my $json_obsid_temps;
    $json_obsid_temps = ccd_temp_wrapper({oflsdir=> $par{dir},
                                          outdir=>$STARCHECK,
                                          json_obsids => $json_text,
                                          model_spec => "$Starcheck_Data/aca_spec.json",
                                          char_file => "$Starcheck_Data/characteristics.yaml",
                                      });
    # convert back from JSON outside
    $obsid_temps = JSON::from_json($json_obsid_temps);
};
if ($@){
    push @global_warn, "Error getting temperatures from get_ccd_temps\n";
}

if ($obsid_temps){
    foreach my $obsid (@obsid_id) {
        $obs{$obsid}->set_ccd_temps($obsid_temps);
    }
}


# Do main checking
foreach my $obsid (@obsid_id) {
    $obs{$obsid}->get_agasc_stars($agasc_dir);
    $obs{$obsid}->identify_stars();
    my $cat = Ska::Starcheck::Obsid::find_command($obs{$obsid}, "MP_STARCAT");
    # If the catalog is empty, don't make plots
    if (defined $cat){
        my $cat_as_array = catalog_array($cat);
        my %plot_args = (obsid=>"$obs{$obsid}->{obsid}",
                         ra=>$obs{$obsid}->{ra},
                         dec=>$obs{$obsid}->{dec},
                         roll=>$obs{$obsid}->{roll},
                         catalog=>$cat_as_array,
                         starcat_time=>"$obs{$obsid}->{date}",
                         outdir=>$STARCHECK);
        eval{
            plot_cat_wrapper(\%plot_args);
        };
        if ($@){
            push @global_warn, "Error Python plotting catalog\n";
        }
        $obs{$obsid}->{plot_file} = "$STARCHECK/stars_$obs{$obsid}->{obsid}.png";
        $obs{$obsid}->{plot_field_file} = "$STARCHECK/star_view_$obs{$obsid}->{obsid}.png";
        $obs{$obsid}->{compass_file} = "$STARCHECK/compass$obs{$obsid}->{obsid}.png";
    }
    $obs{$obsid}->check_monitor_commanding(\@bs, $or{$obsid});
    $obs{$obsid}->check_flick_pix_mon();
    $obs{$obsid}->set_dynamic_mag_limits();
    $obs{$obsid}->check_dither($dither);
    $obs{$obsid}->check_star_catalog($or{$obsid}, $par{vehicle});
    $obs{$obsid}->check_sim_position(@sim_trans) unless $par{vehicle};
	$obs{$obsid}->check_momentum_unload(\@bs);
    $obs{$obsid}->check_for_special_case_er();
    $obs{$obsid}->check_bright_perigee($radmon);
    $obs{$obsid}->count_good_stars();
    $obs{$obsid}->make_figure_of_merit();
# Make sure there is only one star catalog per obsid
    warning ("More than one star catalog assigned to Obsid $obsid\n")
	if ($obs{$obsid}->find_command('MP_STARCAT',2));
}

my $final_json = json_obsids();
open(my $JSON_OUT, "> $STARCHECK/obsids.json")
     or die "Couldn't open $STARCHECK/obsids.json for writing\n";
print $JSON_OUT $final_json;
close($JSON_OUT);

# Produce final report
my %save_hash;

my $out = '<TABLE><TD><PRE> ';
my $date = `date`;
chomp $date;

my $hostname = hostname;
$save_hash{run}{date} = $date;

$out .= "------------  Starcheck $version    -----------------\n";
$out .= " Run on $date by $ENV{USER} from $hostname\n";
$out .= " Configuration:  Using AGASC at $agasc_dir\n";
# ASCDS $ascds_version_name ($ascds_version)\n"
#    if ($mp_agasc_version and $ascds_version_name);
$out .= "\n";

$save_hash{run}{user} = $ENV{USER};
$save_hash{run}{host} = $hostname;
$save_hash{run}{agasc} = $agasc_dir;

if ($mp_top_link){
    $out .= sprintf("<A HREF=\"%s\">Short Term Schedule: %s</A>", $mp_top_link->{url}, $mp_top_link->{week});
    $out .= "\n\n";
}



if (%input_files) {
    $out .= "------------  PROCESSING FILES  -----------------\n\n";
    for my $name (sort (keys %input_files)) { 
	$out .= "Using $name file $input_files{$name}\n";
	push @{$save_hash{files}}, $input_files{$name};
    };
     
# Add info about which bad pixel file is being used:
    if (defined $ACA_badpix_date){
	$out .= "Using ACABadPixel file from $ACA_badpix_date Dark Cal \n";
	$save_hash{run}{badpix} = $ACA_badpix_date;
    }

    $out .= "\n";
}

if (@global_warn) {
    $out .= "------------  PROCESSING WARNING  -----------------\n\n";
    $out .= $red_font_start;
    foreach (@global_warn) {
	$out .= $_;
        push @{$save_hash{processing_warning}}, $_;
    }
    $out .= qq{${font_stop}\n};
}


# Run independent attitude checker
my $CHAR_REQUIRED_AFTER = '2015:315:00:00:00.000';
if ((defined $char_file) or ($bs[0]->{time} > date2time($CHAR_REQUIRED_AFTER))){
    $out .= "------------  VERIFY ATTITUDE (SI_ALIGN CHECK)  -----------------\n\n";
    if (not defined $char_file){
        $out .= "Error.  Characteristics file not found. \n";
    }
    else{
        my $att_report = "${STARCHECK}/pcad_att_check.txt";
        my $att_ok = make_pcad_attitude_check_report(
            $backstop, $or_file, $mm_file, $simtrans_file, $simfocus_file,
            $char_file, $att_report);
        if ($att_ok){
            $out .= "<A HREF=\"${att_report}\">[OK] Coordinates as expected.</A>\n";
        }
        else{
            $out .= "<A HREF=\"${att_report}\">[${red_font_start}NOT OK${font_stop}] Coordinate mismatch or error.</A>\n";
        }
        if (check_characteristics_date($char_file, $date[0])){
            $out .= "[OK] Characteristics file newer than 30 days\n\n";
        }
        else{
            $out .= "[${red_font_start}NOT OK${font_stop}] Characteristics file older than 30 days\n\n";
        }
    }
}

# Dark Cal Checker
if ($dark_cal_checker->{dark_cal_present}){
    $out .= "------------  DARK CURRENT CALIBRATION CHECKS  -----------------\n\n";
    # Add a link to the comm summary if we've figured out a mission planning week name for these products
    if ($mp_top_link){
        my $url = sprintf("http://occweb.cfa.harvard.edu/occweb/web/fot_web/ops/load_reviews/%s_CommSum.php",
                          $mp_top_link->{week});
        $out .= sprintf("<A HREF=\"%s\">Comm Summary: %s</A>\n\n", $url, $mp_top_link->{week});
    }
    $out .= dark_cal_print($dark_cal_checker, $STARCHECK);
    $out .= "\n";
}

# CCD temperature plot
if ($obsid_temps){
    $out .= "------------  CCD TEMPERATURE PREDICTION -----------------\n\n";
    $out .= "<IMG SRC='$STARCHECK/ccd_temperature.png'>\n";
}


# Summary of obsids

$out .= "------------  SUMMARY OF OBSIDS -----------------\n\n";

# keep track of which load segment we're in
my $load_seg_idx = 0;

for my $obs_idx (0 .. $#obsid_id) {    
    $obsid = $obsid_id[$obs_idx];

    # mark the OBC load segment starts
    if ($load_seg_idx <= $#load_segments ){
	my $load_seg_time = date2time( $load_segments[$load_seg_idx]->{date});
	my $obsid_time = date2time($obs{$obsid}->{date});
    	if ($load_seg_time < $obsid_time){
	    $out .= "         ------  $load_segments[$load_seg_idx]->{date}   OBC Load Segment Begins     $load_segments[$load_seg_idx]->{seg_id} \n";
	    $load_seg_idx++;
	    
	}
	
    }

    $out .= sprintf "<A HREF=\"#obsid$obs{$obsid}->{obsid}\">OBSID = %5s</A>", $obs{$obsid}->{obsid};
    $out .= sprintf " at $obs{$obsid}->{date}   ";

    my $good_guide_count = $obs{$obsid}->{count_nowarn_stars}{GUI};
    my $good_acq_count = $obs{$obsid}->{count_nowarn_stars}{ACQ};

    # if Obsid is numeric, print tally info
    if ($obs{$obsid}->{obsid} =~ /^\d+$/ ){

        # minumum requirements for acq and guide for ERs and ORs
        # should be set by config...
        my $min_num_acq = ($obs{$obsid}->{obsid} > 40000 ) ? 5 : 4;
        my $min_num_gui = ($obs{$obsid}->{obsid} > 40000 ) ? 6 : 4;

        # if there is no star catalog and that's ok
        if (not ($obs{$obsid}->find_command("MP_STARCAT"))
            and $obs{$obsid}->{ok_no_starcat}){
            $min_num_acq = 0;
            $min_num_gui = 0;
        }

        # use the 'special case' ER rules from ACA-044
        if ($obs{$obsid}->{special_case_er}){
            $min_num_acq = 4;
            $min_num_gui = 4;
        }

        my $acq_font_start = ($good_acq_count < $min_num_acq) ? $red_font_start
        : $empty_font_start;
        my $gui_font_start = ($good_guide_count < $min_num_gui) ? $red_font_start
        : $empty_font_start;

        $out .= "$acq_font_start";
        $out .= sprintf "$good_acq_count clean ACQ | ";
        $out .= "$font_stop";

        $out .= "$gui_font_start";
        $out .= sprintf "$good_guide_count clean GUI | ";
        $out .= "$font_stop";
	
    }
    # if Obsid is non-numeric, print "Unknown"
    else{
	$out .= sprintf("Undefined Obsid; ER? OR?  | ");
    }


    if (@{$obs{$obsid}->{warn}}) {
	my $count_red_warn = $#{$obs{$obsid}->{warn}}+1;
	$out .= sprintf("${red_font_start}WARNINGS [%2d]${font_stop} ", $count_red_warn);
    } 
    if (@{$obs{$obsid}->{yellow_warn}}) {
	my $count_yellow_warn = $#{$obs{$obsid}->{yellow_warn}}+1;
	$out .= sprintf("${yellow_font_start}WARNINGS [%2d]${font_stop}", $count_yellow_warn);
    }
    $out .= "\n";
}

$out .= "\n";


# For each obsid, print star report, errors, and generate star plot

foreach $obsid (@obsid_id) {
    $out .= "<HR>\n";
    $out .= $obs{$obsid}->print_report();
    my $pict1 = qq{};
    my $pict2 = qq{};
    my $pict3 = qq{};
    if ($obs{$obsid}->{plot_file}){
        my $obs = $obs{$obsid}->{obsid};
        my $obsmap = $obs{$obsid}->star_image_map();
        $pict1 = qq{$obsmap <img src="$obs{$obsid}->{plot_file}" usemap=\#starmap_${obs}
						width=426 height=426 border=0> };
    }
    if ($obs{$obsid}->{plot_field_file}){
	$pict2 = qq{Star Field<BR /><img align="top" src="$obs{$obsid}->{plot_field_file}" width=231 height=231>};
    }
    if ($obs{$obsid}->{compass_file}){
	$pict3 = qq{Compass<BR /><img align="top" src="$obs{$obsid}->{compass_file}" width=154 height=154>};
    }

    $out .= "<TABLE CELLPADDING=0><TR><TD ROWSPAN=2>$pict1</TD><TD ALIGN=CENTER>$pict2</TD></TR><TR><TD ALIGN=CENTER>$pict3</TD></TR></TABLE>\n" ;
}



# Finish up and format it

$out .= '</PRE></TD></TABLE> ';

#print $out;

my $ptf = PoorTextFormat->new();

# Write make_stars file
my $make_stars = "$STARCHECK/make_stars.txt";
open (my $OUT, "> $make_stars") or die "Couldn't open $make_stars for writing\n";
foreach my $obsid (@obsid_id) {
    my $c = $obs{$obsid};
    my $format = ($c->{obsid} =~ /^[0-9]+$/) ? "%05d" : "%s";
    if ( (defined $c->{ra}) and (defined $c->{dec}) and (defined $c->{roll})){
	printf $OUT "../make_stars.pl -starcat starcat.dat.$format", $c->{obsid};
	print $OUT " -ra $c->{ra} -dec $c->{dec} -roll $c->{roll} ";
	print $OUT "-sim_z $c->{SIM_OFFSET_Z} " if ($c->{SIM_OFFSET_Z});
	print $OUT "-si $c->{SI} " if ($c->{SI});
	print $OUT "\n";
    }
}
close($OUT);

# Write the HTML

if ($par{html}) {
    open (my $OUT, "> $STARCHECK.html") or die "Couldn't open $STARCHECK.html for writing\n";
#    print $OUT $ptf->ptf2any('html', $out);
    print $OUT qq{<HTML><HEAD><script type="text/javascript" src="${STARCHECK}/overlib.js"></script></HEAD>};
    print $OUT qq{<BODY><div id="overDiv" style="position:absolute; visibility:hidden; z-index:1000;"></div>$out</BODY></HTML>};
    close $OUT;
#    open (my $DBGOUT, "> $STARCHECK.ptf");
#    print $DBGOUT $out;
#    close $DBGOUT;

    print STDERR "Wrote HTML report to $STARCHECK.html\n";

    my $guide_summ_start = 'PROCESSING SOCKET REQUESTS';
    make_annotated_file('', 'starcat.dat.', ' -ra ', $make_stars);
    make_annotated_file('', ' ID=\s+', ', ', $backstop);
    make_annotated_file($guide_summ_start, '^\s+ID:\s+', '\S\S', $guide_summ);
    make_annotated_file('', '^ ID=', ', ', $or_file) if ($or_file);
    make_annotated_file('', ' ID:\s+', '\S\S', $mm_file);
    make_annotated_file('', 'OBSID,ID=', ',', $dot_file);
    my $tlr_lines = add_obsid_to_tlr(\@bs, $tlr_file);
    make_annotated_file('', 'OBSERVATION ID\s*', '\s*\(', $tlr_file, $tlr_lines);
}

# Write the TEXT

if ($par{text}) {

    my $textout = io("${STARCHECK}.txt");

    my $te = HTML::TableExtract->new();
    $te->parse($out);

    my %table;
    foreach my $ts ($te->table_states) {
#	print "Table (", join(',', $ts->coords), "):\n";
	my $table_text = qq{};
	my ($depth, $count) = $ts->coords;
	foreach my $row ($ts->rows) {
	    $table_text .= $row->[0] . "\n" if defined $row->[0];
	}
	if ($table_text =~ /OBSID/s){
	    $table{$depth}{$count} = $table_text;
	}
    }
#    use Data::Dumper;
#    print Dumper %table;
    for my $depth ( sort {$a <=> $b} (keys %table) ){
	for my $count ( sort {$a <=> $b} (keys %{$table{$depth}})){
#	    print " $depth $count \n";
	    my $chunk =  $table{$depth}{$count};
	    chomp($chunk);
	    $chunk =~ s/\s+$/\n/;
	    $textout->print("$chunk");
	    $textout->print("==================================================================================== \n");
	}
    }

    print STDERR "Wrote text report to $STARCHECK.txt\n";

}

  
##***************************************************************************
sub dark_cal_print{
##***************************************************************************

    my $dark_cal_checker = shift;
    my $out_dir = shift;

    io("${out_dir}/dark_cal_verbose.html")->print($dark_cal_checker->print({ verbose => 1,
																			 criteria => 0,
																			 html_standalone => 1}));


    io("${out_dir}/dark_cal_super_verbose.html")->print($dark_cal_checker->print({verbose => 1,
																				  criteria => 1,
																				  html_standalone => 1}));

    my $out;
    $out .= "<A HREF=\"${out_dir}/dark_cal_verbose.html\">VERBOSE</A> ";
    $out .= "<A HREF=\"${out_dir}/dark_cal_super_verbose.html\">SUPERVERBOSE</A>\n";
    $out .= $dark_cal_checker->print({verbose => 0,
									  criteria => 0,
									  html => 0,
									  link_to => "${out_dir}/dark_cal_super_verbose.html",
								  });

    return $out;
}

##***************************************************************************
sub guess_mp_toplevel{
##***************************************************************************

    # figure out the "week" based on the path, and make a URL to point to the 
    # lookup cgi as defined in the config at paths->week_lookup

    my $arg_ref = shift;
    my $source_dir = $arg_ref->{path};
    my $config = $arg_ref->{config};

    my $lookup_cgi;
    if (defined $config->{paths}->{week_lookup}){
	$lookup_cgi = $config->{paths}->{week_lookup};
    }
    else{
	return undef;
    }


    if ($source_dir =~ /.*\/\d{4}\/(\w{3}\d{4})\/ofls(\w+)/){
	my $week = $1;
	my $rev = uc($2);
	my $weekfile = ${week} . ${rev};
	my $url = $lookup_cgi . "?week=${weekfile}";
	return { url => $url, week => $weekfile };
    
    }
    return undef;
    
    
}





##***************************************************************************
sub add_obsid_to_tlr {
##***************************************************************************
    my ($bs, $file_in) = @_;

    open(my $FILE1, $file_in) or return;
    my @lines = <$FILE1>;
    close $FILE1;

    # Cross correlate obsid command in TLR with backstop
    foreach (@lines) {
	next unless /COAOSQID \s+ ASSIGN \s OBSERVATION/x;
	my ($date) = split;
	my ($bs_obsid) = grep { $_->{date} eq $date and $_->{cmd} eq 'MP_OBSID' } @{$bs};
	next unless defined $bs_obsid;
	my %params = Ska::Parse_CM_File::parse_params($bs_obsid->{params});
	my $obsid = sprintf("%6d", $params{ID});
	s/OBSERVATION ID NUMBER/OBSERVATION ID $obsid/;
    }

    return \@lines;
}

##***************************************************************************
sub make_annotated_file {
##***************************************************************************
# $backstop   = get_file("$par{dir}/*.backstop",'backstop', 'required');
# $guide_summ = get_file("$par{dir}/mg*.sum",   'guide summary');
# $or_file    = get_file("$par{dir}/*.or",      'OR');
# $mm_file    = get_file("$par{dir}/*/mm*.sum", 'maneuver');
# $dot_file   = get_file("$par{dir}/*.dot",     'DOT', 'required');

    my ($start_rexp, $id_pre, $id_post, $file_in, $lines) = @_;

    if (not defined $lines) {
	open(my $FILE1, $file_in) or return;
	$lines = [ <$FILE1> ];
	close $FILE1;
    }

    my $obsid;
    my $start = $start_rexp ? 1 : 0;

    foreach (@{$lines}) {
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
    print $FILE2 $ptf->ptf2any('html', "\\fixed_start \n" . join('',@{$lines}));
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
			ATS_OBSID => 0,
			);

    %dot_tolerance = (ATS_DTHR  => 200.0,
		      ATS_OBSID => 1.0,
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
	next unless (defined $dot_cmd{ $dot{$obsid_index}{cmd_identifier}});

	my $cmd_identifier = $dot{$obsid_index}{cmd_identifier};
	my $dt        = $dot_time_offset{$cmd_identifier} || 0.0;
	my $tolerance = $dot_tolerance{$cmd_identifier}   || $TIME_TOLERANCE ;
	

	if ($dot_cmd{$cmd_identifier} eq $cmd ){
	    if ( abs($dot{$obsid_index}{time} + $dt - $time) < $tolerance) {
		if ($obsid_index =~ /\S0*(\S+)\d{4}/){
		    return $1; 
		    
		}
		else{
		    die "Couldn't parse obsid_index = '$obsid_index' in get_obsid()\n";
		}
	    }


	}
    }

    warning("Could not find a match in DOT for $cmd at $date\n");

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
      my $warn = ((@files == 0) ?
                  "$warning: No $name file matching $glob\n"
                  : "$warning: Found more than one file matching $glob, using none\n");
      warning($warn);
	die "\n" if ($required);
	return undef;
    } 
    $input_files{$name}=$files[0];
    print STDERR "Using $name file $files[0]\n";
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
<out>/stars_<obsid>.png.  The default is <out> = 'STARCHECK'.

=item B<-vehicle>

Use vehicle-only products and the vehicle-only ACA checklist to perform
the ACA load review processing.

=item B<-[no]plot>

Enable (or disable) generation of star/fid plots.  These plots require
the tool mp_get_agasc and the AGASC catalog online.  Default is plotting 
enabled.

=item B<-[no]html>

Enable (or disable) generation of report in HTML format.  Default is HTML enabled.

=item B<-[no]text>

Enable (or disable) generation of report in TEXT format.  Default is TEXT enabled.

=item B<-agasc <agasc>>

Specify version of agasc ( 1p4, 1p5, or 1p6 ).  Default is 1p6 .

=item B<-agasc_dir <agasc directory>>

Specify directory path to agasc.  Overrides -agasc option.

=item B<-fid_char <fid characteristics file>>

Specify file name of the fid characteristics file to use.  This must be in the SKA/data/starcheck/ directory.

=item B<-sc_data <starcheck data directory>>

Specify directory which contains starcheck data files including agasc.bad and fid characteristics.  Default is SKA/data/starcheck.

Specify YAML configuration file in starcheck data directory.  Default is SKA/data/starcheck/characteristics.yaml

=item B<-config_file <config file>>

Specify YAML configuration file in starcheck data directory.  Default is SKA/data/starcheck/characteristics.yaml

=back

=head1 DESCRIPTION

B<Starcheck.pl> checks for problems in ACA star catalogs produced by the 
OFLS, relying primarily on the output of Backstop.  In addition,
if a guide star summary file is available, that information is
used to determine star/fid IDs and magnitudes.  A report summarizing
the star catalogs is generated in HTML and/or plain text formats.

The output reports are named <out>.html, <out>.txt, and star plots are
named <out>/stars_<obsid>.png.  If not specified on the command line,
<out> is 'STARCHECK'.

Starcheck.pl looks in <dir> for a single Backstop file with the name '*.backstop'.
Zero matches or multiple matches of this name results in a fatal error.
The guide star summary file is assumed to be named 'mg*.sum'.  If no file 
is found, a warning is produced but processing continues.  Multiple matches
results in a fatal error, however.


=head1 AUTHOR

Tom Aldcroft ( taldcroft@cfa.harvard.edu )

=cut

