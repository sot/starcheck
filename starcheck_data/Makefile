# Set the task name
TASK = starcheck

# Uncomment the correct choice indicating either SKA or TST flight environment
FLIGHT_ENV = SKA

DATA = ACABadPixels agasc.bad A.tlr B.tlr characteristics.yaml tlr.cfg \
	fid_CHARACTERIS_FEB07 fid_CHARACTERIS_JAN07 fid_CHARACTERIS_JUL01 \
	up.gif down.gif overlib.js bad_gui_stars.rdb bad_acq_stars.rdb \
	aca_spec.json fid_CHARACTERISTICS

include $(SKA)/include/Makefile.FLIGHT

install:
#  Uncomment the lines which apply for this task
ifdef DATA
	mkdir -p $(INSTALL_DATA)
	rsync --times --cvs-exclude $(DATA) $(INSTALL_DATA)/
endif
