#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 14;
use Test::Fatal;
use Test::Refcount;

use Fcntl qw( SEEK_SET );
use File::Temp qw( tempfile );

use IO::Async::Loop;

use IO::Async::FileStream;

use constant AUT => $ENV{TEST_QUICK_TIMERS} ? 0.1 : 1;

my $loop = IO::Async::Loop->new();

testing_loop( $loop );

sub mkhandles
{
   my ( $rd, $filename ) = tempfile( "tmpfile.XXXXXX", UNLINK => 1 );
   open my $wr, ">", $filename or die "Cannot reopen file for writing - $!";

   $wr->autoflush( 1 );

   return ( $rd, $wr );
}

{
   my ( $rd, $wr ) = mkhandles;

   my @lines;

   my $filestream = IO::Async::FileStream->new(
      interval => 1 * AUT,
      read_handle => $rd,
      on_read => sub {
         my $self = shift;
         my ( $buffref, $eof ) = @_;

         return 0 unless( $$buffref =~ s/^(.*\n)// );

         push @lines, $1;
         return 1;
      },
   );

   ok( defined $filestream, '$filestream defined' );
   isa_ok( $filestream, "IO::Async::FileStream", '$filestream isa IO::Async::FileStream' );

   is_oneref( $filestream, 'reading $filestream has refcount 1 initially' );

   $loop->add( $filestream );

   is_refcount( $filestream, 2, '$filestream has refcount 2 after adding to Loop' );

   $wr->syswrite( "message\n" );

   is_deeply( \@lines, [], '@lines before wait' );

   wait_for { scalar @lines };

   is_deeply( \@lines, [ "message\n" ], '@lines after wait' );

   $loop->remove( $filestream );
}

# Truncation
{
   my ( $rd, $wr ) = mkhandles;

   my @lines;
   my $truncated;

   my $filestream = IO::Async::FileStream->new(
      interval => 1 * AUT,
      read_handle => $rd,
      on_read => sub {
         my $self = shift;
         my ( $buffref, $eof ) = @_;

         return 0 unless( $$buffref =~ s/^(.*\n)// );

         push @lines, $1;
         return 1;
      },
      on_truncated => sub { $truncated++ },
   );

   $loop->add( $filestream );

   $wr->syswrite( "Some original lines\nin the file\n" );

   wait_for { scalar @lines };
   
   $wr->truncate( 0 );
   sysseek( $wr, 0, SEEK_SET );
   $wr->syswrite( "And another\n" );

   wait_for { @lines == 3 };

   is( $truncated, 1, 'File content truncation detected' );
   is_deeply( \@lines,
      [ "Some original lines\n", "in the file\n", "And another\n" ],
      'All three lines read' );

   $loop->remove( $filestream );
}

# Subclass
my @sub_lines;

{
   my ( $rd, $wr ) = mkhandles;

   my $filestream = TestStream->new(
      read_handle => $rd,
   );

   ok( defined $filestream, 'subclass $filestream defined' );
   isa_ok( $filestream, "IO::Async::FileStream", '$filestream isa IO::Async::FileStream' );

   is_oneref( $filestream, 'subclass $filestream has refcount 1 initially' );

   $loop->add( $filestream );

   is_refcount( $filestream, 2, 'subclass $filestream has refcount 2 after adding to Loop' );

   $wr->syswrite( "message\n" );

   is_deeply( \@sub_lines, [], '@sub_lines before wait' );

   wait_for { scalar @sub_lines };

   is_deeply( \@sub_lines, [ "message\n" ], '@sub_lines after wait' );

   $loop->remove( $filestream );
}

package TestStream;
use base qw( IO::Async::FileStream );

sub on_read
{
   my $self = shift;
   my ( $buffref ) = @_;

   return 0 unless $$buffref =~ s/^(.*\n)//;

   push @sub_lines, $1;
   return 1;
}
