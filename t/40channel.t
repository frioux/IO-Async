#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 3;

use IO::Async::Channel;

use IO::Async::Stream;
use IO::Async::Loop::Poll;
use Storable qw( freeze );

my $loop = IO::Async::Loop::Poll->new;

testing_loop( $loop );

{
   my ( $pipe_rd, $pipe_wr ) = $loop->pipepair;

   my $channel_rd = IO::Async::Channel->new;
   $channel_rd->setup_sync_mode( $pipe_rd );

   my $channel_wr = IO::Async::Channel->new;
   $channel_wr->setup_sync_mode( $pipe_wr );

   $channel_wr->send( [ structure => "here" ] );

   is_deeply( $channel_rd->recv, [ structure => "here" ], 'Sync mode channels can send/recv structures' );

   $channel_wr->send_frozen( freeze [ prefrozen => "data" ] );

   is_deeply( $channel_rd->recv, [ prefrozen => "data" ], 'Sync mode channels can send_frozen' );
}

{
   my ( $pipe_rd, $pipe_wr ) = $loop->pipepair;

   my $channel_rd = IO::Async::Channel->new;
   $channel_rd->setup_sync_mode( $pipe_rd );

   my $channel_wr = IO::Async::Channel->new;
   $channel_wr->setup_async_mode(
      stream => my $stream_wr = IO::Async::Stream->new( write_handle => $pipe_wr ),
   );

   $loop->add( $stream_wr );

   $channel_wr->send( [ data => "by async" ] );

   # Cheat for semi-sync
   my $flushed;
   $stream_wr->write( "", on_flush => sub { $flushed++ } );
   wait_for { $flushed };

   is_deeply( $channel_rd->recv, [ data => "by async" ], 'Async mode channel can send' );

   $loop->remove( $stream_wr );
}
