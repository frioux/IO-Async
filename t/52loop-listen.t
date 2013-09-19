#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Test;

use Test::More;

use IO::Socket::INET;

use Socket qw( inet_ntoa unpack_sockaddr_in );

use IO::Async::Loop;

# Some odd locations like BSD jails might not like INADDR_LOOPBACK. We'll
# establish a baseline first to test against
my $INADDR_LOOPBACK = do {
   my $localsock = IO::Socket::INET->new( LocalAddr => "localhost", Listen => 1 );
   $localsock->sockaddr;
};
my $INADDR_LOOPBACK_HOST = inet_ntoa( $INADDR_LOOPBACK );
if( $INADDR_LOOPBACK ne INADDR_LOOPBACK ) {
   diag( "Testing with INADDR_LOOPBACK=$INADDR_LOOPBACK_HOST; this may be because of odd networking" );
}

my $loop = IO::Async::Loop->new_builtin;

testing_loop( $loop );

my $listensock;
my $notifier;

$listensock = IO::Socket::INET->new(
   LocalAddr => "localhost",
   Type      => SOCK_STREAM,
   Listen    => 1,
) or die "Cannot socket() - $!";

my $newclient;

$loop->listen(
   handle => $listensock,

   on_notifier => sub { $notifier = $_[0]; },

   on_accept => sub { $newclient = $_[0]; },
);

ok( defined $notifier, 'on_notifier fired synchronously' );
isa_ok( $notifier, "IO::Async::Notifier", 'synchronous on_notifier given a Notifier' );

my $clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listensock->sockname ) or die "Cannot connect() - $!";

ok( defined $clientsock->peername, '$clientsock is connected' );

wait_for { defined $newclient };

is_deeply( [ unpack_sockaddr_in $newclient->peername ],
           [ unpack_sockaddr_in $clientsock->sockname ], '$newclient peer is correct' );

undef $listensock;
undef $clientsock;
undef $newclient;
undef $notifier;

$loop->listen(
   family   => "inet",
   socktype => "stream",
   service  => "", # Ask the kernel to allocate a port for us
   host     => "localhost",

   on_resolve_error => sub { die "Test died early - resolve error $_[0]\n"; },

   on_listen => sub { $listensock = $_[0]; },

   on_notifier => sub { $notifier = $_[0]; },

   on_accept => sub { $newclient = $_[0]; },

   on_listen_error => sub { die "Test died early - $_[0] - $_[-1]\n"; },
);

wait_for { defined $listensock };

ok( defined $listensock->fileno, '$listensock has a fileno' );
# Not sure if it'll be an IO::Socket::INET or ::IP, but either way it should support these
can_ok( $listensock, qw( peerhost peerport ) );

wait_for { defined $notifier };

ok( defined $notifier, 'on_notifier fired asynchronously' );
isa_ok( $notifier, "IO::Async::Notifier", 'asynchronous on_notifier given a Notifier' );

my $listenaddr = $listensock->sockname;

ok( defined $listenaddr, '$listensock has address' );

my ( $listenport, $listen_inaddr ) = unpack_sockaddr_in( $listenaddr );

is( inet_ntoa( $listen_inaddr ), $INADDR_LOOPBACK_HOST, '$listenaddr is INADDR_LOOPBACK' );

$clientsock = IO::Socket::INET->new( Type => SOCK_STREAM )
   or die "Cannot socket() - $!";

$clientsock->connect( $listenaddr ) or die "Cannot connect() - $!";

is( (unpack_sockaddr_in( $clientsock->peername ))[0], $listenport, '$clientsock on the correct port' );

wait_for { defined $newclient };

can_ok( $newclient, qw( peerhost peerport ) );

is_deeply( [ unpack_sockaddr_in $newclient->peername ],
           [ unpack_sockaddr_in $clientsock->sockname ], '$newclient peer is correct' );

# Now we want to test failure. It's hard to know in a test script what will
# definitely fail, but it's likely we're either running as non-root, or the
# machine has at least one of an SSH or a webserver running. In this case,
# it's likely we'll fail to bind TCP port 22 or 80.

my $badport;
my $failure;
foreach my $port ( 22, 80 ) {
   IO::Socket::INET->new(
      Type      => SOCK_STREAM,
      LocalHost => "localhost",
      LocalPort => $port,
      Listen    => 1,
   ) and next;
      
   $badport = $port;
   $failure = $!;
   last;
}

SKIP: {
   skip "No bind()-failing ports found", 6 unless defined $badport;

   my $failop;
   my $failerr;

   my @error;

   # Undocumented API, returning the Listener object
   my $listener = $loop->listen(
      family   => "inet",
      socktype => "stream",
      host     => "localhost",
      service  => $badport,

      on_resolve_error => sub { die "Test died early - resolve error $_[0]\n"; },

      on_listen => sub { die "Test died early - listen on port $badport actually succeeded\n"; },

      on_accept => sub { "DUMMY" }, # really hope this doesn't happen ;)

      on_fail => sub { $failop = shift; $failerr = pop; },
      on_listen_error => sub { @error = @_; },
   );

   wait_for { @error };

   is( $failop, "bind", '$failop is bind' );
   is( "$failerr", $failure, "\$failerr is '$failure'" );

   is( $error[0], "bind", '$error[0] is bind' );
   is( "$error[1]", $failure, "\$error[1] is '$failure'" );

   ok( defined $listener, '$listener defined after bind failure' );
   ok( !$listener->loop, '$listener not in loop after bind failure' );
}

done_testing;
