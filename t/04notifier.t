#!/usr/bin/perl -w

use strict;

use Test::More tests => 38;
use Test::Fatal;
use Test::Refcount;

use IO::Async::Loop;
use IO::Async::Notifier;

my $loop = IO::Async::Loop->new;

is_refcount( $loop, 2, '$loop has refcount 2 initially' );

is_deeply( [ $loop->notifiers ],
           [],
           '$loop->notifiers empty' );

my $notifier = IO::Async::Notifier->new(
   notifier_name => "test1",
);

ok( defined $notifier, '$notifier defined' );
isa_ok( $notifier, "IO::Async::Notifier", '$notifier isa IO::Async::Notifier' );

is_oneref( $notifier, '$notifier has refcount 1 initially' );

is( $notifier->notifier_name, "test1", '$notifier->notifier_name' );

is( $notifier->get_loop, undef, 'get_loop undef' );

$loop->add( $notifier );

is_refcount( $loop, 2, '$loop has refcount 2 adding Notifier' );
is_refcount( $notifier, 2, '$notifier has refcount 2 after adding to Loop' );

is( $notifier->get_loop, $loop, 'get_loop $loop' );

is_deeply( [ $loop->notifiers ],
           [ $notifier ],
           '$loop->notifiers contains new Notifier' );

ok( exception { $loop->add( $notifier ) }, 'adding again produces error' );

$loop->remove( $notifier );

is( $notifier->get_loop, undef, '$notifier->get_loop is undef' );

is_deeply( [ $loop->notifiers ],
           [],
           '$loop->notifiers empty once more' );

ok( !exception { $notifier->configure; },
    '$notifier->configure no params succeeds' );

ok( exception { $notifier->configure( oranges => 1 ) },
    '$notifier->configure an unrecognised parameter fails' );

my @args;
my $mref = $notifier->_capture_weakself( sub { @args = @_ } );

is_oneref( $notifier, '$notifier has refcount 1 after _capture_weakself' );

$mref->( 123 );
is_deeply( \@args, [ $notifier, 123 ], '@args after invoking $mref' );

my @callstack;
$notifier->_capture_weakself( sub {
   my $level = 0;
   push @callstack, [ (caller $level++)[0,3] ] while defined caller $level;
} )->();

is_deeply( \@callstack,
           [ [ "main", "main::__ANON__" ] ],
           'trampoline does not appear in _capture_weakself callstack' );

undef @args;

$mref = $notifier->_replace_weakself( sub { @args = @_ } );

is_oneref( $notifier, '$notifier has refcount 1 after _replace_weakself' );

my $outerself = bless [], "OtherClass";
$mref->( $outerself, 456 );
is_deeply( \@args, [ $notifier, 456 ], '@args after invoking replacer $mref' );

isa_ok( $outerself, "OtherClass", '$outerself unchanged' );

undef @args;

is_refcount( $loop, 2, '$loop has refcount 2 finally' );
is_oneref( $notifier, '$notifier has refcount 1 finally' );

undef $loop;

my @subargs;

$notifier = TestNotifier->new;

$mref = $notifier->_capture_weakself( 'frobnicate' );

is_oneref( $notifier, '$notifier has refcount 1 after _capture_weakself on named method' );

$mref->( 456 );
is_deeply( \@subargs, [ $notifier, 456 ], '@subargs after invoking $mref on named method' );

{
   undef @subargs;
   my @newargs;

   no warnings 'redefine';
   local *TestNotifier::frobnicate = sub { @newargs = @_; };

   $mref->( 321 );

   is_deeply( \@subargs, [], '@subargs empty after TestNotifier::frobnicate replacement' );
   is_deeply( \@newargs, [ $notifier, 321 ], '@newargs after TestNotifier::frobnicate replacement' );
}

undef @subargs;

ok( exception { $notifier->_capture_weakself( 'cannotdo' ) },
    '$notifier->_capture_weakself on unknown method name fails' );

$notifier->invoke_event( 'frobnicate', 78 );
is_deeply( \@subargs, [ $notifier, 78 ], '@subargs after ->invoke_event' );

undef @subargs;

is_deeply( $notifier->maybe_invoke_event( 'frobnicate', 'a'..'c' ),
           [ $notifier, 'a'..'c' ],
           'return value from ->maybe_invoke_event' );

is( $notifier->maybe_invoke_event( 'mangle' ), undef, 'return value from ->maybe_invoke_event on missing event' );

undef @subargs;

my $cb = $notifier->make_event_cb( 'frobnicate' );

is( ref $cb, "CODE", '->make_event_cb returns a CODE reference' );
is_oneref( $notifier, '$notifier has refcount 1 after ->make_event_cb' );

$cb->( 90 );
is_deeply( \@subargs, [ $notifier, 90 ], '@subargs after ->make_event_cb->()' );

isa_ok( $notifier->maybe_make_event_cb( 'frobnicate' ), "CODE", '->maybe_make_event_cb yields CODE ref' );
is( $notifier->maybe_make_event_cb( 'mangle' ), undef, '->maybe_make_event_cb on missing event yields undef' );

undef @subargs;

is_oneref( $notifier, '$notifier has refcount 1 finally' );

package TestNotifier;
use base qw( IO::Async::Notifier );

sub frobnicate { @subargs = @_ }
