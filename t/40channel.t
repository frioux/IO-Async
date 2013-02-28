#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Test;

use Test::More;
use Test::Identity;

use IO::Async::Channel;

use IO::Async::OS;

use IO::Async::Loop::Poll;
use Storable qw( freeze );

my $loop = IO::Async::Loop::Poll->new;

testing_loop( $loop );

# sync->sync - mostly doesn't involve IO::Async
{
   my ( $pipe_rd, $pipe_wr ) = IO::Async::OS->pipepair;

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
   my ( $pipe_rd, $pipe_wr ) = IO::Async::OS->pipepair;

   my $channel_rd = IO::Async::Channel->new;
   $channel_rd->setup_sync_mode( $pipe_rd );

   my $channel_wr = IO::Async::Channel->new;
   $channel_wr->setup_async_mode( write_handle => $pipe_wr );

   $loop->add( $channel_wr );

   $channel_wr->send( [ data => "by async" ] );

   # Cheat for semi-sync
   my $flushed;
   $channel_wr->{stream}->write( "", on_flush => sub { $flushed++ } );
   wait_for { $flushed };

   is_deeply( $channel_rd->recv, [ data => "by async" ], 'Async mode channel can send' );

   $channel_wr->close;

   is( $channel_rd->recv, undef, 'Sync mode can be closed' );
}

# sync->async configured on_recv
{
   my ( $pipe_rd, $pipe_wr ) = IO::Async::OS->pipepair;

   my @recv_queue;
   my $recv_eof;

   my $channel_rd = IO::Async::Channel->new;
   $channel_rd->setup_async_mode( read_handle => $pipe_rd );

   $loop->add( $channel_rd );

   $channel_rd->configure(
      on_recv => sub {
         identical( $_[0], $channel_rd, 'Channel passed to on_recv' );
         push @recv_queue, $_[1];
      },
      on_eof => sub {
         $recv_eof++;
      },
   );

   my $channel_wr = IO::Async::Channel->new;
   $channel_wr->setup_sync_mode( $pipe_wr );

   $channel_wr->send( [ data => "by sync" ] );

   wait_for { @recv_queue };

   is_deeply( shift @recv_queue, [ data => "by sync" ], 'Async mode channel can on_recv' );

   $channel_wr->close;

   wait_for { $recv_eof };
   is( $recv_eof, 1, 'Async mode channel can on_eof' );
}

# sync->async oneshot ->recv
{
   my ( $pipe_rd, $pipe_wr ) = IO::Async::OS->pipepair;

   my $channel_rd = IO::Async::Channel->new;
   $channel_rd->setup_async_mode( read_handle => $pipe_rd );

   $loop->add( $channel_rd );

   my $channel_wr = IO::Async::Channel->new;
   $channel_wr->setup_sync_mode( $pipe_wr );

   $channel_wr->send( [ data => "by sync" ] );

   my $recved;
   $channel_rd->recv(
      on_recv => sub {
         identical( $_[0], $channel_rd, 'Channel passed to ->recv on_recv' );
         $recved = $_[1];
      },
      on_eof => sub { die "Test failed early" },
   );

   wait_for { $recved };

   is_deeply( $recved, [ data => "by sync" ], 'Async mode channel can ->recv on_recv' );

   $channel_wr->close;

   my $recv_eof;
   $channel_rd->recv(
      on_recv => sub { die "Channel recv'ed when not expecting" },
      on_eof  => sub { $recv_eof++ },
   );

   wait_for { $recv_eof };
   is( $recv_eof, 1, 'Async mode channel can ->recv on_eof' );
}

done_testing;
