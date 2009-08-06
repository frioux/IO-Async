#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 12;

use IO::Async::Loop::IO_Poll;

use IO::Socket::INET;

use IO::Async::Listener;

my $loop = IO::Async::Loop::IO_Poll->new();

testing_loop( $loop );

my $listensock;

$listensock = IO::Socket::INET->new(
   LocalAddr => "localhost",
   Type      => SOCK_STREAM,
   Listen    => 1,
) or die "Cannot socket() - $!";

my $newclient;

my $listener = IO::Async::Listener->new(
   handle => $listensock,
   on_accept => sub { $newclient = shift },
);

ok( defined $listener, 'defined $listener' );
isa_ok( $listener, "IO::Async::Listener", '$listener isa IO::Async::Listener' );
isa_ok( $listener, "IO::Async::Notifier", '$listener isa IO::Async::Notifier' );

ok( $listener->is_listening, '$listener is_listening' );
is( $listener->sockname, $listensock->sockname, '$listener->sockname' );

$loop->add( $listener );

my $clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listensock->sockname ) or die "Cannot connect() - $!";

ok( defined $clientsock->peername, '$clientsock is connected' );

wait_for { defined $newclient };

is( $newclient->peername, $clientsock->sockname, '$newclient peer is correct' );

$loop->remove( $listener );

undef $clientsock;
undef $newclient;

undef $listener;
undef $listensock;

$listener = IO::Async::Listener->new(
   on_accept => sub { $newclient = shift },
);

ok( !$listener->is_listening, '$listener is_listening not yet' );

$loop->add( $listener );

my $listen_self;

$listener->listen(
   addr => [ AF_INET, SOCK_STREAM, 0, pack_sockaddr_in( 0, INADDR_ANY ) ],
   on_listen => sub { $listen_self = shift },
   on_listen_error => sub { die "Test died early - $_[0] - $_[-1]\n"; },
);

ok( $listener->is_listening, '$listener is_listening' );

is( $listen_self, $listener, '$listen_self is $listener' );

$clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listener->sockname ) or die "Cannot connect() - $!";

ok( defined $clientsock->peername, '$clientsock is connected' );

wait_for { defined $newclient };

is( $newclient->peername, $clientsock->sockname, '$newclient peer is correct' );

$loop->remove( $listener );
