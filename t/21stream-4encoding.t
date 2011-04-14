#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 7;
use Test::Fatal;
use Test::Refcount;

use POSIX qw( EAGAIN );

use IO::Async::Loop;

use IO::Async::Stream;

my $loop = IO::Async::Loop->new();

testing_loop( $loop );

sub mkhandles
{
   my ( $rd, $wr ) = $loop->pipepair or die "Cannot pipe() - $!";
   # Need handles in nonblocking mode
   $rd->blocking( 0 );
   $wr->blocking( 0 );

   return ( $rd, $wr );
}

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

# To test correct multi-byte encoding handling, we'll use a UTF-8 character
# that requires multiple bytes. Furthermore we'll use one that doesn't appear
# in Latin-1
#
# 'ĉ' [U+0109] - LATIN SMALL LETTER C WITH CIRCUMFLEX
#    :0xc4 0x89

# Read encoding
{
   my ( $rd, $wr ) = mkhandles;

   my $read = "";
   my $stream = IO::Async::Stream->new(
      read_handle => $rd,
      encoding => "UTF-8",
      on_read => sub {
         $read = ${$_[1]};
         ${$_[1]} = "";
         return 0;
      },
   );

   $loop->add( $stream );

   $wr->syswrite( "\xc4\x89" );

   wait_for { length $read };

   is( $read, "\x{109}", 'Unicode characters read by on_read' );

   $wr->syswrite( "\xc4\x8a\xc4" );

   $read = "";
   wait_for { length $read };

   is( $read, "\x{10a}", 'Partial UTF-8 character not yet visible' );

   $wr->syswrite( "\x8b" );

   $read = "";
   wait_for { length $read };

   is( $read, "\x{10b}", 'Partial UTF-8 character visible after completion' );

   # 0xfe is never a valid UTF-8 byte
   $wr->syswrite( "\xfe" );

   $read = "";
   wait_for { length $read };

   is( $read, "\x{fffd}", 'Invalid UTF-8 byte yields U+FFFD' );

   $loop->remove( $stream );
}

# Write encoding
{
   my ( $rd, $wr ) = mkhandles;

   my $stream = IO::Async::Stream->new(
      write_handle => $wr,
      encoding => "UTF-8",
   );

   $loop->add( $stream );

   my $flushed;
   $stream->write( "\x{109}", on_flush => sub { $flushed++ } );

   wait_for { $flushed };

   is( read_data( $rd ), "\xc4\x89", 'UTF-8 bytes written by ->write' );

   $stream->configure( write_len => 1 );

   $stream->write( "\x{109}" );

   my $byte;

   $loop->loop_once while !length( $byte = read_data( $rd ) );
   is( $byte, "\xc4", 'First UTF-8 byte written with write_len 1' );

   $loop->loop_once while !length( $byte = read_data( $rd ) );
   is( $byte, "\x89", 'Remaining UTF-8 byte written with write_len 1' );

   $loop->remove( $stream );
}
