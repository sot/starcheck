========================= 
ACA Load Review Checklist
========================= 

.. Please make all changes to the reStructured Text version of this
   file in the starcheck git project


Date: 2024-Jan-17

Version: 3.10

Author: E. Martin, S. Hurley, T. Aldcroft, J. Connelly, J. Gonzalez

The following software and data files are installed in the HEAD LAN
environment.

Software Packages
-----------------
 
  - starcheck

  - SAUSAGE

Load Input Files
----------------

  - Backstop: 

     * Observing: ./CRddd.hhvv.backstop

     * Vehicle: ./vehicle/VRddd.hhvv.backstop

  - Guide Summary: ./mps/mgddd:hhvv.sum

  - OR: ./mps/or/MMMddyy_v.or

  - Maneuver: ./mps/mmddd:hhvv.sum

  - Dot: ./mps/mdddd:hhvv.dot

      *  (starcheck confirms that the DOT has been modified by SAUSAGE)

  - Mech Check: 

      * Observing: ./output/TEST_mechcheck.txt

      * Vehicle: ./vehicle/output/V_TEST_mechcheck.txt

  - Fidsel: ./History/FIDSEL.txt

  - Dither: ./History/DITHER.txt

  - Radmon: ./History/RADMON.txt

  - Processing Summ: ./mps/msddd:hhvv.sum

  - Timeline Report:

      * Observing: ./CRddd_hhvv.tlr

      * Vehicle: ./vehicle/VRddd_hhvv.tlr

  - Characteristics file (not required if dynamic aimpoint file present):

      * ./mps/ode/characteristics/L_*_CHARACTERIS_DDMMMYY

      or

      * ./mps/ode/characteristics/CHARACTERIS_DDMMMYY

  - Dynamic aimpoint offset file (required after 21-Aug-2016):

      * ./output/\*_dynamical_offsets.txt

Starcheck's Data Files
----------------------

  - ODB File: $SKA/data/starcheck/fid_CHARACTERIS_FEB07
 
  - Bad Agasc List: $SKA/data/starcheck/agasc.bad
 
  - Bad Pixel File: $SKA/data/starcheck/ACABadPixels
 
  - Acq Stats RDB: $SKA/data/starcheck/bad_acq_stars.rdb


Output Files
------------

Observing
~~~~~~~~~  

  - ./starcheck.html

  - ./starcheck.txt

  - ./starcheck/
 
      - stars_OBSID.png
 
      - MMMDDYY_v.or.html
 
      - CRddd:hhvv.backstop.html

      - CRddd_hhvv.tlr.html
 
      - mdddd:hhvv.dot.html
 
      - mgddd:hhvv.sum.html
 
      - mmddd:hhvv.sum.html

Vehicle
~~~~~~~

  - ./vehicle/diff.txt

  - ./vehicle/starcheck.html
 
  - ./vehicle/starcheck.txt

  - ./vehicle/starcheck/
 
      - stars_OBSID.png
 
      - MMMDDYY_v.or.html
 
      - VRddd:hhvv.backstop.html

      - VRddd_hhvv.tlr.html
 
      - mdddd:hhvv.dot.html
 
      - mgddd:hhvv.sum.html
 
      - mmddd:hhvv.sum.html



Instructions on how to use Software
-----------------------------------

  - http://cxc.harvard.edu/mta/ASPECT/run_starcheck.html



Checks
------

+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ID     |Category          |V|C|Check Performed                            |CARD|Implications    |
+=======+==================+=+=+===========================================+====+================+
|ACA-000|Pointing          |X|X|Verify that the backstop pointing and OR   |n/a |Reduced science |
|       |                  | | |pointing agree to within 1 arcsec          |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-001|SIM TT Z-position | |X|Matching SIM Translation Table Z-positions |n/a |Fiducial lights |
|       |                  | | |in backstop and OR list                    |    |not tracked     |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-002|Dither            |X|X|Dither commanding in OR and backstop match |n/a |Reduced science |
|       |                  | | |                                           |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-003|Dither            |X|X|Dither does not change state during an     |n/a |Reduced science |
|       |                  | | |observation (after star acquisition)       |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-004|Star catalog      |X|X|Star catalog exists unless observation is  |n/a |Possible Bright |
|       |                  | | |done in gyro hold                          |    |Star Hold       |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-005|Star catalog      |X|X|#AS = maximum possible <= 8                |n/a |Possible Bright |
|       |                  | | |                                           |    |Star Hold       |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-006|Star catalog      |X|X|#FL + #GS + #MW = maximum possible <= 8    |n/a |Reduced aspect  |
|       |                  | | |                                           |    |quality         |
+-------+------------------+-+-+--------------------+------+-----+----+----+----+----------------+
|       |                  |X|X|Observation Request | #FL  | #AS |#GS |#MW |    |                |
|       |                  | | |(OR)                |      |     |    |    |    |                |
|       |                  | | +--------------------+------+-----+----+----+    |AS:             |
|       |                  | | |Requirements        | <=3  | >=4 |>=4 |<=1 |    |                |
|       |                  | | +--------------------+------+-----+----+----+    |Possible Bright |
|       |                  | | |Standard            |  3   | 4-8 | 5  | 0  |    |Star Hold       |
|       |                  | | |configuration       |      |     |    |    |    |                |
|ACA-007|Star catalog      | | +--------------------+------+-----+----+----+n/a |                |
|       |                  | | |Alternate           |  3   | 4-8 | 4  | 1  |    |                |
|       |                  | | |configuration       |      |     |    |    |    |GS:             |
|       |                  | | |(monitor window)    |      |     |    |    |    |                |
|       |                  | | +--------------------+------+-----+----+----+    |Reduced aspect  |
|       |                  | | |Alternate           |  2   | 4-8 | 6  | 0  |    |quality         |
|       |                  | | |configuration (6    |      |     |    |    |    |                |
|       |                  | | |guide stars)        |      |     |    |    |    |                |
+-------+------------------+-+-+--------------------+------+-----+----+----+----+----------------+
|       |                  |X|X|Engineering Request | #FL  | #AS |#GS |#MW |    |                |
|       |                  | | |(ER)                |      |     |    |    |    |                |
|       |                  | | +--------------------+------+-----+----+----+    |AS:             |
|       |                  | | |Requirements        |  0   | >=5 |>=6 |<=2 |    |                |
|       |                  | | +--------------------+------+-----+----+----+    |Possible Bright |
|       |                  | | |Standard            |  0   | 5-8 |6-8 | 0  |    |Star Hold       |
|       |                  | | |configuration       |      |     |    |    |    |                |
|ACA-008|Star catalog      | | +--------------------+------+-----+----+----+n/a |                |
|       |                  | | |Alternate           |  0   | 5-8 |6-7 | 1  |    |                |
|       |                  | | |configuration (1    |      |     |    |    |    |GS:             |
|       |                  | | |monitor window)     |      |     |    |    |    |                |
|       |                  | | +--------------------+------+-----+----+----+    |Reduced aspect  |
|       |                  | | |Alternate           |  0   | 5-8 | 6  | 2  |    |quality         |
|       |                  | | |configuration (2    |      |     |    |    |    |                |
|       |                  | | |monitor windows)    |      |     |    |    |    |                |
+-------+------------------+-+-+--------------------+------+-----+----+----+----+----------------+
|ACA-009|Magnitude limit   |X|X|AS: 5.2 - 10.3 (or fainter, if needed to   |n/a |Possible Bright |
|       |                  | | |find stars)                                |    |Star Hold       |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-010|Magnitude limit   |X|X|GS: 5.2 - 10.3 (or fainter, if needed to   |n/a |Reduced aspect  |
|       |                  | | |find stars)                                |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-011|Magnitude limit   |X|X|FL: 6.8 - 7.2                              |n/a |Reduced aspect  |
|       |                  | | |                                           |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-015|Search box size   |X|X|AS: Half-width (arcsec)                    |n/a |Possible Bright |
|       |                  | | |       >= maneuver uncertainty             |    |Star Hold       |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-016|Search box size   |X|X|GS: Half-width (arcsec) = 25               |n/a |Reduced aspect  |
|       |                  | | |                                           |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-017|Search box size   |X|X|FL: Half-width (arcsec) = 25               |n/a |Reduced aspect  |
|       |                  | | |                                           |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-018|Search box size   |X|X|Search box has <= 200 arcsec half-width    |n/a |Failure to track|
|       |                  | | |                                           |    |correct star    |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-019|ACA field-of-view |X|X|AS: Y,Z at least (half-width + dither)     |n/a |Possible Bright |
|       |limits            | | |inside field-of-view limits                |    |Star Hold       |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-020|ACA field-of-view |X|X|GS: Y,Z at least (half-width + dither)     |n/a |Reduced aspect  |
|       |limits            | | |inside field-of-view limits                |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-021|ACA field-of-view |X|X|FL: Z at least half-width inside           |n/a |Reduced aspect  |
|       |limits            | | |field-of-view limits                       |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|       |                  | | |AS: Impact of spoilers on acquisition      |    |                |
|       |                  | | |probability is calculated in proseco.      |    |                |
|ACA-022|Spoiler stars     |X|X|Previously this was handled as a red warn  |n/a |Possible Bright |
|       |                  | | |for AS spoiled by another object brighter  |    |Star Hold       |
|       |                  | | |than mag(AS) + 0.2, that lies closer than  |    |                |
|       |                  | | |maneuver uncertainty to the AS search box. |    |                |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|       |                  |X|X|GS: spoiled by another object brighter than|    |Reduced aspect  |
|ACA-023|Spoiler stars     | | |mag(GS) + 0.2, that lies closer than       |n/a |quality         |
|       |                  | | |maneuver uncertainty to the GS search box  |    |                |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|       |                  | |X|FL: spoiled by another object brighter than|    |Reduced aspect  |
|ACA-024|Spoiler stars     | | |mag(FL) + 4.0, that lies closer than       |n/a |quality         |
|       |                  | | |(dither + 25) arcsec to the FL             |    |                |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-025|Bad pixels        |X|X|No guide star is within (dither + 25)      |n/a |Reduced aspect  |
|       |                  | | |arcsec (Y or Z) of a known bad pixel       |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|       |                  |X|X|Spoiler within 50 arcsec, spoiler is 4.5   |    |Reduced aspect  |
|ACA-026|Common column     | | |mag brighter than star, and spoiler is     |n/a |quality         |
|       |                  | | |located between star and readout           |    |                |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|       |                  |X|X|                                           |    |Reduced aspect  |
|       |                  | | |                                           |    |quality         |
|ACA-027|Readout sizes     | | |Acquisition star and guide star readout    |n/a |                |
|       |                  | | |sizes are all 6x6 or 8x8 for ORs           |    |Ground          |
|       |                  | | |                                           |    |processing      |
|       |                  | | |                                           |    |difficulty      |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-028|Readout sizes     |X|X|Acquisition star and guide star readout    |n/a |No ACA Header 3 |
|       |                  | | |sizes are all 8x8 for ERs                  |    |telemetry       |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-029|Readout sizes     |X|X|Fiducial light readout sizes are all 8x8   |n/a |No ACA Header 3 |
|       |                  | | |                                           |    |telemetry       |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-030|Readout sizes     |X|X|Monitor window readout sizes are all 8x8   |n/a |Reduced science |
|       |                  | | |                                           |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-031|Bad AGASC IDs     |X|X|No selected acquisition star or guide      |n/a |Failure to track|
|       |                  | | |star to be in the bad AGASC ID list        |    |star            |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-032|AGASC requirements|X|X|Stars have a measured AGASC magnitude and  |n/a |Failure to track|
|       |                  | | |magnitude error                            |    |star            |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-033|Marginal stars    |X|X|Guide star has valid color information (B-V|n/a |Failure to track|
|       |                  | | |!= 0.700)                                  |    |star            |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-034|Fiducial lights   | |X|Verify FLs turned on via FIDSEL statement  |n/a |Reduced aspect  |
|       |                  | | |match expected FLs in star catalog         |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-035|Fiducial lights   | |X|Commanded fiducial light position matches  |n/a |Failure to track|
|       |                  | | |expected position                          |    |                |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|       |                  |X|X|Monitor window (if #MW = 1) is in image    |    |Ground          |
|ACA-036|Monitor commanding| | |slot #7                                    |n/a |processing      |
|       |                  | | |                                           |    |difficulty      |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-037|Monitor commanding|X|X|Monitor window is within 2.5 arcsec of the |n/a |Reduced science |
|       |                  | | |OR specification                           |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-038|Monitor commanding|X|X|Monitor window is not set to               |n/a |Reduced aspect  |
|       |                  | | |convert-to-track                           |    |quality         |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-039|Monitor commanding|X|X|Designated Tracked Star (DTS) image slot   |n/a |Failure to track|
|       |                  | | |must contain a guide star                  |    |                |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-040|Monitor commanding|X|X|Dither is disabled and enabled with correct|n/a |Failure to track|
|       |                  | | |timing                                     |    |                |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|       |                  |X|X|                                           |    |AS: Reduced     |
|       |                  | | |                                           |    |acq probability |
|       |                  | | |                                           |    |of star         |
|ACA-041|Magnitude         | | |Slot MAXMAG (faint limit) - star MAG >= 0.3|n/a |GS: Increased   |
|       |                  | | |                                           |    |risk of loss of |
|       |                  | | |                                           |    |track of star   |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-042|AGASC requirements|X|X|An AGASC star exists within ID_DIST_LIMIT  |n/a |Failure to track|
|       |                  | | |(1.5as) of the center of each search box   |    |star            |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-043|AGASC requirements|X|X|The assigned AGASC stars exist and are at  |n/a |Failure to track|
|       |                  | | |the correct YAG and ZAG                    |    |star            |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-045|Dark Current      |X|X|Check dark current calibration             |n/a |Incomplete      |
|       |Commanding        | | |commanding if present                      |    |calibration     |
|       |                  | | |                                           |    |data            |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-046|Magnitude         |X|X|Perigee catalogs have 3 or more GS         |n/a |Possible Bright |
|       |                  | | |magnitude 9.0 or brighter                  |    |Star Hold; NSM  |
|       |                  | | |                                           |    |safing action   |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
|ACA-048|Pointing          |X|X|Confirm that PCAD attitudes match expected |n/a |Reduced science |
|       |                  | | |values based on target coordinates, target |    |quality         |
|       |                  | | |offsets, and ODB_SI_ALIGN values           |    |                |
+-------+------------------+-+-+-------------------------------------------+----+----------------+
                           
                           
                           
Key                        
---                        
                           
AS                         
  acquisition star         
                           
GS                         
  guide star               
                           
FL                         
  fiducial light           
                           
#AS                        
  number of acquisition stars
                           
#GS                        
  number of guide stars    
                           
#FL                        
  number of fiducial lights
                           
#MW                        
  number of monitor windows
