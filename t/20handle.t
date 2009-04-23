#!/usr/bin/perl -w

use strict;

use Test::More tests => 43;
use Test::Exception;
use Test::Refcount;

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

my $handle = IO::Async::Handle->new(
   handle => $S1,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
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
is( $writeready, 0, '$writeready while readable' );

$readready = 0;

# Ready $S1 to clear the data
$S1->getline(); # ignore return

$handle->want_writeready( 1 );

$loop->loop_once( 0.1 );

is( $readready,  0, '$readready while writeable' );
is( $writeready, 1, '$writeready while writeable' );

is_refcount( $handle, 2, '$handle has refcount 2 before removing from Loop' );

$loop->remove( $handle );

is_oneref( $handle, '$handle has refcount 1 finally' );

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

my $notifier = IO::Async::Notifier->new(
   read_handle => $S1,
   on_read_ready => sub {},
);

ok( defined $notifier, '$notifier defined' );
isa_ok( $notifier, "IO::Async::Handle", '$notifier isa IO::Async::Handle' );

is( $notifier->read_handle, $S1, '->read_handle returns S1' );

is( $notifier->read_fileno, $S1->fileno, '->read_fileno returns fileno(S1)' );

is_oneref( $notifier, '$notifier has refcount 1' );
