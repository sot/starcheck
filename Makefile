SKA		= /proj/rad1/ska
PERL            = $(SKA)/perl
PERLLIB         = $(SKA)/lib/perl5/local

install:
	cp starcheck.pl $(PERL)/
	cp starcheck_obsid.pl $(PERL)/
	cp parse_cm_file.pl $(PERL)/
