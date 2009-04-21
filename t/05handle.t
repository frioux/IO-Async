#!/usr/bin/perl -w

use strict;

use Test::More tests => 34;
use Test::Exception;

use IO::Async::Loop;
use IO::Async::Handle;

use IO::Handle;

use POSIX qw( EAGAIN );

dies_ok( sub { IO::Async::Handle->new( handle => "Hello" ) },
         'Not a socket' );

my $loop = IO::Async::Loop->new;

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

dies_ok( sub { IO::Async::Handle->new( handle => $S1 ) },
         'No on_read_ready' );

my $handle = IO::Async::Handle->new( handle => $S1, want_writeready => 0,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
);

ok( defined $handle, '$handle defined' );
isa_ok( $handle, "IO::Async::Handle", '$handle isa IO::Async::Handle' );

is( $handle->read_handle,  $S1, '->read_handle returns S1' );
is( $handle->write_handle, $S1, '->write_handle returns S1' );

is( $handle->read_fileno,  fileno($S1), '->read_fileno returns fileno(S1)' );
is( $handle->write_fileno, fileno($S1), '->write_fileno returns fileno(S1)' );

is( $handle->want_writeready, 0, 'wantwriteready 0' );

is( $handle->get_loop, undef, '__memberof_loop undef' );

$handle->want_writeready( 1 );
is( $handle->want_writeready, 1, 'wantwriteready 1' );

is( $readready, 0, '$readready before call' );
$handle->on_read_ready;
is( $readready, 1, '$readready after call' );

is( $writeready, 0, '$writeready before call' );
$handle->on_write_ready;
is( $writeready, 1, '$writeready after call' );

my $ret = $S2->sysread( my $b, 1 );
my $errno = $!;
is( $ret, undef,  '$S2 not readable before close...' );
is( $!+0, EAGAIN, '$S2 read error is EAGAIN before close' );

$handle->close;

$ret = $S2->sysread( $b, 1 );
is( $ret, 0, '$S2 gives EOF after close' );

undef $handle;
$handle = IO::Async::Handle->new(
   read_handle  => IO::Handle->new_from_fd(fileno(STDIN),  'r'),
   write_handle => IO::Handle->new_from_fd(fileno(STDOUT), 'w'),
   want_writeready => 0,
   on_read_ready  => sub {},
   on_write_ready => sub {},
);

ok( defined $handle, 'defined $handle around STDIN/STDOUT' );
is( $handle->read_fileno,  fileno(STDIN),  '->read_fileno returns fileno(STDIN)' );
is( $handle->write_fileno, fileno(STDOUT), '->write_fileno returns fileno(STDOUT)' );

$handle->want_writeready( 1 );
is( $handle->want_writeready, 1, 'wantwriteready STDOUT 1' );

undef $handle;
$handle = IO::Async::Handle->new(
   read_handle  => \*STDIN,
   want_writeready => 0,
   on_read_ready  => sub {},
);

ok( defined $handle, 'defined $handle around STDIN/undef' );
is( $handle->read_fileno,  fileno(STDIN), '->read_fileno returns fileno(STDIN)' );
is( $handle->write_fileno, undef,         '->write_fileno returns undef' );

dies_ok( sub { $handle->want_writeready( 1 ); },
         'setting want_writeready with write_handle == undef dies' );
is( $handle->want_writeready, 0, 'wantwriteready write_handle == undef 1' );

my $closed = 0;

$handle = IO::Async::Handle->new(
   read_handle => \*STDIN,
   want_writeready => 0,
   on_read_ready => sub {},
   on_closed => sub { $closed = 1 },
);

$handle->close;

is( $closed, 1, '$closed after ->close' );

undef $handle;
$handle = IO::Async::Handle->new(
   write_handle => \*STDOUT,
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

( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

$handle->set_handle( $S1 );

is( $handle->read_handle,  $S1, '->read_handle now S1' );
is( $handle->write_handle, $S1, '->write_handle now S1' );
