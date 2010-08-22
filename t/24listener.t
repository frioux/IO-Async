#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 29;
use Test::Refcount;

use IO::Async::Loop::Poll;

use IO::Socket::INET;

use IO::Async::Listener;

my $loop = IO::Async::Loop::Poll->new();

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
   on_accept => sub { ( undef, $newclient ) = @_ },
);

ok( defined $listener, 'defined $listener' );
isa_ok( $listener, "IO::Async::Listener", '$listener isa IO::Async::Listener' );
isa_ok( $listener, "IO::Async::Notifier", '$listener isa IO::Async::Notifier' );

is_oneref( $listener, '$listener has refcount 1 initially' );

ok( $listener->is_listening, '$listener is_listening' );
is_deeply( [ unpack_sockaddr_in $listener->sockname ],
           [ unpack_sockaddr_in $listensock->sockname ], '$listener->sockname' );

$loop->add( $listener );

is_refcount( $listener, 2, '$listener has refcount 2 after adding to Loop' );

my $clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listensock->sockname ) or die "Cannot connect() - $!";

ok( defined $clientsock->peername, '$clientsock is connected' );

wait_for { defined $newclient };

is_deeply( [ unpack_sockaddr_in $newclient->peername ],
           [ unpack_sockaddr_in $clientsock->sockname ], '$newclient peer is correct' );

undef $clientsock;
undef $newclient;

my $newstream;
$listener->configure(
   on_stream => sub { ( undef, $newstream ) = @_ },
);

$clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listensock->sockname ) or die "Cannot connect() - $!";

wait_for { defined $newstream };

isa_ok( $newstream, "IO::Async::Stream", 'on_stream $newstream isa IO::Async::Stream' );
is_deeply( [ unpack_sockaddr_in $newstream->read_handle->peername ],
           [ unpack_sockaddr_in $clientsock->sockname ], '$newstream sock peer is correct' );

my $newsocket;
$listener->configure(
   on_socket => sub { ( undef, $newsocket ) = @_ },
);

$clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listensock->sockname ) or die "Cannot connect() - $!";

wait_for { defined $newsocket };

isa_ok( $newsocket, "IO::Async::Socket", 'on_socket $newsocket isa IO::Async::Socket' );
is_deeply( [ unpack_sockaddr_in $newsocket->read_handle->peername ],
           [ unpack_sockaddr_in $clientsock->sockname ], '$newsocket sock peer is correct' );

$loop->remove( $listener );
undef $listener;

## Subclass

my $sub_newclient;

$listener = TestListener->new(
   handle => $listensock,
);

ok( defined $listener, 'subclass defined $listener' );
isa_ok( $listener, "IO::Async::Listener", 'subclass $listener isa IO::Async::Listener' );

is_oneref( $listener, 'subclass $listener has refcount 1 initially' );

$loop->add( $listener );

is_refcount( $listener, 2, 'subclass $listener has refcount 2 after adding to Loop' );

$clientsock = IO::Socket::INET->new( LocalAddr => "127.0.0.1", Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listensock->sockname ) or die "Cannot connect() - $!";

ok( defined $clientsock->peername, 'subclass $clientsock is connected' );

wait_for { defined $sub_newclient };

is_deeply( [ unpack_sockaddr_in $sub_newclient->peername ],
           [ unpack_sockaddr_in $clientsock->sockname ], '$sub_newclient peer is correct' );

$loop->remove( $listener );

undef $clientsock;
undef $sub_newclient;

undef $listener;

undef $listener;
undef $listensock;

$listener = IO::Async::Listener->new(
   on_accept => sub { ( undef, $newclient ) = @_ },
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

my $sockname = $listener->sockname;
ok( defined $sockname, 'defined $sockname' );

my ( $port, $sinaddr ) = unpack_sockaddr_in( $sockname );

ok( $port > 0, 'socket listens on some defined port number' );
is( $sinaddr, INADDR_ANY, 'socket listens on INADDR_ANY' );

is( $listen_self, $listener, '$listen_self is $listener' );
undef $listen_self; # for refcount

$clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( pack_sockaddr_in( $port, INADDR_LOOPBACK ) ) or die "Cannot connect() - $!";

ok( defined $clientsock->peername, '$clientsock is connected' );

wait_for { defined $newclient };

is_deeply( [ unpack_sockaddr_in $newclient->peername ],
           [ unpack_sockaddr_in $clientsock->sockname ], '$newclient peer is correct' );

is_refcount( $listener, 2, 'subclass $listener has refcount 2 before removing from Loop' );

$loop->remove( $listener );

is_oneref( $listener, 'subclass $listener has refcount 1 after removing from Loop' );

package TestListener;
use base qw( IO::Async::Listener );

sub on_accept { ( undef, $sub_newclient ) = @_ }
