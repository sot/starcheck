package Ska::Starcheck::Python;

use strict;
use warnings;
use IO::Socket;
use JSON;
use Carp qw(confess);
use Data::Dumper;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
require Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw();
our @EXPORT_OK = qw(call_python date2time time2date);
%EXPORT_TAGS = ( all => \@EXPORT_OK );

STDOUT->autoflush(1);

$Data::Dumper::Terse = 1;

my $host = "localhost";
my $port = 44123;


sub call_python {
    my $func = shift;
    my $args = shift;
    my $kwargs = shift;
    if (!defined $args) { $args = []; }
    if (!defined $kwargs) { $kwargs = {}; }

    my $command = {
        "func" => $func,
        "args" => $args,
        "kwargs" => $kwargs,
    };
    my $command_json = encode_json $command;
    # print "CLIENT: Sending command $command_json\n";

    my $handle;
    my $iter = 0;
    while ($iter++ < 10) {
        $handle = IO::Socket::INET->new(Proto     => "tcp",
                                        PeerAddr  => $host,
                                        PeerPort  => $port);
        last if defined($handle);
        sleep 1;
    }
    if (!defined($handle)) {
        die "Unable to connect to port $port on $host: $!";
    }
    $handle->autoflush(1);       # so output gets there right away
    $handle->write("$command_json\n");

    my $response = <$handle>;
    $handle->close();

    my $data = decode_json $response;
    # print "CLIENT: Got response: $response\n";
    # print Dumper($data);
    if (defined $data->{exception}) {
        my $msg = "\nPython exception:\n";
        $msg .= "command = " . Dumper($command) . "\n";
        $msg .= "$data->{exception}\n";
        Carp::confess $msg;
    }

    return $data->{result};
}


sub date2time {
    my $date = shift;
    # print "date2time: $date\n";
    return call_python("utils.date2time", [$date]);
}


sub time2date {
    my $time = shift;
    # print "time2date: $time\n";
    return call_python("utils.time2date", [$time]);
}

