TASK = starcheck

include /proj/sot/ska/include/Makefile.FLIGHT

BIN = starcheck.pl 
SHARE = starcheck_obsid.pl parse_cm_file.pl figure_of_merit.pl
DATA = ACABadPixels agasc.bad  fid_CHARACTERIS_JUL01
DOC = aca_load_review_cl.html
BADPIXELS = ACABadPixels.new
TEST_DEPS = data/acq_stats/bad_acq_stars.rdb

test: check_install AUG0104A install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck.pl -agasc 1p5 -dir AUG0104A -out test

AUG0104A:
	ln -s /data/mpcrit1/mplogs/2004/AUG0104/oflsa AUG0104A

MAR0705B:
	ln -s /data/mpcrit1/mplogs/2005/MAR0705/oflsb MAR0705B

OCT1005B:
	ln -s /data/mpcrit1/mplogs/2005/OCT1005/oflsb OCT1005B

NOV0705B:
	ln -s /data/mpcrit1/mplogs/2005/NOV0705/oflsb NOV0705B

test_mar: check_install MAR0705B install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck.pl -dir MAR0705B -out test

test_oct: check_install OCT1005B install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck.pl -dir OCT1005B -out test

test_nov: check_install NOV0705B install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck.pl -dir NOV0705B -out test

regress: $(BIN) $(SHARE) $(DATA)
	if [ -r regress_diffs ] ; then rm regress_diffs ; fi
	if [ -r regress_log ] ; then rm regress_log ; fi
	if [ -d regress ] ; then rm -r regress ; fi
	run_regress

test_badpixels: check_install $(BIN) $(SHARE) $(DATA) $(BADPIXELS) install
	if [ -r test_badpix.diff ] ; then rm test_badpix.diff ; fi
	if [ -r test_oldbadpix.html ] ; then rm test_oldbadpix.html ; fi          
	if [ -r test_oldbadpix.txt ] ; then rm test_oldbadpix.txt ; fi          
	$(INSTALL_BIN)/starcheck.pl -agasc 1p5 -dir AUG0104A -out test_oldbadpix
	rsync --times --cvs-exclude $(BADPIXELS) $(INSTALL_DATA)/
	if [ -r test_newbadpix.html ] ; then rm test_newbadpix.html ; fi          
	if [ -r test_newbadpix.txt ] ; then rm test_newbadpix.txt ; fi          
	$(INSTALL_BIN)/starcheck.pl -agasc 1p5 -dir AUG0104A -out test_newbadpix
	if [ -r test_badpix.diff ] ; then rm test_badpix.diff ; fi
	diff test_newbadpix.txt test_oldbadpix.txt > test_badpix.diff
	rsync --times --cvs-exclude $(DATA) $(INSTALL_DATA)/

install: $(TEST_DEPS)
ifdef DOC
	mkdir -p $(INSTALL_DOC)
	rsync --times --cvs-exclude $(DOC) $(INSTALL_DOC)/
endif
ifdef BIN
	mkdir -p $(INSTALL_BIN)
	rsync --times --cvs-exclude $(BIN) $(INSTALL_BIN)/
endif
ifdef DATA
	mkdir -p $(INSTALL_DATA)
	rsync --times --cvs-exclude $(DATA) $(INSTALL_DATA)/
endif
ifdef SHARE
	mkdir -p $(INSTALL_SHARE)
	rsync --times --cvs-exclude $(SHARE) $(INSTALL_SHARE)/
endif
	mkdir -p $(SKA)/ops/Chex
 
