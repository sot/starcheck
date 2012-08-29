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
TEST_BACKSTOP = AUG0104A/CR214_0300.backstop 

DATA_TGZ = $(INSTALL_DATA)/starcheck_characteristics.tar.gz

DATA_FILES = starcheck_data_local/ACABadPixels starcheck_data_local/agasc.bad \
	starcheck_data_local/fid_CHARACTERIS_JUL01 starcheck_data_local/fid_CHARACTERIS_FEB07 \
	starcheck_data_local/fid_CHARACTERISTICS starcheck_data_local/characteristics.yaml \
	starcheck_data_local/A.tlr starcheck_data_local/B.tlr starcheck_data_local/tlr.cfg

SHA_FILES = $(BIN) $(LIB) $(DATA_FILES)

# Calculate the SHA1 checksum of the set of files in SHA_FILES and return just the sum
SHA = $(shell sha1sum $(SHA_FILES) | sha1sum | cut -c 1-40)

$(TEST_BACKSTOP):
	tar -zxvpf $(TEST_DATA_TGZ) 

$(DATA_FILES): starcheck_data_local

.PHONY: starcheck_data_local
starcheck_data_local:
	if [ -r characteristics_temp ] ; then rm -r characteristics_temp ; fi
	if [ -r starcheck_data_local ] ; then rm -r starcheck_data_local ; fi
	mkdir -p characteristics_temp
	mkdir -p starcheck_data_local
	tar -zxvpf $(DATA_TGZ) -C characteristics_temp
	rsync -aruvz  characteristics_temp/starcheck_characteristics/* starcheck_data_local/
	rm -r characteristics_temp
	cd starcheck_data_local && $(MAKE) fid_link

starcheck_data:
	tar -zxvpf $(DATA_TGZ)
	cd starcheck_characteristics && $(MAKE) install

all: 
	# Nothing to make; "make install" to install to $(SKA)


# Basic aliveness test
test: $(TEST_BACKSTOP) $(DATA_FILES)
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	./sandbox_starcheck -dir AUG0104A -fid_char fid_CHARACTERIS_JUL01 -out test

check: test


# Comprehensive regression test
regress: $(TEST_BACKSTOP) $(DATA_FILES)
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
 

