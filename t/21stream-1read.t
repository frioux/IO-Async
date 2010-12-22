#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 45;
use Test::Exception;
use Test::Refcount;

use POSIX qw( ECONNRESET );

use IO::Async::Loop;

use IO::Async::Stream;

my $loop = IO::Async::Loop->new();

testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my @lines;

my $stream = IO::Async::Stream->new( 
   read_handle => $S1,
   on_read => sub {
      my $self = shift;
      my ( $buffref, $buffclosed ) = @_;

      return 0 unless( $$buffref =~ s/^(.*\n)// );

      push @lines, $1;
      return 1;
   },
);

ok( defined $stream, 'reading $stream defined' );
isa_ok( $stream, "IO::Async::Stream", 'reading $stream isa IO::Async::Stream' );

is_oneref( $stream, 'reading $stream has refcount 1 initially' );

$loop->add( $stream );

is_refcount( $stream, 2, 'reading $stream has refcount 2 after adding to Loop' );

$S2->syswrite( "message\n" );

is_deeply( \@lines, [], '@lines before wait' );

wait_for { scalar @lines };

is_deeply( \@lines, [ "message\n" ], '@lines after wait' );

undef @lines;

$S2->syswrite( "return" );

$loop->loop_once( 0.1 ); # nothing happens

is_deeply( \@lines, [], '@lines partial still empty' );

$S2->syswrite( "\n" );

wait_for { scalar @lines };

is_deeply( \@lines, [ "return\n" ], '@lines partial completed now received' );

undef @lines;

$S2->syswrite( "hello\nworld\n" );
wait_for { scalar @lines };

is_deeply( \@lines, [ "hello\n", "world\n" ], '@lines two at once' );

undef @lines;
my @new_lines;
$stream->configure( 
   on_read => sub {
      my $self = shift;
      my ( $buffref, $closed ) = @_;

      return 0 unless( $$buffref =~ s/^(.*\n)// );

      push @new_lines, $1;
      return 1;
   },
);

$S2->syswrite( "new\nlines\n" );

wait_for { scalar @new_lines };

is( scalar @lines, 0, '@lines still empty after on_read replace' );
is_deeply( \@new_lines, [ "new\n", "lines\n" ], '@new_lines after on_read replace' );

is_refcount( $stream, 2, 'reading $stream has refcount 2 before removing from Loop' );

$loop->remove( $stream );

is_oneref( $stream, 'reading $stream refcount 1 finally' );

undef $stream;

my @chunks;

$stream = IO::Async::Stream->new(
   read_handle => $S1,
   read_len => 2,
   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      push @chunks, $$buffref;
      $$buffref = "";
   },
);

$loop->add( $stream );

$S2->syswrite( "partial" );

wait_for { scalar @chunks };

is_deeply( \@chunks, [ "pa" ], '@lines with read_len=2 without read_all' );

wait_for { @chunks == 4 };

is_deeply( \@chunks, [ "pa", "rt", "ia", "l" ], '@lines finally with read_len=2 without read_all' );

undef @chunks;
$stream->configure( read_all => 1 );

$S2->syswrite( "partial" );

wait_for { scalar @chunks };

is_deeply( \@chunks, [ "pa", "rt", "ia", "l" ], '@lines with read_len=2 with read_all' );

my $no_on_read_stream;
lives_ok( sub { $no_on_read_stream = IO::Async::Stream->new( handle => $S1 ) },
          'Allowed to construct a Stream without an on_read handler' );
dies_ok( sub { $loop->add( $no_on_read_stream ) },
         'Not allowed to add an on_read-less Stream to a Loop' );

# Subclass

my @sub_lines;

$stream = TestStream->new(
   read_handle => $S1,
);

ok( defined $stream, 'reading subclass $stream defined' );
isa_ok( $stream, "IO::Async::Stream", 'reading $stream isa IO::Async::Stream' );

is_oneref( $stream, 'subclass $stream has refcount 1 initially' );

$loop->add( $stream );

is_refcount( $stream, 2, 'subclass $stream has refcount 2 after adding to Loop' );

$S2->syswrite( "message\n" );

is_deeply( \@sub_lines, [], '@sub_lines before wait' );

wait_for { scalar @sub_lines };

is_deeply( \@sub_lines, [ "message\n" ], '@sub_lines after wait' );

undef @lines;

$loop->remove( $stream );

undef $stream;

# Dynamic on_read chaining

my $outer_count = 0;
my $inner_count = 0;

my $record;

$stream = IO::Async::Stream->new(
   read_handle => $S1,
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

is_oneref( $stream, 'dynamic reading $stream has refcount 1 initially' );

$loop->add( $stream );

$S2->syswrite( "11" ); # No linefeed yet
wait_for { $outer_count > 0 };
is( $outer_count, 1, '$outer_count after idle' );
is( $inner_count, 0, '$inner_count after idle' );

$S2->syswrite( "\n" );
wait_for { $inner_count > 0 };
is( $outer_count, 2, '$outer_count after received length' );
is( $inner_count, 1, '$inner_count after received length' );

$S2->syswrite( "Hello " );
wait_for { $inner_count > 1 };
is( $outer_count, 2, '$outer_count after partial body' );
is( $inner_count, 2, '$inner_count after partial body' );

$S2->syswrite( "world" );
wait_for { $inner_count > 2 };
is( $outer_count, 3, '$outer_count after complete body' );
is( $inner_count, 3, '$inner_count after complete body' );
is( $record, "Hello world", '$record after complete body' );

$loop->remove( $stream );

is_oneref( $stream, 'dynamic reading $stream has refcount 1 finally' );

undef $stream;

# Close

my $closed = 0;
my $loop_during_closed;

$stream = IO::Async::Stream->new( handle => $S1,
   on_read   => sub { },
   on_closed => sub {
      my ( $self ) = @_;
      $closed = 1;
      $loop_during_closed = $self->get_loop;
   },
);

is_oneref( $stream, 'closing $stream has refcount 1 initially' );

$stream->write( "hello" );

$loop->add( $stream );

is_refcount( $stream, 2, 'closing $stream has refcount 2 after adding to Loop' );

is( $closed, 0, 'closed before close' );

$stream->close_when_empty;

is( $closed, 0, 'closed after close' );

wait_for { $closed };

is( $closed, 1, 'closed after wait' );
is( $loop_during_closed, $loop, 'loop during closed' );

ok( !defined $stream->get_loop, 'Stream no longer member of Loop' );

is_oneref( $stream, 'closing $stream refcount 1 finally' );

undef $stream;

# Socket errors

my ( $ES1, $ES2 ) = $loop->socketpair() or die "Cannot socketpair - $!";
$ES2->syswrite( "X" ); # ensuring $ES1 is read-ready

{
   no warnings 'redefine';
   local *IO::Handle::sysread = sub {
      $! = ECONNRESET;
      return undef;
   };

   my $read_errno;

   $stream = IO::Async::Stream->new(
      read_handle => $ES1,
      on_read => sub {},
      on_read_error  => sub { ( undef, $read_errno ) = @_ },
   );

   $loop->add( $stream );

   wait_for { defined $read_errno };

   cmp_ok( $read_errno, "==", ECONNRESET, 'errno after failed read' );

   $loop->remove( $stream );
}

$stream = IO::Async::Stream->new_for_stdin;
is( $stream->read_handle, \*STDIN, 'Stream->new_for_stdin->read_handle is STDIN' );

package TestStream;
use base qw( IO::Async::Stream );

sub on_read
{
   my $self = shift;
   my ( $buffref, $buffclosed ) = @_;

   return 0 unless $$buffref =~ s/^(.*\n)//;

   push @sub_lines, $1;
   return 1;
}
