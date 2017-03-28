TASK = starcheck
FLIGHT_ENV = SKA

SRC = starcheck/src

include $(SKA)/include/Makefile.FLIGHT

RELATED_LIB = $(SRC)/StarcheckParser.pm
BIN = $(SRC)/starcheck.pl $(SRC)/starcheck
LIB = $(SRC)/lib/Ska/Starcheck/Obsid.pm $(SRC)/lib/Ska/Starcheck/FigureOfMerit.pm \
	$(SRC)/lib/Ska/Starcheck/Dark_Cal_Checker.pm $(SRC)/lib/Ska/Parse_CM_File.pm
PYTHON_LIB = starcheck/calc_ccd_temps.py starcheck/pcad_att_check.py
DOC_RST = $(SRC)/aca_load_review_cl.rst
DOC_HTML = aca_load_review_cl.html


TEST_DATA_TGZ = $(ROOT_FLIGHT)/data/starcheck/AUG0104A_test_data.tar.gz
# starcheck_characteristics tarball should be installed from
# separate starcheck_characteristics project
# with "make install_dist" from that project
TEST_BACKSTOP = AUG0104A/CR214_0300.backstop 

DATA_FILES = starcheck/data/aca_spec.json starcheck/data/ACABadPixels starcheck/data/agasc.bad \
	starcheck/data/fid_CHARACTERIS_JUL01 starcheck/data/fid_CHARACTERIS_FEB07 \
	starcheck/data/fid_CHARACTERISTICS starcheck/data/characteristics.yaml \
	starcheck/data/A.tlr starcheck/data/B.tlr starcheck/data/tlr.cfg \
	starcheck/data/overlib.js starcheck/data/up.gif starcheck/data/down.gif \

SHA_FILES = ${SKA_ARCH_OS}/bin/ska_version ${SKA_ARCH_OS}/pkgs.manifest $(BIN) $(LIB) \
	$(DATA_FILES) $(PYTHON_LIB)

# Calculate the SHA1 checksum of the set of files in SHA_FILES and return the abbreviated sum
SHA = $(shell sha1sum $(SHA_FILES) | sha1sum | cut -c 1-40)
HOSTNAME = $(shell hostname)


$(TEST_BACKSTOP):
	tar -zxvpf $(TEST_DATA_TGZ) 


all: 
	# Nothing to make; "make install" to install to $(SKA)


.PHONY: test
# Basic aliveness test
test: $(TEST_BACKSTOP) $(DATA_FILES)
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	./sandbox_starcheck -dir AUG0104A -fid_char fid_CHARACTERIS_JUL01 -out test

check: test


# Comprehensive regression test
.PHONY: regress
regress: $(TEST_BACKSTOP) $(DATA_FILES)
	$(SRC)/run_regress "$(HOSTNAME)_$(SHA)"

checklist:
ifdef DOC_RST
	mkdir -p $(INSTALL_DOC)
	if [ -r $(DOC_HTML) ] ; then rm $(DOC_HTML); fi
	rst2html.py $(DOC_RST) > $(DOC_HTML)
endif


install:
	rsync -a ska_bin_starcheck $(INSTALL_BIN)/starcheck

