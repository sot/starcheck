
TASK = starcheck

include /proj/sot/ska/include/Makefile.FLIGHT

ICXC_STARCHECK = "https://icxc.harvard.edu/mta/ASPECT/tool_doc/starcheck_php_doc_tmp"
ICXC_DOC_FOLDER = "/proj/sot/ska/doc/starcheck_php_doc_tmp/"
RELATED_LIB = StarcheckParser.pm
BIN = starcheck.pl 
SHARE = starcheck_obsid.pl parse_cm_file.pl figure_of_merit.pl
DATA = ACABadPixels agasc.bad  fid_CHARACTERIS_JUL01
DOC_PHP = aca_load_review_cl.php
DOC_HTML = aca_load_review_cl.html
BADPIXELS = ACABadPixels.new
TEST_DEPS = data/acq_stats/bad_acq_stars.rdb

AUG0104A:
	ln -s /data/mpcrit1/mplogs/2004/AUG0104/oflsa AUG0104A

test: check_install AUG0104A install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck.pl -agasc 1p5 -dir AUG0104A -out test


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


starcheck_parser: $(RELATED_LIB)
	mkdir -p $(INSTALL_PERLLIB)
	rsync --times --cvs-exclude $(RELATED_LIB) $(INSTALL_PERLLIB)/

install: $(TEST_DEPS)
ifdef DOC_PHP
	mkdir -p $(ICXC_DOC_FOLDER)
	mkdir -p $(INSTALL_DOC)
	if [ -r $(INSTALL_DOC)/$(DOC_HTML) ] ; then rm $(INSTALL_DOC)/$(DOC_HTML); fi
	rsync --times --cvs-exclude $(DOC_PHP) $(ICXC_DOC_FOLDER)/
	wget $(ICXC_STARCHECK)/$(DOC_PHP) -O $(INSTALL_DOC)/$(DOC_HTML)
endif
ifdef BIN
	mkdir -p $(INSTALL_BIN)
	rsync --times --cvs-exclude $(BIN) $(INSTALL_BIN)/
	pod2html starcheck.pl > $(INSTALL_DOC)/starcheck.html
endif
ifdef DATA
	mkdir -p $(INSTALL_DATA)
	rsync --times --cvs-exclude $(DATA) $(INSTALL_DATA)/
endif
ifdef SHARE
	mkdir -p $(INSTALL_SHARE)
	rsync --times --cvs-exclude $(SHARE) $(INSTALL_SHARE)/
endif
ifdef RELATED_LIB
	mkdir -p $(INSTALL_PERLLIB)
	rsync --times --cvs-exclude $(RELATED_LIB) $(INSTALL_PERLLIB)/
endif
	mkdir -p $(SKA)/ops/Chex
 
