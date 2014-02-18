# Set the task name
TASK = starcheck

# Uncomment the correct choice indicating either SKA or TST flight environment
FLIGHT_ENV = SKA

FID_CHARACTERISTICS = fid_CHARACTERIS_FEB07
FID_LINK_NAME = fid_CHARACTERISTICS
MODELSPEC_CHARACTERISTICS = aca_spec.json_FEB14
MODELSPEC_LINK_NAME = aca_spec.json

DATA = ACABadPixels agasc.bad A.tlr B.tlr characteristics.yaml tlr.cfg \
	fid_CHARACTERIS_FEB07 fid_CHARACTERIS_JAN07 fid_CHARACTERIS_JUL01 \
	up.gif down.gif overlib.js bad_gui_stars.rdb bad_acq_stars.rdb \
	aca_spec.json_FEB14

include $(SKA)/include/Makefile.FLIGHT

fid_link:
ifdef FID_LINK_NAME
	rm -f $(FID_LINK_NAME)
	ln -s $(FID_CHARACTERISTICS) $(FID_LINK_NAME)
endif

model_link:
ifdef MODELSPEC_LINK_NAME
	rm -f $(MODELSPEC_LINK_NAME)
	ln -s $(MODELSPEC_CHARACTERISTICS) $(MODELSPEC_LINK_NAME)
endif

install: fid_link model_link
#  Uncomment the lines which apply for this task
ifdef FID_LINK_NAME
	rsync --times --cvs-exclude --links $(FID_LINK_NAME) $(INSTALL_DATA)/
endif
ifdef MODELSPEC_LINK_NAME
	rsync --times --cvs-exclude --links $(MODELSPEC_LINK_NAME) $(INSTALL_DATA)/
endif
ifdef DATA
	mkdir -p $(INSTALL_DATA)
	rsync --times --cvs-exclude $(DATA) $(INSTALL_DATA)/
endif
