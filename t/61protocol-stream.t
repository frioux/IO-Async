#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 26;
use Test::Refcount;

use IO::Async::Loop;

use IO::Async::Stream;
use IO::Async::Protocol::Stream;

use IO::Socket::INET;
use Socket qw( SOCK_STREAM );

my $loop = IO::Async::Loop->new;

testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my @lines;

my $streamproto = IO::Async::Protocol::Stream->new(
   transport => IO::Async::Stream->new( handle => $S1 ),
   on_read => sub {
      my $self = shift;
      my ( $buffref, $closed ) = @_;

      return 0 unless( $$buffref =~ s/^(.*\n)// );

      push @lines, $1;
      return 1;
   },
);

ok( defined $streamproto, '$streamproto defined' );
isa_ok( $streamproto, "IO::Async::Protocol::Stream", '$streamproto isa IO::Async::Protocol::Stream' );

is_oneref( $streamproto, '$streamproto has refcount 1 initially' );

$loop->add( $streamproto );

is_refcount( $streamproto, 2, '$streamproto has refcount 2 after adding to Loop' );

$S2->syswrite( "message\n" );

is_deeply( \@lines, [], '@lines before wait' );

wait_for { scalar @lines };

is_deeply( \@lines, [ "message\n" ], '@lines after wait' );

undef @lines;
my @new_lines;
$streamproto->configure( 
   on_read => sub {
      my $self = shift;
      my ( $buffref, $closed ) = @_;

      return 0 unless( $$buffref =~ s/^(.*\n)// );

      push @new_lines, $1;
      return 1;
   },
);

$S2->syswrite( "new\nlines\n" );

wait_for { scalar @new_lines };

is( scalar @lines, 0, '@lines still empty after on_read replace' );
is_deeply( \@new_lines, [ "new\n", "lines\n" ], '@new_lines after on_read replace' );

$streamproto->write( "response\n" );

my $response = "";
wait_for_stream { $response =~ m/\n/ } $S2 => $response;

is( $response, "response\n", 'response written by protocol' );

my $done;
my $flushed;

$streamproto->write(
   sub {
      is( $_[0], $streamproto, 'writersub $_[0] is $streamproto' );
      return $done++ ? undef : "a lazy message\n";
   },
   on_flush => sub {
      is( $_[0], $streamproto, 'on_flush $_[0] is $streamproto' );
      $flushed = 1;
   },
);

wait_for { $flushed };

$response = "";
wait_for_stream { $response =~ m/\n/ } $S2 => $response;

is( $response, "a lazy message\n", 'response written by protocol writersub' );

my $closed = 0;
$streamproto->configure(
   on_closed => sub { $closed++ },
);

$S2->close;

wait_for { $closed };

is( $closed, 1, '$closed after stream close' );

is_refcount( $streamproto, 2, '$streamproto has refcount 2 before removing from Loop' );

$loop->remove( $streamproto );

is_oneref( $streamproto, '$streamproto refcount 1 finally' );

undef $streamproto;

( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my @sub_lines;

$streamproto = TestProtocol::Stream->new(
   transport => IO::Async::Stream->new( handle => $S1 ),
);

ok( defined $streamproto, 'subclass $streamproto defined' );
isa_ok( $streamproto, "IO::Async::Protocol::Stream", '$streamproto isa IO::Async::Protocol::Stream' );

is_oneref( $streamproto, 'subclass $streamproto has refcount 1 initially' );

$loop->add( $streamproto );

is_refcount( $streamproto, 2, 'subclass $streamproto has refcount 2 after adding to Loop' );

$S2->syswrite( "message\n" );

is_deeply( \@sub_lines, [], '@sub_lines before wait' );

wait_for { scalar @sub_lines };

is_deeply( \@sub_lines, [ "message\n" ], '@sub_lines after wait' );

undef @lines;

$loop->remove( $streamproto );

undef $streamproto;

$streamproto = IO::Async::Protocol::Stream->new(
   handle => $S1,
);

isa_ok( $streamproto->transport, "IO::Async::Stream", 'Protocol::Stream->new( handle ) shortcut creates Stream object' );
is( $streamproto->transport->read_handle, $S1, 'Stream object has correct handle' );

my $serversock = IO::Socket::INET->new(
   Type      => SOCK_STREAM,
   LocalHost => "localhost",
   Listen    => 1,
) or die "Cannot create server socket - $!";

$streamproto = IO::Async::Protocol::Stream->new(
   on_read => sub {
      my $self = shift;
      my ( $buffref, $closed ) = @_;
      push @lines, $1 while $$buffref =~ s/^(.*\n)//;
      return 0;
   }
);

$loop->add( $streamproto );

my $connected = 0;

$streamproto->connect(
   host    => $serversock->sockhost,
   service => $serversock->sockport,
   family  => $serversock->sockdomain,

   on_connected => sub { $connected++ },

   on_connect_error => sub { die "Test failed early - $_[-1]" },
   on_resolve_error => sub { die "Test failed early - $_[-1]" },
);

wait_for { $connected };

my $clientsock = $serversock->accept;

is( $streamproto->transport->read_handle->peerport,
    $serversock->sockport,
    'Protocol is connected to server socket port' );

$clientsock->syswrite( "A message\n" );

undef @lines;

wait_for { @lines };

is( $lines[0], "A message\n", 'Protocol transport works' );

package TestProtocol::Stream;
use base qw( IO::Async::Protocol::Stream );

sub on_read
{
   my $self = shift;
   my ( $buffref, $buffclosed ) = @_;

   return 0 unless $$buffref =~ s/^(.*\n)//;

   push @sub_lines, $1;
   return 1;
}
