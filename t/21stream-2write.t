#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 28;
use Test::Refcount;

use POSIX qw( EAGAIN ECONNRESET );

use IO::Async::Loop;

use IO::Async::Stream;

my $loop = IO::Async::Loop->new();

testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

# useful test function
sub read_data
{
   my ( $s ) = @_;

   my $buffer;
   my $ret = $s->sysread( $buffer, 8192 );

   return $buffer if( defined $ret && $ret > 0 );
   die "Socket closed" if( defined $ret && $ret == 0 );
   return "" if( $! == EAGAIN );
   die "Cannot sysread() - $!";
}

my $empty;

my $stream = IO::Async::Stream->new(
   write_handle => $S1,
   on_outgoing_empty => sub { $empty = 1 },
);

ok( defined $stream, 'writing $stream defined' );
isa_ok( $stream, "IO::Async::Stream", 'writing $stream isa IO::Async::Stream' );

is_oneref( $stream, 'writing $stream has refcount 1 initially' );

$loop->add( $stream );

is_refcount( $stream, 2, 'writing $stream has refcount 2 after adding to Loop' );

ok( !$stream->want_writeready, 'want_writeready before write' );
$stream->write( "message\n" );

ok( $stream->want_writeready, 'want_writeready after write' );

wait_for { $empty };

ok( !$stream->want_writeready, 'want_writeready after wait' );
is( $empty, 1, '$empty after writing buffer' );

is( read_data( $S2 ), "message\n", 'data after writing buffer' );

my $flushed;

$stream->write( "hello again\n", on_flush => sub {
   is( $_[0], $stream, 'on_flush $_[0] is $stream' );
   $flushed++
} );

wait_for { $flushed };

is( read_data( $S2 ), "hello again\n", 'flushed data does get flushed' );

my $done;

$stream->write(
   sub {
      is( $_[0], $stream, 'Writersub $_[0] is $stream' );
      return $done++ ? undef : "a lazy message\n";
   },
   on_flush => sub { $flushed++ },
);

$flushed = 0;
wait_for { $flushed };

is( read_data( $S2 ), "a lazy message\n", 'lazy data was written' );

my @chunks = ( "some ", "message chunks ", "here\n" );

$stream->write(
   sub { return shift @chunks },
   on_flush => sub { $flushed++ },
);

$flushed = 0;
wait_for { $flushed };

is( read_data( $S2 ), "some message chunks here\n", 'multiple lazy data was written' );

$stream->configure( autoflush => 1 );
$stream->write( "immediate\n" );

ok( !$stream->want_writeready, 'not want_writeready after autoflush write' );
is( read_data( $S2 ), "immediate\n", 'data after autoflush write' );

$stream->configure( autoflush => 0 );
$stream->write( "partial " );
$stream->configure( autoflush => 1 );
$stream->write( "data\n" );

ok( !$stream->want_writeready, 'not want_writeready after split autoflush write' );
is( read_data( $S2 ), "partial data\n", 'data after split autoflush write' );

is_refcount( $stream, 2, 'writing $stream has refcount 2 before removing from Loop' );

$loop->remove( $stream );

is_oneref( $stream, 'writing $stream refcount 1 finally' );

undef $stream;

$stream = IO::Async::Stream->new(
   write_handle => $S1,
   write_len => 2,
);

$loop->add( $stream );

$stream->write( "partial" );

$loop->loop_once( 0.1 );

is( read_data( $S2 ), "pa", 'data after writing buffer with write_len=2 without write_all');

$loop->loop_once( 0.1 ) for 1 .. 3;

is( read_data( $S2 ), "rtial", 'data finally after writing buffer with write_len=2 without write_all' );

$stream->configure( write_all => 1 );

$stream->write( "partial" );

$loop->loop_once( 0.1 );

is( read_data( $S2 ), "partial", 'data after writing buffer with write_len=2 with write_all');

$loop->remove( $stream );

{
   my $stream = IO::Async::Stream->new;

   undef $flushed;

   $stream->write( "Prequeued data", on_flush => sub { $flushed++ } );

   $stream->configure( write_handle => $S1 );

   $loop->add( $stream );

   wait_for { $flushed };

   ok( 1, 'prequeued data gets flushed' );

   is( read_data( $S2 ), "Prequeued data", 'prequeued data gets written' );

   $loop->remove( $stream );
}

# Socket errors

my ( $ES1, $ES2 ) = $loop->socketpair() or die "Cannot socketpair - $!";

{
   no warnings 'redefine';
   local *IO::Handle::syswrite = sub {
      $! = ECONNRESET;
      return undef;
   };

   my $write_errno;

   $stream = IO::Async::Stream->new(
      write_handle => $ES1,
      on_write_error  => sub { ( undef, $write_errno ) = @_ },
   );

   $loop->add( $stream );

   $stream->write( "hello" );

   wait_for { defined $write_errno };

   cmp_ok( $write_errno, "==", ECONNRESET, 'errno after failed write' );

   $loop->remove( $stream );
}

$stream = IO::Async::Stream->new_for_stdout;
is( $stream->write_handle, \*STDOUT, 'Stream->new_for_stdout->write_handle is STDOUT' );
