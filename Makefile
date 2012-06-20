TASK = starcheck
FLIGHT_ENV = SKA

SRC = $(PWD)/src

include $(SKA)/include/Makefile.FLIGHT

RELATED_LIB = $(SRC)/StarcheckParser.pm
BIN = $(SRC)/starcheck.pl $(SRC)/starcheck
LIB = $(SRC)/lib/Ska/Starcheck/Obsid.pm $(SRC)/lib/Ska/Starcheck/FigureOfMerit.pm \
	$(SRC)/lib/Ska/Starcheck/Dark_Cal_Checker.pm $(SRC)/lib/Ska/Parse_CM_File.pm

DOC_RST = $(SRC)/aca_load_review_cl.rst
DOC_HTML = aca_load_review_cl.html


TEST_DATA_TGZ = $(ROOT_FLIGHT)/data/starcheck/AUG0104A_test_data.tar.gz
# starcheck_characteristics tarball should be installed from
# separate starcheck_characteristics project
# with "make install_dist" from that project
DATA_TGZ = $(INSTALL_DATA)/starcheck_characteristics.tar.gz

SHA_FILES = $(BIN) $(LIB) $(GEN_LIB) \
	$(INSTALL_DATA)/ACABadPixels $(INSTALL_DATA)/agasc.bad \
	$(INSTALL_DATA)/fid_CHARACTERIS_JUL01 $(INSTALL_DATA)/fid_CHARACTERIS_FEB07 \
	$(INSTALL_DATA)/fid_CHARACTERISTICS $(INSTALL_DATA)/characteristics.yaml \
	$(INSTALL_DATA)/A.tlr $(INSTALL_DATA)/B.tlr $(INSTALL_DATA)/tlr.cfg

# Calculate the SHA1 checksum of the set of files in SHA_FILES and return just the sum
SHA = $(shell sha1sum $(SHA_FILES) | sha1sum | cut -c 1-40)

test_data:
	tar -zxvpf $(TEST_DATA_TGZ) 

starcheck_data:
	tar -zxvpf $(DATA_TGZ)
	cd starcheck_characteristics && $(MAKE) install

all: 
	# Nothing to make; "make install" to install to $(SKA)


check: check_install all install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck -dir AUG0104A -fid_char fid_CHARACTERIS_JUL01 -out test

# Basic aliveness test
test: check_install install test_data starcheck_data
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck -dir AUG0104A -fid_char fid_CHARACTERIS_JUL01 -out test


# Comprehensive regression test
regress: check_install install bad_acq_install
	$(SRC)/run_regress $(SHA)

checklist:
ifdef DOC_RST
	mkdir -p $(INSTALL_DOC)
	if [ -r $(DOC_HTML) ] ; then rm $(DOC_HTML); fi
	rst2html.py $(DOC_RST) > $(DOC_HTML)
endif



install: 
ifdef BIN
	mkdir -p $(INSTALL_BIN)
	rsync --times --cvs-exclude $(BIN) $(INSTALL_BIN)/
#	pod2html starcheck.pl > $(INSTALL_DOC)/starcheck.html
endif
ifdef LIB
	mkdir -p $(INSTALL_PERLLIB)
	rsync --times --cvs-exclude --recursive $(SRC)/lib/* $(INSTALL_PERLLIB)/
endif


# Make sure install dir is not flight.  (This doesn't resolve links etc)
check_install:
        test "$(INSTALL)" != "$(ROOT_FLIGHT)"
 

