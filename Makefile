TASK = starcheck

include /proj/sot/ska/include/Makefile.FLIGHT

BIN = starcheck.pl 
SHARE = starcheck_obsid.pl parse_cm_file.pl figure_of_merit.pl
DATA = data/ACABadPixels data/agasc.bad  data/fid_CHARACTERIS_JUL01

test: AUG0104A share lib 
	if [ -r test.html ] ; then rm test.html ; fi
	if [ -r test.txt ] ; then rm test.txt ; fi
	if [ -d test ] ; then rm -r test ; fi
	env SKA=$(PWD) ./starcheck.pl -dir AUG0104A -out test

AUG0104A:
	ln -s /data/mpcrit1/mplogs/2004/AUG0104/oflsa AUG0104A

regress: $(BIN) $(SHARE) $(DATA) share lib
	run_regress

install:
ifdef BIN
	mkdir -p $(INSTALL_BIN)
	rsync --times --cvs-exclude $(BIN) $(INSTALL_BIN)/
endif
ifdef DATA
	mkdir -p $(INSTALL_DATA)
	rsync --times --cvs-exclude $(DATA) $(INSTALL_DATA)/
endif
ifdef DATA
	mkdir -p $(INSTALL_SHARE)
	rsync --times --cvs-exclude $(SHARE) $(INSTALL_SHARE)/
endif
	mkdir -p $(SKA)/ops/Chex
