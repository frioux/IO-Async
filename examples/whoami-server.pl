#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Listener;

my $PORT = 12345;

my $loop = IO::Async::Loop->new;

my $listener = IO::Async::Listener->new(
   on_accept => sub {
      my $self = shift;
      my ( $socket ) = @_;

      # $socket is just an IO::Socket reference
      my $peeraddr = $socket->peerhost . ":" . $socket->peerport;

      my $clientstream = IO::Async::Stream->new(
         write_handle => $socket,
      );

      $loop->add( $clientstream );

      $clientstream->write( "Your address is " . $peeraddr . "\n" );

      $loop->resolver->getnameinfo(
         addr => $socket->peername,

         on_resolved => sub {
            my ( $host, $service ) = @_;
            $clientstream->write( "You are $host:$service\n" );
            $clientstream->close_when_empty;
         },
         on_error => sub {
            $clientstream->write( "Cannot resolve your address - $_[-1]\n" );
            $clientstream->close_when_empty;
         },
      );
   },
);

$loop->add( $listener );

$listener->listen(
   service  => $PORT,
   socktype => 'stream',

   on_resolve_error => sub { die "Cannot resolve - $_[0]\n"; },
   on_listen_error  => sub { die "Cannot listen\n"; },
);

$loop->run;
