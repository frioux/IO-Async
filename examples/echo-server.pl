#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;

use IO::Async::Loop;
use IO::Async::Listener;

my $PORT = 12345;
my $FAMILY;
my $V6ONLY;

GetOptions(
   'port|p=i' => \$PORT,
   '4'        => sub { $FAMILY = "inet" },
   '6'        => sub { $FAMILY = "inet6" },
   'v6only=i' => \$V6ONLY,
) or exit 1;

my $loop = IO::Async::Loop->new;

my $listener = IO::Async::Listener->new(
   on_stream => sub {
      my $self = shift;
      my ( $stream ) = @_;

      my $socket = $stream->read_handle;
      my $peeraddr = $socket->peerhost . ":" . $socket->peerport;

      print STDERR "Accepted new connection from $peeraddr\n";

      $stream->configure(
         on_read => sub {
            my ( $self, $buffref, $eof ) = @_;

            while( $$buffref =~ s/^(.*\n)// ) {
               # eat a line from the stream input
               $self->write( $1 );
            }

            return 0;
         },

         on_closed => sub {
            print STDERR "Connection from $peeraddr closed\n";
         },
      );

      $loop->add( $stream );
   },
);

$loop->add( $listener );

$listener->listen(
   service  => $PORT,
   socktype => 'stream',
   family   => $FAMILY,
   v6only   => $V6ONLY,

   on_resolve_error => sub { die "Cannot resolve - $_[0]\n"; },
   on_listen_error  => sub { die "Cannot listen\n"; },
);

$loop->run;
