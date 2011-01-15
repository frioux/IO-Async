#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Loop;
use IO::Async::Stream;

my $PORT = 12345;

my $loop = IO::Async::Loop->new;

my $listener = ChatListener->new();

$loop->add( $listener );

$listener->listen(
   service  => $PORT,
   socktype => 'stream',

   on_resolve_error => sub { die "Cannot resolve - $_[0]\n"; },
   on_listen_error  => sub { die "Cannot listen\n"; },
);

$loop->loop_forever;

package ChatListener;
use base qw( IO::Async::Listener );

my @clients;

sub on_stream
{
   my $self = shift;
   my ( $stream ) = @_;

   # $socket is just an IO::Socket reference
   my $socket = $stream->read_handle;
   my $peeraddr = $socket->peerhost . ":" . $socket->peerport;

   # Inform the others
   $_->write( "$peeraddr joins\n" ) for @clients;

   $stream->configure(
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

   $loop->add( $stream );
   push @clients, $stream;
}
