#!/usr/bin/perl -w

use strict;

use Test::More tests => 19;
use Test::Exception;
use Test::Refcount;

use IO::Async::Loop;
use IO::Async::Notifier;

my $loop = IO::Async::Loop->new;

is_oneref( $loop, '$loop has refcount 1 initially' );

my $notifier = IO::Async::Notifier->new( );

ok( defined $notifier, '$notifier defined' );
isa_ok( $notifier, "IO::Async::Notifier", '$notifier isa IO::Async::Notifier' );

is_oneref( $notifier, '$notifier has refcount 1 initially' );

is( $notifier->get_loop, undef, 'get_loop undef' );

$loop->add( $notifier );

is_oneref( $loop, '$loop has refcount 1 adding Notifier' );
is_refcount( $notifier, 2, '$notifier has refcount 2 after adding to Loop' );

is( $notifier->get_loop, $loop, 'get_loop $loop' );

dies_ok( sub { $loop->add( $notifier ) }, 'adding again produces error' );

$loop->remove( $notifier );

is( $notifier->get_loop, undef, '$notifier->get_loop is undef' );

lives_ok( sub { $notifier->configure; },
          '$notifier->configure no params succeeds' );

dies_ok( sub { $notifier->configure( oranges => 1 ) },
         '$notifier->configure an unrecognised parameter fails' );

my @args;
my $mref = $notifier->_capture_weakself( sub { @args = @_ } );

is_oneref( $notifier, '$notifier has refcount 1 after _capture_weakself' );

$mref->( 123 );
is_deeply( \@args, [ $notifier, 123 ], '@args after invoking $mref' );

undef @args;

is_oneref( $loop, '$loop has refcount 1 finally' );
is_oneref( $notifier, '$notifier has refcount 1 finally' );

undef $loop;

my @subargs;

$notifier = TestNotifier->new;

$mref = $notifier->_capture_weakself( 'frobnicate' );

is_oneref( $notifier, '$notifier has refcount 1 after _capture_weakself on named method' );

$mref->( 456 );
is_deeply( \@subargs, [ $notifier, 456 ], '@subargs after invoking $mref on named method' );

undef @subargs;

is_oneref( $notifier, '$notifier has refcount 1 finally' );

package TestNotifier;
use base qw( IO::Async::Notifier );

sub frobnicate { @subargs = @_ }
