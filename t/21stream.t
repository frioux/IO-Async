#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 86;
use Test::Exception;
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

# Reading

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

{
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
}

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

# Writing

my $empty;

$stream = IO::Async::Stream->new(
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

{
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
}

# Split reading/writing to different handles

my ( $S3, $S4 ) = $loop->socketpair() or die "Cannot socketpair - $!";

$S3->blocking( 0 );
$S4->blocking( 0 );

$stream = IO::Async::Stream->new(
   read_handle => $S2,
   write_handle => $S3,
   on_read => sub {
      my $self = shift;
      my ( $buffref, $closed ) = @_;

      return 0 unless( $$buffref =~ s/^(.*\n)// );

      push @lines, $1;
      return 1;
   },
);

is_oneref( $stream, 'split read/write $stream has refcount 1 initially' );

undef @lines;

$loop->add( $stream );

is_refcount( $stream, 2, 'split read/write $stream has refcount 2 after adding to Loop' );

$stream->write( "message\n" );

$loop->loop_once( 0.1 );

is( read_data( $S4 ), "message\n", '$S4 receives data from split stream' );
is( read_data( $S1 ), "",          '$S1 empty from split stream' );

$S1->syswrite( "reverse\n" );

$loop->loop_once( 0.1 );

is_deeply( \@lines, [ "reverse\n" ], '@lines on response to split stream' );

is_refcount( $stream, 2, 'split read/write $stream has refcount 2 before removing from Loop' );

$loop->remove( $stream );

is_oneref( $stream, 'split read/write $stream refcount 1 finally' );

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

# Make two sets of sockets now, so that we know they'll definitely have
# different FDs
( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";
( $S3, $S4 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$_->blocking( 0 ) for $S1, $S2, $S3, $S4;

my $buffer = "";

$stream = IO::Async::Stream->new(
   # No handle yet
   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      $buffer .= $$buffref;
      $$buffref =  "";
      return 0;
   },
   on_closed => sub {
      my ( $self ) = @_;
      $closed = 1;
   },
);

is_oneref( $stream, 'latehandle $stream has refcount 1 initially' );

$loop->add( $stream );

is_refcount( $stream, 2, 'latehandle $stream has refcount 2 after adding to Loop' );

dies_ok( sub { $stream->write( "some text" ) },
         '->write on stream with no IO handle fails' );

$stream->set_handle( $S1 );

is_refcount( $stream, 2, 'latehandle $stream has refcount 2 after setting a handle' );

$stream->write( "some text" );

$loop->loop_once( 0.1 );

my $buffer2;
$S2->sysread( $buffer2, 8192 );

is( $buffer2, "some text", 'stream-written text appears' );

$S2->syswrite( "more text" );

wait_for { length $buffer };

is( $buffer, "more text", 'stream-read text appears' );

$stream->close_when_empty;

is( $closed, 1, 'closed after close' );

ok( !defined $stream->get_loop, 'Stream no longer member of Loop' );

is_oneref( $stream, 'latehandle $stream refcount 1 finally' );

# Now try re-opening the stream with a new handle, and check it continues to
# work

$loop->add( $stream );

$stream->set_handle( $S3 );

$stream->write( "more text" );

$loop->loop_once( 0.1 );

undef $buffer2;
$S4->sysread( $buffer2, 8192 );

is( $buffer2, "more text", 'stream-written text appears after reopen' );

$loop->remove( $stream );

undef $stream;

{
   my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot socketpair - $!";

   my $stream = IO::Async::Stream->new(
      handle => $S1,
      on_read => sub { },
   );

   $stream->write( "hello" );

   $loop->add( $stream );

   is_refcount( $stream, 2, '$stream has two references' );
   undef $stream; # Only ref is now in the Loop

   $S2->close;

   # $S1 should now be both read- and write-ready.
   lives_ok sub { $loop->loop_once }, 'read+write-ready closed Stream doesn\'t die';
}

# Socket errors

my ( $ES1, $ES2 ) = $loop->socketpair() or die "Cannot socketpair - $!";
$ES2->syswrite( "X" ); # ensuring $ES1 is read- and write-ready
# cheating and hackery
bless $ES1, "ErrorSocket";

$ErrorSocket::errno = ECONNRESET;

my $read_errno;
my $write_errno;

$stream = IO::Async::Stream->new(
   read_handle => $ES1,
   on_read => sub {},
   on_read_error  => sub { ( undef, $read_errno ) = @_ },
);

$loop->add( $stream );

wait_for { defined $read_errno };

cmp_ok( $read_errno, "==", ECONNRESET, 'errno after failed read' );

$loop->remove( $stream );

$stream = IO::Async::Stream->new(
   write_handle => $ES1,
   on_write_error  => sub { ( undef, $write_errno ) = @_ },
);

$loop->add( $stream );

$stream->write( "hello" );

wait_for { defined $write_errno };

cmp_ok( $write_errno, "==", ECONNRESET, 'errno after failed write' );

$loop->remove( $stream );

undef $stream;

$stream = IO::Async::Stream->new_for_stdin;
is( $stream->read_handle, \*STDIN, 'Stream->new_for_stdin->read_handle is STDIN' );

$stream = IO::Async::Stream->new_for_stdout;
is( $stream->write_handle, \*STDOUT, 'Stream->new_for_stdout->write_handle is STDOUT' );

$stream = IO::Async::Stream->new_for_stdio;
is( $stream->read_handle,  \*STDIN,  'Stream->new_for_stdio->read_handle is STDIN' );
is( $stream->write_handle, \*STDOUT, 'Stream->new_for_stdio->write_handle is STDOUT' );

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

package ErrorSocket;

use base qw( IO::Socket );
our $errno;

sub sysread  { $! = $errno; undef; }
sub syswrite { $! = $errno; undef; }
sub close    { }
