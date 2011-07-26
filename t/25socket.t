#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 40;
use Test::Fatal;
use Test::Refcount;

use POSIX qw( EAGAIN ECONNRESET );

use Socket qw( unpack_sockaddr_in );

use IO::Async::Loop;

use IO::Async::Socket;

my $loop = IO::Async::Loop->new;

testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair( "inet", "dgram" ) or die "Cannot socketpair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );
my @S2addr = unpack_sockaddr_in $S2->sockname;

# useful test function
sub recv_data
{
   my ( $s ) = @_;

   my $buffer;
   my $ret = $s->recv( $buffer, 8192 );

   return $buffer if defined $ret and length $buffer;
   die "Socket closed" if defined $ret;
   return "" if $! == EAGAIN;
   die "Cannot recv - $!";
}

ok( !exception { IO::Async::Socket->new( write_handle => \*STDOUT ) }, 'Send-only Socket works' );

# Receiving

my @received;

my $socket = IO::Async::Socket->new(
   handle => $S1,
   on_recv => sub {
      my $self = shift;
      my ( $dgram, $sender ) = @_;

      push @received, [ $dgram, unpack_sockaddr_in $sender ];
   },
);

ok( defined $socket, 'recving $socket defined' );
isa_ok( $socket, "IO::Async::Socket", 'recving $socket isa IO::Async::Socket' );

is_oneref( $socket, 'recving $socket has refcount 1 initially' );

$loop->add( $socket );

is_refcount( $socket, 2, 'recving $socket has refcount 2 after adding to Loop' );

$S2->send( "message\n" );

is_deeply( \@received, [], '@received before wait' );

wait_for { scalar @received };

is_deeply( \@received,
           [ [ "message\n", @S2addr ] ],
           '@received after wait' );

undef @received;
my @new_received;
$socket->configure(
   on_recv => sub {
      my $self = shift;
      my ( $dgram, $sender ) = @_;
      push @new_received, [ $dgram, unpack_sockaddr_in $sender ];
   },
);

$S2->send( "another message\n" );

wait_for { scalar @new_received };

is( scalar @received, 0, '@received still empty after on_recv replace' );
is_deeply( \@new_received,
           [ [ "another message\n", @S2addr ] ],
           '@new_received after on_recv replace' );

is_refcount( $socket, 2, 'receiving $socket has refcount 2 before removing from Loop' );

$loop->remove( $socket );

is_oneref( $socket, 'receiving $socket refcount 1 finally' );

undef $socket;

{
   my @frags;

   $socket = IO::Async::Socket->new(
      handle => $S1,
      recv_len => 4,
      on_recv => sub {
         my ( $self, $dgram ) = @_;
         push @frags, $dgram;
      },
   );

   $loop->add( $socket );

   $S2->send( "A nice long message" );
   $S2->send( "another one here" );
   $S2->send( "and again" );

   wait_for { scalar @frags };

   is_deeply( \@frags, [ "A ni" ], '@frags with recv_len=4 without recv_all' );

   wait_for { @frags == 3 };

   is_deeply( \@frags, [ "A ni", "anot", "and " ], '@frags finally with recv_len=4 without recv_all' );

   undef @frags;
   $socket->configure( recv_all => 1 );

   $S2->send( "Long messages" );
   $S2->send( "Repeated" );
   $S2->send( "Once more" );

   wait_for { scalar @frags };

   is_deeply( \@frags, [ "Long", "Repe", "Once" ], '@frags with recv_len=4 with recv_all' );
}

my $no_on_recv_socket;
ok( !exception { $no_on_recv_socket = IO::Async::Socket->new( handle => $S1 ) },
    'Allowed to construct a Socket without an on_recv handler' );
ok( exception { $loop->add( $no_on_recv_socket ) },
    'Not allowed to add an on_recv-less Socket to a Loop' );

# Subclass

my @sub_received;

$socket = TestSocket->new(
   handle => $S1,
);

ok( defined $socket, 'receiving subclass $socket defined' );
isa_ok( $socket, "IO::Async::Socket", 'receiving $socket isa IO::Async::Socket' );

is_oneref( $socket, 'subclass $socket has refcount 1 initially' );

$loop->add( $socket );

is_refcount( $socket, 2, 'subclass $socket has refcount 2 after adding to Loop' );

$S2->send( "message\n" );

is_deeply( \@sub_received, [], '@sub_received before wait' );

wait_for { scalar @sub_received };

is_deeply( \@sub_received,
          [ [ "message\n", @S2addr ] ],
          '@sub_received after wait' );

undef @sub_received;

$loop->remove( $socket );

undef $socket;

# Sending

my $empty;

$socket = IO::Async::Socket->new(
   write_handle => $S1,
   on_outgoing_empty => sub { $empty = 1 },
);

ok( defined $socket, 'sending $socket defined' );
isa_ok( $socket, "IO::Async::Socket", 'sending $socket isa IO::Async::Socket' );

is_oneref( $socket, 'sending $socket has refcount 1 intially' );

$loop->add( $socket );

is_refcount( $socket, 2, 'sending $socket has refcount 2 after adding to Loop' );

ok( !$socket->want_writeready, 'want_writeready before send' );
$socket->send( "message\n" );

ok( $socket->want_writeready, 'want_writeready after send' );

wait_for { $empty };

ok( !$socket->want_writeready, 'want_writeready after wait' );
is( $empty, 1, '$empty after writing buffer' );

is( recv_data( $S2 ), "message\n", 'data after writing buffer' );

$socket->configure( autoflush => 1 );
$socket->send( "immediate\n" );

ok( !$socket->want_writeready, 'not want_writeready after autoflush send' );
is( recv_data( $S2 ), "immediate\n", 'data after autoflush send' );

$socket->configure( autoflush => 0 );
$socket->send( "First\n" );
$socket->configure( autoflush => 1 );
$socket->send( "Second\n" );

ok( !$socket->want_writeready, 'not want_writeready after split autoflush send' );
is( recv_data( $S2 ), "First\n",  'data[0] after split autoflush send' );
is( recv_data( $S2 ), "Second\n", 'data[1] after split autoflush send' );

is_refcount( $socket, 2, 'sending $socket has refcount 2 before removing from Loop' );

$loop->remove( $socket );

is_oneref( $socket, 'sending $socket has refcount 1 finally' );

# Socket errors

my ( $ES1, $ES2 ) = $loop->socketpair or die "Cannot socketpair - $!";
$ES2->syswrite( "X" ); # ensuring $ES1 is read- and write-ready
# cheating and hackery
bless $ES1, "ErrorSocket";

$ErrorSocket::errno = ECONNRESET;

my $recv_errno;
my $send_errno;

$socket = IO::Async::Socket->new(
   read_handle => $ES1,
   on_recv => sub {},
   on_recv_error => sub { ( undef, $recv_errno ) = @_ },
);

$loop->add( $socket );

wait_for { defined $recv_errno };

cmp_ok( $recv_errno, "==", ECONNRESET, 'errno after failed recv' );

$loop->remove( $socket );

$socket = IO::Async::Socket->new(
   write_handle => $ES1,
   on_send_error => sub { ( undef, $send_errno ) = @_ },
);

$loop->add( $socket );

$socket->send( "hello" );

wait_for { defined $send_errno };

cmp_ok( $send_errno, "==", ECONNRESET, 'errno after failed send' );

$loop->remove( $socket );

package TestSocket;
use base qw( IO::Async::Socket );
use Socket qw( unpack_sockaddr_in );

sub on_recv
{
   my $self = shift;
   my ( $dgram, $sender ) = @_;

   push @sub_received, [ $dgram, unpack_sockaddr_in $sender ];
}

package ErrorSocket;

use base qw( IO::Socket );
our $errno;

sub recv  { $! = $errno; undef; }
sub send  { $! = $errno; undef; }
sub close { }
