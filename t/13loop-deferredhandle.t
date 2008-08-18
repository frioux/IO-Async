#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;
use Test::Exception;

use IO::Async::Loop;
use IO::Async::Stream;

my $loop = IO::Async::Loop->new();

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

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
