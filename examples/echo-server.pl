#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Loop;
use IO::Async::Stream;

my $PORT = 12345;

my $loop = IO::Async::Loop->new;

$loop->listen(
   service  => $PORT,
   socktype => 'stream',

   on_accept => sub {
      my ( $socket ) = @_;

      # $socket is just an IO::Socket reference
      my $peeraddr = $socket->peerhost . ":" . $socket->peerport;

      print STDERR "Accepted new connection from $peeraddr\n";

      my $clientstream = IO::Async::Stream->new(
         handle => $socket,

         on_read => sub {
            my ( $self, $buffref, $closed ) = @_;

            if( $$buffref =~ s/^(.*\n)// ) {
               # eat a line from the stream input
               my $line = $1;
               $self->write( $line );

               return 1;
            }

            return 0;
         },

         on_closed => sub {
            print STDERR "Connection from $peeraddr closed\n";
         },
      );

      $loop->add( $clientstream );
   },

   on_resolve_error => sub { die "Cannot resolve - $_[0]\n"; },
   on_listen_error  => sub { die "Cannot listen\n"; },
);

$loop->loop_forever;
