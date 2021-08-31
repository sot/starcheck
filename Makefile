TASK = starcheck
FLIGHT_ENV = SKA

SRC = starcheck/src


RELATED_LIB = $(SRC)/StarcheckParser.pm
BIN = $(SRC)/starcheck.pl $(SRC)/starcheck
LIB = $(SRC)/lib/Ska/Starcheck/Obsid.pm \
	$(SRC)/lib/Ska/Parse_CM_File.pm
PYTHON_LIB = starcheck/calc_ccd_temps.py starcheck/pcad_att_check.py starcheck/plot.py \
	     starcheck/utils.py starcheck/__init__.py
DOC_RST = $(SRC)/aca_load_review_cl.rst
DOC_HTML = aca_load_review_cl.html


TEST_DATA_TGZ = ${SKA}/data/starcheck/JUL0918A_test_data.tar.gz
# starcheck_characteristics tarball should be installed from
# separate starcheck_characteristics project
# with "make install_dist" from that project
TEST_BACKSTOP = JUL0918A/CR190_0603.backstop

DATA_FILES = starcheck/data/ACABadPixels starcheck/data/agasc.bad \
	starcheck/data/fid_CHARACTERIS_JUL01 starcheck/data/fid_CHARACTERIS_FEB07 \
	starcheck/data/fid_CHARACTERISTICS starcheck/data/characteristics.yaml \
	starcheck/data/overlib.js starcheck/data/up.gif starcheck/data/down.gif \

SHA_FILES = ${SKA_ARCH_OS}/bin/ska_version $(BIN) $(LIB) \
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
	./sandbox_starcheck -dir JUL0918A -agasc_file ${SKA}/data/agasc/agasc1p6.h5 -out test


check: test

# Comprehensive regression test
.PHONY: dark_regress
dark_regress: $(TEST_BACKSTOP) $(DATA_FILES)
	$(SRC)/dark_regress "$(HOSTNAME)_$(SHA)"


# Comprehensive regression test
.PHONY: regress
regress: $(DATA_FILES)
	$(SRC)/run_regress "$(HOSTNAME)_$(SHA)"

checklist:
ifdef DOC_RST
	if [ -r $(DOC_HTML) ] ; then rm $(DOC_HTML); fi
	rst2html.py $(DOC_RST) > $(DOC_HTML)
endif


install:
	rsync -a ska_bin_starcheck $(INSTALL_BIN)/starcheck

