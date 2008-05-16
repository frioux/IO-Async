#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;
use Test::Exception;

use IO::Socket::UNIX;

use IO::Async::Loop::IO_Poll;
use IO::Async::Stream;

my ( $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socketpair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $buffer = "";

my $stream = IO::Async::Stream->new(
   # No handle yet
   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      $buffer .= $$buffref;
      $$buffref =  "";
      return 0;
   },
);

my $loop = IO::Async::Loop::IO_Poll->new();
$loop->add( $stream );

dies_ok( sub { $stream->write( "some text" ) },
         '->write on stream with no IO handle fails' );

$stream->set_handle( $S1 );

$stream->write( "some text" );

$loop->loop_once( 0.1 );

my $buffer2;
$S2->sysread( $buffer2, 8192 );

is( $buffer2, "some text", 'stream-written text appears' );

$S2->syswrite( "more text" );

$loop->loop_once( 0.1 );

is( $buffer, "more text", 'stream-read text appears' );
