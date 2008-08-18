#!/usr/bin/perl -w

use strict;

use Test::More tests => 34;
use Test::Exception;

use IO::Async::Loop;
use IO::Async::Notifier;

use IO::Handle;

use POSIX qw( EAGAIN );

dies_ok( sub { IO::Async::Notifier->new( handle => "Hello" ) },
         'Not a socket' );

my $loop = IO::Async::Loop->new;

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

dies_ok( sub { IO::Async::Notifier->new( handle => $S1 ) },
         'No on_read_ready' );

my $ioan = IO::Async::Notifier->new( handle => $S1, want_writeready => 0,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
);

ok( defined $ioan, '$ioan defined' );
isa_ok( $ioan, "IO::Async::Notifier", '$ioan isa IO::Async::Notifier' );

is( $ioan->read_handle,  $S1, '->read_handle returns S1' );
is( $ioan->write_handle, $S1, '->write_handle returns S1' );

is( $ioan->read_fileno,  fileno($S1), '->read_fileno returns fileno(S1)' );
is( $ioan->write_fileno, fileno($S1), '->write_fileno returns fileno(S1)' );

is( $ioan->want_writeready, 0, 'wantwriteready 0' );

is( $ioan->get_loop, undef, '__memberof_loop undef' );

$ioan->want_writeready( 1 );
is( $ioan->want_writeready, 1, 'wantwriteready 1' );

is( $readready, 0, '$readready before call' );
$ioan->on_read_ready;
is( $readready, 1, '$readready after call' );

is( $writeready, 0, '$writeready before call' );
$ioan->on_write_ready;
is( $writeready, 1, '$writeready after call' );

my $ret = $S2->sysread( my $b, 1 );
my $errno = $!;
is( $ret, undef,  '$S2 not readable before close...' );
is( $!+0, EAGAIN, '$S2 read error is EAGAIN before close' );

$ioan->close;

$ret = $S2->sysread( $b, 1 );
is( $ret, 0, '$S2 gives EOF after close' );

undef $ioan;
$ioan = IO::Async::Notifier->new(
   read_handle  => IO::Handle->new_from_fd(fileno(STDIN),  'r'),
   write_handle => IO::Handle->new_from_fd(fileno(STDOUT), 'w'),
   want_writeready => 0,
   on_read_ready  => sub {},
   on_write_ready => sub {},
);

ok( defined $ioan, 'defined $ioan around STDIN/STDOUT' );
is( $ioan->read_fileno,  fileno(STDIN),  '->read_fileno returns fileno(STDIN)' );
is( $ioan->write_fileno, fileno(STDOUT), '->write_fileno returns fileno(STDOUT)' );

$ioan->want_writeready( 1 );
is( $ioan->want_writeready, 1, 'wantwriteready STDOUT 1' );

undef $ioan;
$ioan = IO::Async::Notifier->new(
   read_handle  => \*STDIN,
   want_writeready => 0,
   on_read_ready  => sub {},
);

ok( defined $ioan, 'defined $ioan around STDIN/undef' );
is( $ioan->read_fileno,  fileno(STDIN), '->read_fileno returns fileno(STDIN)' );
is( $ioan->write_fileno, undef,         '->write_fileno returns undef' );

dies_ok( sub { $ioan->want_writeready( 1 ); },
         'setting want_writeready with write_handle == undef dies' );
is( $ioan->want_writeready, 0, 'wantwriteready write_handle == undef 1' );

my $closed = 0;

$ioan = IO::Async::Notifier->new(
   read_handle => \*STDIN,
   want_writeready => 0,
   on_read_ready => sub {},
   on_closed => sub { $closed = 1 },
);

$ioan->close;

is( $closed, 1, '$closed after ->close' );

undef $ioan;
$ioan = IO::Async::Notifier->new(
   write_handle => \*STDOUT,
   want_writeready => 1,
   on_write_ready => sub {},
);

ok( defined $ioan, 'defined $ioan for only write_handle/on_write_ready' );

### Late-binding of handle

$ioan = IO::Async::Notifier->new(
   want_writeready => 0,
   on_read_ready  => sub { $readready  = 1 },
   on_write_ready => sub { $writeready = 1 },
);

ok( defined $ioan, '$ioan defined' );

ok( !defined $ioan->read_handle,  '->read_handle not defined' );
ok( !defined $ioan->write_handle, '->write_handle not defined' );

( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

$ioan->set_handle( $S1 );

is( $ioan->read_handle,  $S1, '->read_handle now S1' );
is( $ioan->write_handle, $S1, '->write_handle now S1' );
