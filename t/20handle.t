#!/usr/bin/perl -w

use strict;

use Test::More tests => 62;
use Test::Exception;
use Test::Refcount;
use Test::Warn;

use IO::Async::Loop;

use IO::Async::Handle;

my $loop = IO::Async::Loop->new();

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

dies_ok( sub { IO::Async::Handle->new( handle => "Hello" ) },
         'Not a filehandle' );

my $readready = 0;
my $writeready = 0;

my @rrargs;
my @wrargs;

my $handle = IO::Async::Handle->new(
   handle => $S1,
   on_read_ready  => sub { @rrargs = @_; $readready = 1 },
   on_write_ready => sub { @wrargs = @_; $writeready = 1 },
);

ok( defined $handle, '$handle defined' );
isa_ok( $handle, "IO::Async::Handle", '$handle isa IO::Async::Handle' );

is_oneref( $handle, '$handle has refcount 1 initially' );

is( $handle->read_handle,  $S1, '->read_handle returns S1' );
is( $handle->write_handle, $S1, '->write_handle returns S1' );

is( $handle->read_fileno,  $S1->fileno, '->read_fileno returns fileno(S1)' );
is( $handle->write_fileno, $S1->fileno, '->write_fileno returns fileno(S1)' );

ok( $handle->want_readready,   'want_readready true' );
ok( !$handle->want_writeready, 'want_writeready false' );

$loop->add( $handle );

is_refcount( $handle, 2, '$handle has refcount 2 after adding to Loop' );

$loop->loop_once( 0.1 );

is( $readready,  0, '$readready while idle' );
is( $writeready, 0, '$writeready while idle' );

# Read-ready

$S2->syswrite( "data\n" );

$loop->loop_once( 0.1 );

is( $readready,  1, '$readready while readable' );
is_deeply( \@rrargs, [ $handle ], 'on_read_ready args while readable' );
is( $writeready, 0, '$writeready while readable' );

$S1->getline(); # ignore return

$readready = 0;
my $new_readready = 0;

$handle->configure( on_read_ready => sub { $new_readready = 1 } );

$loop->loop_once( 0.1 );

is( $readready,     0, '$readready while idle after on_read_ready replace' );
is( $new_readready, 0, '$new_readready while idle after on_read_ready replace' );

$S2->syswrite( "data\n" );

$loop->loop_once( 0.1 );

is( $readready,     0, '$readready while readable after on_read_ready replace' );
is( $new_readready, 1, '$new_readready while readable after on_read_ready replace' );

$S1->getline(); # ignore return

# Write-ready

$handle->want_writeready( 1 );

$loop->loop_once( 0.1 );

is( $readready,  0, '$readready while writeable' );
is( $writeready, 1, '$writeready while writeable' );
is_deeply( \@wrargs, [ $handle ], 'on_write_ready args while writeable' );

$writeready = 0;
my $new_writeready = 0;

$handle->configure( on_write_ready => sub { $new_writeready = 1 } );

$loop->loop_once( 0.1 );

is( $writeready,     0, '$writeready while writeable after on_write_ready replace' );
is( $new_writeready, 1, '$new_writeready while writeable after on_write_ready replace' );

undef @rrargs;
undef @wrargs;

is_refcount( $handle, 2, '$handle has refcount 2 before removing from Loop' );

$loop->remove( $handle );

is_oneref( $handle, '$handle has refcount 1 finally' );

undef $handle;

# Subclass

my $sub_readready = 0;
my $sub_writeready = 0;

$handle = TestHandle->new(
   handle => $S1,
);

ok( defined $handle, 'subclass $handle defined' );
isa_ok( $handle, "IO::Async::Handle", 'subclass $handle isa IO::Async::Handle' );

is_oneref( $handle, 'subclass $handle has refcount 1 initially' );

is( $handle->read_handle,  $S1, 'subclass ->read_handle returns S1' );
is( $handle->write_handle, $S1, 'subclass ->write_handle returns S1' );

$loop->add( $handle );

is_refcount( $handle, 2, 'subclass $handle has refcount 2 after adding to Loop' );

$S2->syswrite( "data\n" );

$loop->loop_once( 0.1 );

is( $sub_readready,  1, '$sub_readready while readable' );
is( $sub_writeready, 0, '$sub_writeready while readable' );

$S1->getline(); # ignore return
$sub_readready = 0;

$handle->want_writeready( 1 );

$loop->loop_once( 0.1 );

is( $sub_readready,  0, '$sub_readready while writeable' );
is( $sub_writeready, 1, '$sub_writeready while writeable' );

$loop->remove( $handle );

undef $handle;

$handle = IO::Async::Handle->new(
   read_handle  => \*STDIN,
   write_handle => \*STDOUT,
   on_read_ready  => sub {},
   on_write_ready => sub {},
);

ok( defined $handle, 'defined $handle around STDIN/STDOUT' );
is( $handle->read_handle,  \*STDIN,  '->read_handle returns STDIN' );
is( $handle->write_handle, \*STDOUT, '->write_handle returns STDOUT' );

is_oneref( $handle, '$handle around STDIN/STDOUT has refcount 1' );

undef $handle;

$handle = IO::Async::Handle->new(
   read_handle  => \*STDIN,
   on_read_ready  => sub {},
);

ok( defined $handle, 'defined $handle around STDIN/undef' );
is( $handle->read_handle,  \*STDIN, '->read_handle returns STDIN' );
is( $handle->write_handle, undef,   '->write_handle returns undef' );

is_oneref( $handle, '$handle around STDIN/undef has refcount 1' );

dies_ok( sub { $handle->want_writeready( 1 ); },
         'setting want_writeready with write_handle == undef dies' );
ok( !$handle->want_writeready, 'wantwriteready write_handle == undef false' );

undef $handle;

my $closed = 0;

$handle = IO::Async::Handle->new(
   read_handle => $S1,
   want_writeready => 0,
   on_read_ready => sub {},
   on_closed => sub { $closed = 1 },
);

$handle->close;

is( $closed, 1, '$closed after ->close' );

undef $handle;

# Reopen the testing sockets since we just broke them
( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

$handle = IO::Async::Handle->new(
   write_handle => $S1,
   want_writeready => 1,
   on_write_ready => sub {},
);

ok( defined $handle, 'defined $handle for only write_handle/on_write_ready' );

### Late-binding of handle

$handle = IO::Async::Handle->new(
   want_writeready => 0,
   on_read_ready  => sub { $readready  = 1 },
   on_write_ready => sub { $writeready = 1 },
);

ok( defined $handle, '$handle defined' );

ok( !defined $handle->read_handle,  '->read_handle not defined' );
ok( !defined $handle->write_handle, '->write_handle not defined' );

is_oneref( $handle, '$handle latebount has refcount 1 initially' );

$handle->set_handle( $S1 );

is( $handle->read_handle,  $S1, '->read_handle now S1' );
is( $handle->write_handle, $S1, '->write_handle now S1' );

is_oneref( $handle, '$handle latebount has refcount 1 after set_handle' );

# Legacy upgrade from IO::Async::Notifier

my $notifier;

warning_is {
      $notifier = IO::Async::Notifier->new(
         read_handle => $S1,
         on_read_ready => sub {},
      );
   }
   { carped => "IO::Async::Notifier no longer wraps a filehandle; see instead IO::Async::Handle" },
   'Legacy IO::Async::Notifier to ::Handle upgrade produces warning';


ok( defined $notifier, '$notifier defined' );
isa_ok( $notifier, "IO::Async::Handle", '$notifier isa IO::Async::Handle' );

is( $notifier->read_handle, $S1, '->read_handle returns S1' );

is( $notifier->read_fileno, $S1->fileno, '->read_fileno returns fileno(S1)' );

is_oneref( $notifier, '$notifier has refcount 1' );

package TestHandle;
use base qw( IO::Async::Handle );

sub on_read_ready  { $sub_readready = 1 }
sub on_write_ready { $sub_writeready = 1 }
