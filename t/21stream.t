#!/usr/bin/perl -w

use strict;

use Test::More tests => 69;
use Test::Exception;
use Test::Refcount;

use POSIX qw( EAGAIN ECONNRESET );

use IO::Async::Loop;

use IO::Async::Stream;

my $loop = IO::Async::Loop->new();

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

dies_ok( sub { IO::Async::Stream->new( handle => $S1 ) },
         'No on_read' );

lives_ok( sub { IO::Async::Stream->new( write_handle => \*STDOUT ) },
          'Write-only Stream works' );

# useful test function
sub read_data($)
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

my @received;

my $stream = IO::Async::Stream->new( 
   read_handle => $S1,
   on_read => sub {
      my $self = shift;
      my ( $buffref, $buffclosed ) = @_;

      return 0 unless( $$buffref =~ s/^(.*\n)// );

      push @received, $1;
      return 1;
   },
);

ok( defined $stream, 'reading $stream defined' );
isa_ok( $stream, "IO::Async::Stream", 'reading $stream isa IO::Async::Stream' );

is_oneref( $stream, 'reading $stream has refcount 1 initially' );

$loop->add( $stream );

is_refcount( $stream, 2, 'reading $stream has refcount 2 after adding to Loop' );

$S2->syswrite( "message\n" );

is_deeply( \@received, [], '@received before loop_once' );

$loop->loop_once( 0.1 );

is_deeply( \@received, [ "message\n" ], '@received after loop_once' );

undef @received;

$S2->syswrite( "return" );

$loop->loop_once( 0.1 );

is_deeply( \@received, [], '@received partial still empty' );

$S2->syswrite( "\n" );

$loop->loop_once( 0.1 );

is_deeply( \@received, [ "return\n" ], '@received partial completed now received' );

undef @received;

$S2->syswrite( "hello\nworld\n" );

$loop->loop_once( 0.1 );

is_deeply( \@received, [ "hello\n", "world\n" ], '@received two at once' );

my @new_lines;
$stream->configure( on_read => sub {
      my $self = shift;
      my ( $buffref, $closed ) = @_;

      return 0 unless( $$buffref =~ s/^(.*\n)// );

      push @new_lines, $1;
      return 1;
   } );

$S2->syswrite( "new\nlines\n" );

$loop->loop_once( 0.1 );

is_deeply( \@new_lines, [ "new\n", "lines\n" ], '@new_lines after on_read replace' );

is_refcount( $stream, 2, 'reading $stream has refcount 2 before removing from Loop' );

$loop->remove( $stream );

is_oneref( $stream, 'reading $stream refcount 1 finally' );

undef $stream;

# Subclass

my @sub_received;

$stream = TestStream->new(
   read_handle => $S1,
);

ok( defined $stream, 'reading subclass $stream defined' );
isa_ok( $stream, "IO::Async::Stream", 'reading $stream isa IO::Async::Stream' );

is_oneref( $stream, 'subclass $stream has refcount 1 initially' );

$loop->add( $stream );

is_refcount( $stream, 2, 'subclass $stream has refcount 2 after adding to Loop' );

$S2->syswrite( "message\n" );

is_deeply( \@sub_received, [], '@sub_received before loop_once' );

$loop->loop_once( 0.1 );

is_deeply( \@sub_received, [ "message\n" ], '@sub_received after loop_once' );

undef @received;

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
$loop->loop_once( 0.1 );
is( $outer_count, 1, '$outer_count after idle' );
is( $inner_count, 0, '$inner_count after idle' );

$S2->syswrite( "\n" );
$loop->loop_once( 0.1 );
is( $outer_count, 2, '$outer_count after received length' );
is( $inner_count, 1, '$inner_count after received length' );

$S2->syswrite( "Hello " );
$loop->loop_once( 0.1 );
is( $outer_count, 2, '$outer_count after partial body' );
is( $inner_count, 2, '$inner_count after partial body' );

$S2->syswrite( "world" );
$loop->loop_once( 0.1 );
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

$loop->loop_once( 0.1 );

ok( !$stream->want_writeready, 'want_writeready after loop_once' );
is( $empty, 1, '$empty after writing buffer' );

is( read_data( $S2 ), "message\n", 'data after writing buffer' );

is_refcount( $stream, 2, 'writing $stream has refcount 2 before removing from Loop' );

$loop->remove( $stream );

is_oneref( $stream, 'writing $stream refcount 1 finally' );

undef $stream;

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

      push @received, $1;
      return 1;
   },
);

is_oneref( $stream, 'split read/write $stream has refcount 1 initially' );

undef @received;

$loop->add( $stream );

is_refcount( $stream, 2, 'split read/write $stream has refcount 2 after adding to Loop' );

$stream->write( "message\n" );

$loop->loop_once( 0.1 );

is( read_data( $S4 ), "message\n", '$S4 receives data from split stream' );
is( read_data( $S1 ), "",          '$S1 empty from split stream' );

$S1->syswrite( "reverse\n" );

$loop->loop_once( 0.1 );

is_deeply( \@received, [ "reverse\n" ], '@received on response to split stream' );

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

$loop->loop_once( 1 ) or die "Nothing ready after 1 second";

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

$loop->loop_once( 0.1 );

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

$loop->loop_once( 0.1 );

cmp_ok( $read_errno, "==", ECONNRESET, 'errno after failed read' );

$loop->remove( $stream );

$stream = IO::Async::Stream->new(
   write_handle => $ES1,
   on_write_error  => sub { ( undef, $write_errno ) = @_ },
);

$loop->add( $stream );

$stream->write( "hello" );

$loop->loop_once( 0.1 );

cmp_ok( $write_errno, "==", ECONNRESET, 'errno after failed write' );

$loop->remove( $stream );

undef $stream;

package TestStream;
use base qw( IO::Async::Stream );

sub on_read
{
   my $self = shift;
   my ( $buffref, $buffclosed ) = @_;

   return 0 unless $$buffref =~ s/^(.*\n)//;

   push @sub_received, $1;
   return 1;
}

package ErrorSocket;

use base qw( IO::Socket );
our $errno;

sub sysread  { $! = $errno; undef; }
sub syswrite { $! = $errno; undef; }
sub close    { }
