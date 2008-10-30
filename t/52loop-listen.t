#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 10;
use Test::Exception;

use IO::Socket::INET;

use Socket qw( unpack_sockaddr_in );

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();

testing_loop( $loop );

my $listensock;

$listensock = IO::Socket::INET->new(
   LocalAddr => "localhost",
   Type      => SOCK_STREAM,
   Listen    => 1,
) or die "Cannot socket() - $!";

my $newclient;

$loop->listen(
   handle => $listensock,

   on_accept => sub { $newclient = $_[0]; },
);

my $clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listensock->sockname ) or die "Cannot connect() - $!";

ok( defined $clientsock->peername, '$clientsock is connected' );

wait_for { defined $newclient };

is( $newclient->peername, $clientsock->sockname, '$newclient peer is correct' );

undef $listensock;
undef $clientsock;
undef $newclient;

$loop->listen(
   family   => AF_INET,
   socktype => SOCK_STREAM,
   service  => 0, # Ask the kernel to allocate a port for us
   host     => "localhost",

   on_resolve_error => sub { die "Test died early - resolve error $_[0]\n"; },

   on_listen => sub { $listensock = $_[0]; },

   on_accept => sub { $newclient = $_[0]; },

   on_listen_error => sub { die "Test died early - $_[0] - $_[-1]\n"; },
);

wait_for { defined $listensock };

ok( defined $listensock->fileno, '$listensock has a fileno' );
isa_ok( $listensock, "IO::Socket::INET", '$listenaddr isa IO::Socket::INET' );

my $listenaddr = $listensock->sockname;

ok( defined $listenaddr, '$listensock has address' );

my ( $listenport, $listen_inaddr ) = unpack_sockaddr_in( $listenaddr );

is( $listen_inaddr, "\x7f\0\0\1", '$listenaddr is INADDR_LOOPBACK' );

$clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listenaddr ) or die "Cannot connect() - $!";

is( (unpack_sockaddr_in( $clientsock->peername ))[0], $listenport, '$clientsock on the correct port' );

wait_for { defined $newclient };

isa_ok( $newclient, "IO::Socket::INET", '$newclient isa IO::Socket::INET' );

is( $newclient->peername, $clientsock->sockname, '$newclient peer is correct' );

# Now we want to test failure. It's hard to know in a test script what will
# definitely fail, but it's likely we're either running as non-root, or the
# machine has at least one of an SSH or a webserver running. In this case,
# it's likely we'll fail to bind TCP port 22 or 80.

my $badport;
foreach my $port ( 22, 80 ) {
   IO::Socket::INET->new( Type => SOCK_STREAM, LocalPort => $port, Listen => 1, ReuseAddr => 1 ) and next;
      
   $badport = $port;
   last;
}

SKIP: {
   skip "No bind()-failing ports found", 1 unless defined $badport;

   my ( $failcall, @failargs, $failbang );

   my $errored = 0;

   $loop->listen(
      family   => AF_INET,
      socktype => SOCK_STREAM,
      service  => $badport,

      on_resolve_error => sub { die "Test died early - resolve error $_[0]\n"; },

      on_listen => sub { die "Test died early - listen on port $badport actually succeeded\n"; },

      on_accept => sub { "DUMMY" }, # really hope this doesn't happen ;)

      on_fail => sub { $failbang = pop; ( $failcall, @failargs ) = @_; },
      on_listen_error => sub { $errored = 1 },
   );

   wait_for { $errored };

   # We hope it's the bind() call that failed. Not quite sure what bang might
   # be. EPERM or EADDRINUSE or various things. Best not to be sensitive on it
   is( $failcall, "bind", "bind() to bad port $badport fails ($failbang)" );
}
