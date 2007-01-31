
TASK = starcheck
PERLTASK = Ska/Starcheck
PERLGEN = Ska/

include /proj/sot/ska/include/Makefile.FLIGHT

FID_CHARACTERISTICS = fid_CHARACTERIS_JAN07
FID_LINK_NAME = fid_CHARACTERISTICS

ICXC_STARCHECK = "https://icxc.harvard.edu/mta/ASPECT/tool_doc/starcheck_php_doc_tmp"
ICXC_DOC_FOLDER = "/proj/sot/ska/doc/starcheck_php_doc_tmp/"
RELATED_LIB = StarcheckParser.pm
BIN = starcheck.pl 
GEN_LIB = Parse_CM_File.pm
LIB = Obsid.pm FigureOfMerit.pm
DATA = ACABadPixels agasc.bad fid_CHARACTERIS_JUL01 $(FID_CHARACTERISTICS)
DOC_PHP = aca_load_review_cl.php
DOC_HTML = aca_load_review_cl.html
BADPIXELS = ACABadPixels.new
TEST_DEPS = data/acq_stats/bad_acq_stars.rdb


#AUG0104A:
#	ln -s /data/mpcrit1/mplogs/2004/AUG0104/oflsa AUG0104A


#JAN2104A:
#	ln -s /data/mpcrit1/mplogs/2004/JAN2104/oflsa/ JAN2104A


MAR0104B:
	ln -s /data/mpcrit1/mplogs/2004/MAR0104/oflsb MAR0104B

test: check_install MAR0104B install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck.pl -fid_char="fid_CHARACTERIS_JUL01" -dir MAR0104B -out test


regress: $(BIN) $(LIB) $(DATA)
	if [ -r regress_diffs ] ; then rm regress_diffs ; fi
	if [ -r regress_log ] ; then rm regress_log ; fi
	if [ -d regress ] ; then rm -r regress ; fi
	run_regress

test_badpixels: check_install AUG0104A $(BIN) $(LIB) $(DATA) $(BADPIXELS) install
	if [ -r test_badpix.diff ] ; then rm test_badpix.diff ; fi
	if [ -r test_oldbadpix.html ] ; then rm test_oldbadpix.html ; fi          
	if [ -r test_oldbadpix.txt ] ; then rm test_oldbadpix.txt ; fi          
	$(INSTALL_BIN)/starcheck.pl -agasc 1p5 -dir AUG0104A -out test_oldbadpix
	rsync --times --cvs-exclude $(BADPIXELS) $(INSTALL_DATA)/
	if [ -r test_newbadpix.html ] ; then rm test_newbadpix.html ; fi          
	if [ -r test_newbadpix.txt ] ; then rm test_newbadpix.txt ; fi          
	$(INSTALL_BIN)/starcheck.pl -agasc 1p5 -dir AUG0104A -out test_newbadpix
	if [ -r test_badpix.diff ] ; then rm test_badpix.diff ; fi
	- diff test_newbadpix.txt test_oldbadpix.txt > test_badpix.diff
#	rsync --times --cvs-exclude $(DATA) $(INSTALL_DATA)/


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
ifdef LIB
	mkdir -p $(INSTALL_PERLLIB)/$(PERLTASK)
	rsync --times --cvs-exclude $(LIB) $(INSTALL_PERLLIB)/$(PERLTASK)/
endif
ifdef GEN_LIB
	mkdir -p $(INSTALL_PERLLIB)/$(PERLGEN)
	rsync --times --cvs-exclude $(GEN_LIB) $(INSTALL_PERLLIB)/$(PERLGEN)/
endif
ifdef FID_LINK_NAME
	if [ -r $(INSTALL_DATA)/$(FID_LINK_NAME) ]; then rm $(INSTALL_DATA)/$(FID_LINK_NAME); fi
	ln -s $(INSTALL_DATA)/$(FID_CHARACTERISTICS) $(INSTALL_DATA)/$(FID_LINK_NAME)
endif
	mkdir -p $(SKA)/ops/Chex
 
