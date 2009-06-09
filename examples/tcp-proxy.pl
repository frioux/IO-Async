#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Loop;
use IO::Async::Stream;

my $LISTEN_PORT = 12345;
my $CONNECT_HOST = "localhost";
my $CONNECT_PORT = 80;

my $loop = IO::Async::Loop->new;

$loop->listen(
   service  => $LISTEN_PORT,
   socktype => 'stream',

   on_accept => sub {
      my ( $socket1 ) = @_;

      # $socket is just an IO::Socket reference
      my $peeraddr = $socket1->peerhost . ":" . $socket1->peerport;

      print STDERR "Accepted new connection from $peeraddr\n";

      $loop->connect(
         host    => $CONNECT_HOST,
         service => $CONNECT_PORT,

         on_connected => sub {
            my ( $socket2 ) = @_;

            # Now we need two Streams, cross-connected.
            my ( $stream1, $stream2 );

            $stream1 = IO::Async::Stream->new(
               handle => $socket1,

               on_read => sub {
                  my ( $self, $buffref, $closed ) = @_;
                  # Just copy all the data
                  $stream2->write( $$buffref ); $$buffref = "";
                  return 0;
               },
               on_closed => sub {
                  $stream2->close_when_empty;
                  print STDERR "Connection from $peeraddr closed\n";
               },
            );

            $stream2 = IO::Async::Stream->new(
               handle => $socket2,

               on_read => sub {
                  my ( $self, $buffref, $closed ) = @_;
                  # Just copy all the data
                  $stream1->write( $$buffref ); $$buffref = "";
                  return 0;
               },
               on_closed => sub {
                  $stream1->close_when_empty;
                  print STDERR "Connection to $CONNECT_HOST:$CONNECT_PORT closed\n";
               },
            );

            $loop->add( $stream1 );
            $loop->add( $stream2 );
         },

         on_resolve_error => sub { print STDERR "Cannot resolve - $_[0]\n"; },
         on_connect_error => sub { print STDERR "Cannot connect\n"; },
      );
   },

   on_resolve_error => sub { die "Cannot resolve - $_[0]\n"; },
   on_listen_error  => sub { die "Cannot listen\n"; },
);

$loop->loop_forever;
