SKA		= /proj/rad1/ska
PERL            = $(SKA)/perl
PERLLIB         = $(SKA)/lib/perl5/local


test:
	run_regress

install:
	rsync -a starcheck.pl $(PERL)/
	rsync -a starcheck_obsid.pl $(PERL)/
	rsync -a parse_cm_file.pl $(PERL)/

clean:
	rm starcheck.pl starcheck_obsid.pl parse_cm_file.pl
