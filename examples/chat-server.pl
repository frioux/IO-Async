#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Listener;

my $PORT = 12345;

my $loop = IO::Async::Loop->new;

my @clients;

my $listener = IO::Async::Listener->new(
   on_accept => sub {
      my $self = shift;
      my ( $socket ) = @_;

      # $socket is just an IO::Socket reference
      my $peeraddr = $socket->peerhost . ":" . $socket->peerport;

      # Inform the others
      $_->write( "$peeraddr joins\n" ) for @clients;

      my $clientstream = IO::Async::Stream->new(
         handle => $socket,

         on_read => sub {
            my ( $self, $buffref, $closed ) = @_;

            if( $$buffref =~ s/^(.*\n)// ) {
               # eat a line from the stream input

               # Reflect it to all but the stream who wrote it
               $_ == $self or $_->write( "$peeraddr: $1" ) for @clients;

               return 1;
            }

            return 0;
         },

         on_closed => sub {
            my ( $self ) = @_;
            @clients = grep { $_ != $self } @clients;

            # Inform the others
            $_->write( "$peeraddr leaves\n" ) for @clients;
         },
      );

      $loop->add( $clientstream );
      push @clients, $clientstream;
   },
);

$loop->add( $listener );

$listener->listen(
   service  => $PORT,
   socktype => 'stream',

   on_resolve_error => sub { die "Cannot resolve - $_[0]\n"; },
   on_listen_error  => sub { die "Cannot listen\n"; },
);

$loop->loop_forever;
