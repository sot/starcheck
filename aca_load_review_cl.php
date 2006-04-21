<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">
<?php $VERSION= '$Id$'; 
      preg_match("/.*aca_load_review_cl.php,v\s+(\S+)\s+(\S+)/", $VERSION, $matches);
      $cvs_version = $matches[1];
      $cvs_date = $matches[2];
?>

<HTML>
<!-- Please make all changes to the PHP version of this file in starcheck CVS -->
<?php echo "<!-- CVS INFO: $VERSION  -->" ?>

<HEAD>
	<TITLE>ACA Load Review Checklist</TITLE>
</HEAD>
<BODY>

<H2 ALIGN=CENTER>ACA Load Review Checklist</H2>
<P><BR>Date: <?php echo $cvs_date ?> <BR>Author: E. Martin, S. Bucher, T. Aldcroft, J. Connelly</P>
<P>The following software and data files are installed in the HEAD
LAN environment.</P>
<P><B>Software Packages</B></P>
<UL TYPE=DISC>
	<LI><P>starcheck 
	</P>
	<LI><P>SAUSAGE 
	</P>
	<LI><P>make_stars 
	</P>
</UL>
<P>&nbsp;</P>
<P><B>Load Input Files</B></P>
<UL TYPE=DISC>
	<LI><P>Backstop: ./CRddd.hhvv.backstop 
	</P>
	<LI><P>Guide Summary: ./mps/mgddd:hhvv.sum 
	</P>
	<LI><P>OR: ./mps/or/MMMddyy_v.or 
	</P>
	<LI><P>Maneuver: ./mps/mmddd:hhvv.sum 
	</P>
	<LI><P>Dot: ./mps/mdddd:hhvv.dot 
	</P>
	<UL>
		<LI><P>starcheck confirms that the DOT
		has been modified by SAUSAGE</P>
	</UL>
	<LI><P>Mech Check: ./output/TEST_mechcheck.txt 
	</P>
	<LI><P>SOE: ./mps/soe/msddd:hhvv.soe 
	</P>
	<LI><P>Fidsel: ./History/FIDSEL.txt
	</P>
	<LI><P>Dither: ./History/DITHER.txt
	</P>
	<LI><P>Maneuver Error: ./output/MMMddyyv_ManErr.txt 
	</P>
	<LI><P>Processing Summ: ./mps/msddd:hhvv.sum
	</P>
</UL>
<P><B>Starcheck's Data Files</B></P>
<UL TYPE=DISC>
	<LI><P>ODB File: $SKA/data/starcheck/fid_CHARACTERIS_JUL01
	</P> 
	<LI><P>Bad Agasc List: $SKA/data/starcheck/agasc.bad
	</P>
	<LI><P>Bad Pixel File: $SKA/data/starcheck/ACABadPixels
	</P>
	<LI><P>Acq Stats RDB: $SKA/data/starcheck/bad_acq_stars.rdb
	</P>
</UL>
<P>&nbsp;</P>
<P><B>Output Files</B></P>
<UL TYPE=DISC>
	<LI><P>/data/mpcrit1/mplogs/YYYY/MMMDDYY/starcheck.html
		</P>
	<LI><P>/data/mpcrit1/mplogs/YYYY/MMMDDYY/starcheck.txt
		</P>
	<LI><P>/data/mpcrit1/mplogs/YYYY/MMMDDYY/starcheck/
		</P>
	<UL TYPE=CIRCLE>
		<LI><P>stars_OBSID.gif 
		</P>
		<LI><P>MMMDDYY_v.or.html 
		</P>
		<LI><P>CRddd:hhvv.backstop.html 
		</P>
		<LI><P>make_stars.txt 
		</P>
		<LI><P>make_stars.txt.html 
		</P>
		<LI><P>mdddd:hhvv.dot.html 
		</P>
		<LI><P>mgddd:hhvv.sum.html 
		</P>
		<LI><P>mmddd:hhvv.sum.html 
		</P>
	</UL>
</UL>
<P>&nbsp;</P>
<P><B>Instructions on how to use Software</B></P>
<UL TYPE=DISC>
	<LI><P>http://asc.harvard.edu/mta/ASPECT/run_starcheck.html 
	</P>
</UL>
<P>&nbsp;</P>

<?php $aca_count = 0 ?>

<H1>Checks</H1>
<P>&nbsp;</P>
<TABLE WIDTH=854 BORDER=1 CELLPADDING=2 CELLSPACING=3>
	<COL WIDTH=52>
	<COL WIDTH=127>
	<COL WIDTH=224>
	<COL WIDTH=36>
	<COL WIDTH=36>
	<COL WIDTH=36>
	<COL WIDTH=39>
	<COL WIDTH=92>
	<COL WIDTH=144>
	<TR>
		<TD WIDTH=52>
			<P><B>ID</B></P>
		</TD>
		<TD WIDTH=127>
			<P><B>Category</B></P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P><B>Check Performed</B></P>
		</TD>
		<TD WIDTH=92>
			<P><B>CARD</B></P>
		</TD>
		<TD WIDTH=144>
			<P><B>Implications</B></P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Pointing</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Verify that the backstop
			pointing and OR pointing agree to within 1 arcsec</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced science quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >SIM TT&nbsp;Z-position</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Matching SIM&nbsp;Translation
			Table&nbsp;Z-positions in backstop and OR list</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Fiducial lights not tracked</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>

		</TD>
		<TD WIDTH=127>
			<P >Dither</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Dither commanding in OR and
			backstop match</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced science quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Dither</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Dither does not change state
			during an observation (after star acquisition)</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced science quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Star catalog</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Star catalog exists unless
			observation is done in gyro hold</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Possible Bright Star Hold</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Star catalog</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >#AS = maximum possible &lt;=
			8</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Possible Bright Star Hold</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Star catalog</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >#FL + #GS + #MW = maximum
			possible &lt;= 8</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD ROWSPAN=5 WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD ROWSPAN=5 WIDTH=127>
			<P>Star catalog</P>
		</TD>
		<TD WIDTH=224>
			<P><I>Observation Request (OR)</I></P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>#FL</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>#AS</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>#GS</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>#MW</P>
		</TD>
		<TD ROWSPAN=5 WIDTH=92 ALIGN=CENTER>
			<P>n/a</P>
		</TD>
		<TD ROWSPAN=5 WIDTH=144>
			<P>AS:</P>
			<P>Possible Bright Star Hold</P>
			<P>&nbsp;</P>
			<P>GS:</P>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=224>
			<P>Requirements</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>&lt;=3</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>&gt;=4</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>&gt;=4</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>&lt;=1</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=224>
			<P>Standard configuration</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>3</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>4-8</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>5</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>0</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=224>
			<P>Alternate configuration (monitor window)</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>3</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>4-8</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>4</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>1</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=224>
			<P>Alternate configuration (6 guide stars)</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>2</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>4-8</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>6</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>0</P>
		</TD>
	</TR>
	<TR>
		<TD ROWSPAN=5 WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD ROWSPAN=5 WIDTH=127>
			<P>Star catalog</P>
		</TD>
		<TD WIDTH=224>
			<P><I>Engineering Request (ER)</I></P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>#FL</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>#AS</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>#GS</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>#MW</P>
		</TD>
		<TD ROWSPAN=5 WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD ROWSPAN=5 WIDTH=144>
			<P>AS:</P>
			<P>Possible Bright Star Hold</P>
			<P>&nbsp;</P>
			<P>GS:</P>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=224>
			<P>Requirements</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>0</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>&gt;=5</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>&gt;=6</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>&lt;=2</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=224>
			<P>Standard configuration</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>0</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>5-8</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>6-8</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>0</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=224>
			<P>Alternate configuration (1 monitor window)</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>0</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>5-8</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>6-7</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>1</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=224>
			<P>Alternate configuration (2 monitor windows)</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>0</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>5-8</P>
		</TD>
		<TD WIDTH=36 VALIGN=TOP>
			<P ALIGN=CENTER>6</P>
		</TD>
		<TD WIDTH=39 VALIGN=TOP>
			<P ALIGN=CENTER>2</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Magnitude limit</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >AS: 5.8 - 10.3 (or fainter,
			if needed to find stars)</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Possible Bright Star Hold</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Magnitude limit</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >GS: 6.0 - 10.3 (or fainter,
			if needed to find stars)</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Magnitude limit</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >FL: 6.8 - 7.2</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >CCD quadrant inner boundary
			exclusion zones</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >AS: n/a</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Possible Bright Star Hold</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >CCD quadrant inner boundary
			exclusion zones</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >GS: (dither + 20) arcsec</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >CCD quadrant inner boundary
			exclusion zones</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >FL: 25 arcsec</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Search box size</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >AS: HW (arcsec) &gt;= MU</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Possible Bright Star Hold</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Search box size</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >GS: HW (arcsec) = 25</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Search box size</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >FL: HW (arcsec) = 25</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Search box size</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Search box has &lt;= 200
			arcsec half-width</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Failure to track correct star</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >ACA field-of-view limits</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >AS: Y,Z at least (HW +
			dither) inside field-of-view limits</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Possible Bright Star Hold</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >ACA field-of-view limits</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >GS: Y,Z at least (HW +
			dither) inside field-of-view limits</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >ACA field-of-view limits</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >FL: Z at least HW inside
			field-of-view limits</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Spoiler stars</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >AS: spoiled by another
			object brighter than mag(AS) + 0.2, that lies closer than MU
			arcsec to the AS search box</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Possible Bright Star Hold</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Spoiler stars</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >GS: spoiled by another
			object brighter than mag(GS) + 0.2, that lies closer than MU
			arcsec to the GS search box</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Spoiler stars</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >FL:&nbsp;spoiled by another
			object brighter than mag(FL) + 4.0, that lies closer than (dither
			+&nbsp;25) arcsec to the FL</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Bad pixels</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >No guide star is within
			(dither + 25) arcsec (Y or Z) of a known bad pixel</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Common column</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Spoiler within 50 arcsec,
			spoiler is 4.5 mag brighter than star, and spoiler is located
			between star and readout</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Readout sizes</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Acquisition star and guide
			star readout sizes are all 6x6 for ORs</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
			<P>Ground processing difficulty</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Readout sizes</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Acquisition star and guide
			star readout sizes are all 8x8 for ERs</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>No ACA Header 3 telemetry</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Readout sizes</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Fiducial light readout sizes
			are all 8x8</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>No ACA Header 3 telemetry</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Readout sizes</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Monitor window readout sizes
			are all 8x8</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced science quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Bad AGASC&nbsp;IDs</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >No selected acquisition
			star&nbsp;or guide star&nbsp;to be in the bad AGASC&nbsp;ID&nbsp;list</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Failure to track star</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >AGASC requirements</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Stars have a measured AGASC
			magnitude and magnitude error</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Failure to track star</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Marginal stars</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Guide star has valid color
			information (B-V != 0.700)</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Failure to track star</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Fiducial lights</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Verify FLs turned on via
			FIDSEL statement match expected FLs in star catalog</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Fiducial lights</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Commanded fiducial light
			position matches expected position</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Failure to track</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Monitor commanding</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Monitor window (if #MW = 1)
			is in image slot #7</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Ground processing difficulty</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Monitor commanding</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Monitor window is within 2.5
			arcsec of the OR specification</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced science quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Monitor commanding</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Monitor window is not set to
			convert-to-track</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Reduced aspect quality</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Monitor commanding</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Designated Tracked Star
			(DTS) image slot must contain a guide star</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Failure to track</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Monitor commanding</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Dither is disabled and
			enabled with correct timing</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>n/a</P>
		</TD>
		<TD WIDTH=144>
			<P>Failure to track</P>
		</TD>
	</TR>
	<TR>
		<TD WIDTH=52>
			<P>ACA-<?php 
			$aca_count_string = sprintf("%03d",$aca_count);
			echo $aca_count_string;  
			$aca_count++;
			?>
			</P>
		</TD>
		<TD WIDTH=127>
			<P >Magnitude</P>
		</TD>
		<TD COLSPAN=5 WIDTH=400>
			<P >Slot MAXMAG (faint limit) -
			star MAG &gt;= 1.4 
			</P>
		</TD>
		<TD WIDTH=92>
			<P ALIGN=CENTER>N/a</P>
		</TD>
		<TD WIDTH=144>
			<P>AS: Possible Bright Star Hold, GS: Reduced aspect quality</P>
		</TD>
	</TR>
</TABLE>
<P><B>Key</B></P>
<TABLE BORDER=0 CELLPADDING=0 CELLSPACING=2>
	<TR>
		<TD>
			<P>AS = acquisition star</P>
		</TD>
	</TR>
	<TR>
		<TD>
			<P>GS = guide star</P>
		</TD>
	</TR>
	<TR>
		<TD>
			<P>FL = fiducial light</P>
		</TD>
	</TR>
	<TR>
		<TD>
			<P>#AS = number of acquisition stars</P>
		</TD>
	</TR>
	<TR>
		<TD>
			<P>#GS = number of guide stars</P>
		</TD>
	</TR>
	<TR>
		<TD>
			<P>#FL = number of fiducial lights</P>
		</TD>
	</TR>
	<TR>
		<TD>
			<P>#MW = number of monitor windows</P>
		</TD>
	</TR>
	<TR>
		<TD>
			<P>HW = search box single-axis half-width</P>
		</TD>
	</TR>
	<TR>
		<TD>
			<P>MU = maneuver uncertainty (arcsec)</P>
		</TD>
	</TR>
</TABLE>
<HR SIZE=1>
<HR SIZE=1>
</BODY>
</HTML>
