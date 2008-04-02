#!/usr/bin/perl -w

use strict;

use Test::More tests => 9;

use IO::Socket::UNIX;

use IO::Async::Stream;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $outer_count = 0;
my $inner_count = 0;

my $record;

my $stream = IO::Async::Stream->new(
   handle => $S1,
   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      $outer_count++;

      return 0 unless $$buffref =~ s/^(.*\n)//;

      my $length = $1;

      return sub {
         my ( $self, $buffref, $closed ) = @_;
         $inner_count++;

         return 0 unless length $$buffref >= $length;

         $record = substr( $$buffref, 0, $length, "" );

         return undef;
      }
   },
);

$S2->write( "11" ); # No linefeed yet
$stream->on_read_ready;
is( $outer_count, 1, '$outer_count after idle' );
is( $inner_count, 0, '$inner_count after idle' );

$S2->write( "\n" );
$stream->on_read_ready;
is( $outer_count, 2, '$outer_count after received length' );
is( $inner_count, 1, '$inner_count after received length' );

$S2->write( "Hello " );
$stream->on_read_ready;
is( $outer_count, 2, '$outer_count after partial body' );
is( $inner_count, 2, '$inner_count after partial body' );

$S2->write( "world" );
$stream->on_read_ready;
is( $outer_count, 3, '$outer_count after complete body' );
is( $inner_count, 3, '$inner_count after complete body' );
is( $record, "Hello world", '$record after complete body' );
