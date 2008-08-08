#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 6;

use IO::Socket::INET;
use POSIX qw( ENOENT );
use Socket qw( AF_UNIX pack_sockaddr_un );

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();

testing_loop( $loop );

# Try connect()ing to a socket we've just created
my $listensock = IO::Socket::INET->new( LocalAddr => 'localhost', Listen => 1 ) or
   die "Cannot create listensock - $!";

printf "Have a testing socket listening on %s:%d\n", $listensock->sockhost, $listensock->sockport;

my $addr = $listensock->sockname;

my $sock;

$loop->connect(
   addr => [ AF_INET, SOCK_STREAM, 0, $addr ],
   on_connected => sub { $sock = shift; },
   on_connect_error => sub { die "Test died early - connect error $_[0]\n"; },
);

wait_for { $sock };

isa_ok( $sock, "IO::Socket", 'by addr: $sock isa IO::Socket' );
is( $sock->peername, $addr, 'by addr: $sock->getpeername is $addr' );

$listensock->accept; # Throw it away
undef $sock; # This too

# Now try by name

$loop->connect(
   host     => $listensock->sockhost,
   service  => $listensock->sockport,
   socktype => $listensock->socktype,
   on_connected => sub { $sock = shift; },
   on_resolve_error => sub { die "Test died early - resolve error $_[0]\n"; },
   on_connect_error => sub { die "Test died early - connect error $_[0]\n"; },
);

wait_for { $sock };

isa_ok( $sock, "IO::Socket", 'by host/service: $sock isa IO::Socket' );
is( $sock->peername, $addr, 'by host/service: $sock->getpeername is $addr' );

$listensock->accept; # Throw it away
undef $sock; # This too

# Now try an address we know to be invalid - a UNIX socket that doesn't exist

my $error;

my $failop;
my $failerr;

$loop->connect(
   addr => [ AF_UNIX, SOCK_STREAM, 0, pack_sockaddr_un( "/some/path/we/know/breaks" ) ],
   on_connected => sub { die "Test died early - connect succeeded\n"; },
   on_fail => sub { $failop = shift @_; $failerr = pop @_; },
   on_connect_error => sub { $error = 1 },
);

wait_for { $error };

is( $failop, "connect", '$failop is connect' );
is( $failerr+0, ENOENT, '$failerr is ENOENT' );
