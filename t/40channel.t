#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 8;
use Test::Identity;

use IO::Async::Channel;

use IO::Async::Stream;
use IO::Async::Loop::Poll;
use Storable qw( freeze );

my $loop = IO::Async::Loop::Poll->new;

testing_loop( $loop );

# sync->sync - mostly doesn't involve IO::Async
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

   $channel_wr->close;

   is( $channel_rd->recv, undef, 'Sync mode can be closed' );
}

# async->sync
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

   $channel_wr->close;

   is( $channel_rd->recv, undef, 'Sync mode can be closed' );
}

# sync->async
{
   my ( $pipe_rd, $pipe_wr ) = $loop->pipepair;

   my @recv_queue;
   my $recv_eof;

   my $channel_rd = IO::Async::Channel->new;
   $channel_rd->setup_async_mode(
      stream => my $stream_rd = IO::Async::Stream->new( read_handle => $pipe_rd ),
      on_recv => sub {
         identical( $_[0], $channel_rd, 'Channel passed to on_recv' );
         push @recv_queue, $_[1];
      },
      on_eof => sub {
         $recv_eof++;
      },
   );

   $loop->add( $stream_rd );

   my $channel_wr = IO::Async::Channel->new;
   $channel_wr->setup_sync_mode( $pipe_wr );

   $channel_wr->send( [ data => "by sync" ] );

   wait_for { @recv_queue };

   is_deeply( shift @recv_queue, [ data => "by sync" ], 'Async mode channel can on_recv' );

   $channel_wr->close;

   wait_for { $recv_eof };
   is( $recv_eof, 1, 'Async mode channel can on_eof' );
}
