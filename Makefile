TASK = starcheck
FLIGHT_ENV = SKA

SRC = $(PWD)/src

PERLTASK = Ska/Starcheck
PERLGEN = Ska/

include $(SKA)/include/Makefile.FLIGHT

RELATED_LIB = $(SRC)/StarcheckParser.pm
BIN = $(SRC)/starcheck.pl $(SRC)/starcheck
GEN_LIB = $(SRC)/Parse_CM_File.pm
LIB = $(SRC)/Obsid.pm $(SRC)/FigureOfMerit.pm $(SRC)/Dark_Cal_Checker.pm

DOC_RST = $(SRC)/aca_load_review_cl.rst
DOC_HTML = aca_load_review_cl.html


TEST_DATA_TGZ = $(ROOT_FLIGHT)/data/starcheck/AUG0104A_test_data.tar.gz
# starcheck_characteristics tarball should be installed from
# separate starcheck_characteristics project
# with "make install_dist" from that project
DATA_TGZ = $(INSTALL_DATA)/starcheck_characteristics.tar.gz

GITSHA := $(shell git rev-parse --short HEAD)

test_data:
	tar -zxvpf $(TEST_DATA_TGZ) 

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


check: check_install all install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck -dir AUG0104A -fid_char fid_CHARACTERIS_JUL01 -out test

# Basic aliveness test
test: test_data starcheck_data_local
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	./sandbox_starcheck -dir AUG0104A -fid_char fid_CHARACTERIS_JUL01 -out test


# Comprehensive regression test
regress: test_data starcheck_data_local
	if [ -r regress_diffs ] ; then rm regress_diffs ; fi
	if [ -r regress_log ] ; then rm regress_log ; fi
	if [ -r vehicle_regress_diffs ] ; then rm vehicle_regress_diffs ; fi
	if [ -r vehicle_regress_log ] ; then rm vehicle_regress_log ; fi
	if [ -r regress/$(GITSHA) ] ; then rm -r regress/$(GITSHA); fi
	$(SRC)/run_regress $(GITSHA)

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
	mkdir -p $(INSTALL_PERLLIB)/$(PERLTASK)
	rsync --times --cvs-exclude $(LIB) $(INSTALL_PERLLIB)/$(PERLTASK)/
endif
ifdef GEN_LIB
	mkdir -p $(INSTALL_PERLLIB)/$(PERLGEN)
	rsync --times --cvs-exclude $(GEN_LIB) $(INSTALL_PERLLIB)/$(PERLGEN)/
endif


# Make sure install dir is not flight.  (This doesn't resolve links etc)
check_install:
        test "$(INSTALL)" != "$(ROOT_FLIGHT)"
 

