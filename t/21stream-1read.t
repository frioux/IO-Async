#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 54;
use Test::Fatal;
use Test::Refcount;

use IO::File;
use POSIX qw( ECONNRESET );

use IO::Async::Loop;

use IO::Async::Stream;

my $loop = IO::Async::Loop->new;

testing_loop( $loop );

sub mkhandles
{
   my ( $rd, $wr ) = $loop->pipepair or die "Cannot pipe() - $!";
   # Need handles in nonblocking mode
   $rd->blocking( 0 );
   $wr->blocking( 0 );

   return ( $rd, $wr );
}

{
   my ( $rd, $wr ) = mkhandles;

   my @lines;

   my $stream = IO::Async::Stream->new( 
      read_handle => $rd,
      on_read => sub {
         my $self = shift;
         my ( $buffref, $eof ) = @_;

         push @lines, $1 while $$buffref =~ s/^(.*\n)//;
         return 0;
      },
   );

   ok( defined $stream, 'reading $stream defined' );
   isa_ok( $stream, "IO::Async::Stream", 'reading $stream isa IO::Async::Stream' );

   is_oneref( $stream, 'reading $stream has refcount 1 initially' );

   $loop->add( $stream );

   is_refcount( $stream, 2, 'reading $stream has refcount 2 after adding to Loop' );

   $wr->syswrite( "message\n" );

   is_deeply( \@lines, [], '@lines before wait' );

   wait_for { scalar @lines };

   is_deeply( \@lines, [ "message\n" ], '@lines after wait' );

   undef @lines;

   $wr->syswrite( "return" );

   $loop->loop_once( 0.1 ); # nothing happens

   is_deeply( \@lines, [], '@lines partial still empty' );

   $wr->syswrite( "\n" );

   wait_for { scalar @lines };

   is_deeply( \@lines, [ "return\n" ], '@lines partial completed now received' );

   undef @lines;

   $wr->syswrite( "hello\nworld\n" );
   wait_for { scalar @lines };

   is_deeply( \@lines, [ "hello\n", "world\n" ], '@lines two at once' );

   undef @lines;
   my @new_lines;
   $stream->configure( 
      on_read => sub {
         my $self = shift;
         my ( $buffref, $eof ) = @_;

         push @new_lines, $1 while $$buffref =~ s/^(.*\n)//;
         return 0;
      },
   );

   $wr->syswrite( "new\nlines\n" );

   wait_for { scalar @new_lines };

   is( scalar @lines, 0, '@lines still empty after on_read replace' );
   is_deeply( \@new_lines, [ "new\n", "lines\n" ], '@new_lines after on_read replace' );

   is_refcount( $stream, 2, 'reading $stream has refcount 2 before removing from Loop' );

   $loop->remove( $stream );

   is_oneref( $stream, 'reading $stream refcount 1 finally' );
}

{
   my ( $rd, $wr ) = mkhandles;

   my @chunks;

   my $stream = IO::Async::Stream->new(
      read_handle => $rd,
      read_len => 2,
      on_read => sub {
         my ( $self, $buffref, $eof ) = @_;
         push @chunks, $$buffref;
         $$buffref = "";
      },
   );

   $loop->add( $stream );

   $wr->syswrite( "partial" );

   wait_for { scalar @chunks };

   is_deeply( \@chunks, [ "pa" ], '@lines with read_len=2 without read_all' );

   wait_for { @chunks == 4 };

   is_deeply( \@chunks, [ "pa", "rt", "ia", "l" ], '@lines finally with read_len=2 without read_all' );

   undef @chunks;
   $stream->configure( read_all => 1 );

   $wr->syswrite( "partial" );

   wait_for { scalar @chunks };

   is_deeply( \@chunks, [ "pa", "rt", "ia", "l" ], '@lines with read_len=2 with read_all' );

   $loop->remove( $stream );
}

{
   my ( $rd, $wr ) = mkhandles;

   my $no_on_read_stream;
   ok( !exception { $no_on_read_stream = IO::Async::Stream->new( read_handle => $rd ) },
       'Allowed to construct a Stream without an on_read handler' );
   ok( exception { $loop->add( $no_on_read_stream ) },
       'Not allowed to add an on_read-less Stream to a Loop' );
}

# Subclass
my @sub_lines;

{
   my ( $rd, $wr ) = mkhandles;

   my $stream = TestStream->new(
      read_handle => $rd,
   );

   ok( defined $stream, 'reading subclass $stream defined' );
   isa_ok( $stream, "IO::Async::Stream", 'reading $stream isa IO::Async::Stream' );

   is_oneref( $stream, 'subclass $stream has refcount 1 initially' );

   $loop->add( $stream );

   is_refcount( $stream, 2, 'subclass $stream has refcount 2 after adding to Loop' );

   $wr->syswrite( "message\n" );

   is_deeply( \@sub_lines, [], '@sub_lines before wait' );

   wait_for { scalar @sub_lines };

   is_deeply( \@sub_lines, [ "message\n" ], '@sub_lines after wait' );

   $loop->remove( $stream );
}

# Dynamic on_read chaining
{
   my ( $rd, $wr ) = mkhandles;

   my $outer_count = 0;
   my $inner_count = 0;

   my $record;

   my $stream = IO::Async::Stream->new(
      read_handle => $rd,
      on_read => sub {
         my ( $self, $buffref, $eof ) = @_;
         $outer_count++;

         return 0 unless $$buffref =~ s/^(.*\n)//;

         my $length = $1;

         return sub {
            my ( $self, $buffref, $eof ) = @_;
            $inner_count++;

            return 0 unless length $$buffref >= $length;

            $record = substr( $$buffref, 0, $length, "" );

            return undef;
         }
      },
   );

   is_oneref( $stream, 'dynamic reading $stream has refcount 1 initially' );

   $loop->add( $stream );

   $wr->syswrite( "11" ); # No linefeed yet
   wait_for { $outer_count > 0 };
   is( $outer_count, 1, '$outer_count after idle' );
   is( $inner_count, 0, '$inner_count after idle' );

   $wr->syswrite( "\n" );
   wait_for { $inner_count > 0 };
   is( $outer_count, 2, '$outer_count after received length' );
   is( $inner_count, 1, '$inner_count after received length' );

   $wr->syswrite( "Hello " );
   wait_for { $inner_count > 1 };
   is( $outer_count, 2, '$outer_count after partial body' );
   is( $inner_count, 2, '$inner_count after partial body' );

   $wr->syswrite( "world" );
   wait_for { $inner_count > 2 };
   is( $outer_count, 3, '$outer_count after complete body' );
   is( $inner_count, 3, '$inner_count after complete body' );
   is( $record, "Hello world", '$record after complete body' );

   $loop->remove( $stream );

   is_oneref( $stream, 'dynamic reading $stream has refcount 1 finally' );
}

# EOF
{
   my ( $rd, $wr ) = mkhandles;

   my $eof = 0;
   my $partial;

   my $stream = IO::Async::Stream->new( read_handle => $rd,
      on_read => sub {
         my ( undef, $buffref, $eof ) = @_;
         $partial = $$buffref if $eof;
         return 0;
      },
      on_read_eof => sub { $eof++ },
   );

   $loop->add( $stream );

   $wr->syswrite( "Incomplete" );

   $wr->close;

   is( $eof, 0, 'EOF indication before wait' );

   wait_for { $eof };

   is( $eof, 1, 'EOF indication after wait' );
   is( $partial, "Incomplete", 'EOF stream retains partial input' );

   ok( !defined $stream->loop, 'EOF stream no longer member of Loop' );
   ok( !defined $stream->read_handle, 'Stream no longer has a read_handle' );
}

# Disabled close_on_read_eof
{
   my ( $rd, $wr ) = mkhandles;

   my $eof = 0;
   my $partial;

   my $stream = IO::Async::Stream->new( read_handle => $rd,
      on_read => sub {
         my ( undef, $buffref, $eof ) = @_;
         $partial = $$buffref if $eof;
         return 0;
      },
      on_read_eof => sub { $eof++ },
      close_on_read_eof => 0,
   );

   $loop->add( $stream );

   $wr->syswrite( "Incomplete" );

   $wr->close;

   is( $eof, 0, 'EOF indication before wait' );

   wait_for { $eof };

   is( $eof, 1, 'EOF indication after wait' );
   is( $partial, "Incomplete", 'EOF stream retains partial input' );

   ok( defined $stream->loop, 'EOF stream still member of Loop' );
   ok( defined $stream->read_handle, 'Stream still has a read_handle' );
}

# Close
{
   my ( $rd, $wr ) = mkhandles;

   my $closed = 0;
   my $loop_during_closed;

   my $stream = IO::Async::Stream->new( read_handle => $rd,
      on_read   => sub { },
      on_closed => sub {
         my ( $self ) = @_;
         $closed = 1;
         $loop_during_closed = $self->loop;
      },
   );

   is_oneref( $stream, 'closing $stream has refcount 1 initially' );

   $loop->add( $stream );

   is_refcount( $stream, 2, 'closing $stream has refcount 2 after adding to Loop' );

   is( $closed, 0, 'closed before close' );

   $stream->close;

   is( $closed, 1, 'closed after close' );
   is( $loop_during_closed, $loop, 'loop during closed' );

   ok( !defined $stream->loop, 'Stream no longer member of Loop' );

   is_oneref( $stream, 'closing $stream refcount 1 finally' );
}

# Errors
{
   my ( $rd, $wr ) = mkhandles;
   $wr->syswrite( "X" ); # ensuring $rd is read-ready

   no warnings 'redefine';
   local *IO::Handle::sysread = sub {
      $! = ECONNRESET;
      return undef;
   };

   my $read_errno;

   my $stream = IO::Async::Stream->new(
      read_handle => $rd,
      on_read => sub {},
      on_read_error  => sub { ( undef, $read_errno ) = @_ },
   );

   $loop->add( $stream );

   wait_for { defined $read_errno };

   cmp_ok( $read_errno, "==", ECONNRESET, 'errno after failed read' );

   $loop->remove( $stream );
}

{
   STDIN->binmode; # Avoid harmless warning in case -CS is in effect
   my $stream = IO::Async::Stream->new_for_stdin;
   is( $stream->read_handle, \*STDIN, 'Stream->new_for_stdin->read_handle is STDIN' );
}

package TestStream;
use base qw( IO::Async::Stream );

sub on_read
{
   my $self = shift;
   my ( $buffref, $eof ) = @_;

   return 0 unless $$buffref =~ s/^(.*\n)//;

   push @sub_lines, $1;
   return 1;
}
