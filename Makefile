TASK = starcheck

include /proj/sot/ska/include/Makefile.FLIGHT

BIN = starcheck.pl 
SHARE = starcheck_obsid.pl parse_cm_file.pl figure_of_merit.pl
DATA = ACABadPixels agasc.bad  fid_CHARACTERIS_JUL01

TEST_DEPS = data/acq_stats/bad_acq_stars.rdb

test: check_install AUG0805A install
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	$(INSTALL_BIN)/starcheck.pl -dir AUG0805A -out test

AUG0104A:
	ln -s /data/mpcrit1/mplogs/2004/AUG0104/oflsa AUG0104A

regress: $(BIN) $(SHARE) $(DATA)
	if [ -r regress_diffs ] ; then rm regress_diffs ; fi
	if [ -r regress_log ] ; then rm regress_log ; fi
	if [ -d regress ] ; then rm -r regress ; fi
	run_regress

install: $(TEST_DEPS)
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
 
