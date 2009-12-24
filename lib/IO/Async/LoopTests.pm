#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::LoopTests;

use strict;
use warnings;

use base qw( Exporter );
our @EXPORT = qw(
   run_tests
);

use Test::More;
use Test::Exception;
use Test::Refcount;

use IO::Async::Test qw();

use POSIX qw( SIGTERM WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG );
use Time::HiRes qw( time );

our $VERSION = '0.27';

# Abstract Units of Time
use constant AUT => $ENV{TEST_QUICK_TIMERS} ? 0.1 : 1;

# The loop under test. We keep it in a single lexical here, so we can use
# is_oneref() tests in the individual test suite functions
my $loop;

=head1 NAME

C<IO::Async::LoopTests> - acceptance testing for C<IO::Async::Loop> subclasses

=head1 SYNOPSIS

 use IO::Async::LoopTests;
 run_tests( 'IO::Async::Loop::Shiney', 'io' );

=head1 DESCRIPTION

This module contains a collection of test functions for running acceptance
tests on L<IO::Async::Loop> subclasses. It is provided as a facility for
authors of such subclasses to ensure that the code conforms to the Loop API
required by C<IO::Async>.

=head1 TIMING

Certain tests require the use of timers or timed delays. Normally these are
counted in units of seconds. By setting the environment variable
C<TEST_QUICK_TIMERS> to some true value, these timers run 10 times quicker,
being measured in units of 0.1 seconds instead. This value may be useful when
running the tests interactively, to avoid them taking too long. The slower
timers are preferred on automated smoke-testing machines, to help guard
against false negatives reported simply because of scheduling delays or high
system load while testing.

 TEST_QUICK_TIMERS=1 ./Build test

=cut

=head1 FUNCTIONS

=cut

=head2 run_tests( $class, @tests )

Runs a test or collection of tests against the loop subclass given. The class
being tested is loaded by this function; the containing script does not need
to C<require> or C<use> it first.

This function runs C<Test::More::plan> to output its expected test count; the
containing script should not do this.

=cut

sub run_tests
{
   my ( $testclass, @tests ) = @_;

   my $count = 0;
   $count += __PACKAGE__->can( "count_tests_$_" )->() + 2 for @tests;

   plan tests => $count;

   ( my $file = "$testclass.pm" ) =~ s{::}{/}g;

   eval { require $file };
   if( $@ ) {
      BAIL_OUT( "Unable to load $testclass - $@" );
   }

   foreach my $test ( @tests ) {
      $loop = $testclass->new();

      is_oneref( $loop, '$loop has refcount 1' );

      __PACKAGE__->can( "run_tests_$test" )->();

      is_oneref( $loop, '$loop has refcount 1 finally' );
   }
}

sub wait_for(&)
{
   # Bounce via here so we don't upset refcount tests by having loop
   # permanently set in IO::Async::Test
   IO::Async::Test::testing_loop( $loop );

   # Override prototype - I know what I'm doing
   &IO::Async::Test::wait_for( @_ );

   IO::Async::Test::testing_loop( undef );
}

sub time_between(&$$$)
{
   my ( $code, $lower, $upper, $name ) = @_;

   my $start = time;
   $code->();
   my $took = ( time - $start ) / AUT;

   cmp_ok( $took, '>=', $lower, "$name took at least $lower seconds" ) if defined $lower;
   cmp_ok( $took, '<=', $upper * 3, "$name took no more than $upper seconds" ) if defined $upper;
   if( $took > $upper and $took <= $upper * 3 ) {
      diag( "$name took longer than $upper seconds - this may just be an indication of a busy testing machine rather than a bug" );
   }
}

=head1 TEST SUITES

The following test suite names exist, to be passed as a name in the C<@tests>
argument to C<run_tests>:

=cut

=head2 io

Tests the Loop's ability to watch filehandles for IO readiness

=cut

use constant count_tests_io => 11;
sub run_tests_io
{
   my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

   $_->blocking( 0 ) for $S1, $S2;

   my $readready  = 0;
   my $writeready = 0;

   $loop->watch_io(
      handle => $S1,
      on_read_ready => sub { $readready = 1 },
   );

   is_oneref( $loop, '$loop has refcount 1 after watch_io on_read_ready' );
   is( $readready, 0, '$readready still 0 before ->loop_once' );

   $loop->loop_once( 0.1 );

   is( $readready, 0, '$readready when idle' );

   $S2->syswrite( "data\n" );

   # We should still wait a little while even thought we expect to be ready
   # immediately, because talking to ourself with 0 poll timeout is a race
   # condition - we can still race with the kernel.

   $loop->loop_once( 0.1 );

   is( $readready, 1, '$readready after loop_once' );

   # Ready $S1 to clear the data
   $S1->getline(); # ignore return

   $loop->watch_io(
      handle => $S1,
      on_write_ready => sub { $writeready = 1 },
   );

   is_oneref( $loop, '$loop has refcount 1 after watch_io on_write_ready' );

   $loop->loop_once( 0.1 );

   is( $writeready, 1, '$writeready after loop_once' );

   $loop->unwatch_io(
      handle => $S1,
      on_write_ready => 1,
   );

   $readready = 0;
   $loop->loop_once( 0.1 );

   is( $readready, 0, '$readready before HUP' );

   close( $S2 );

   $readready = 0;
   $loop->loop_once( 0.1 );

   is( $readready, 1, '$readready after HUP' );

   $loop->unwatch_io(
      handle => $S1,
      on_read_ready => 1,
   );

   # HUP of pipe - can be different to sockets on some architectures

   my ( $P1, $P2 ) = $loop->pipepair() or die "Cannot pipepair - $!";

   $loop->watch_io(
      handle => $P1,
      on_read_ready => sub { $readready = 1 },
   );

   $readready = 0;
   $loop->loop_once( 0.1 );

   is( $readready, 0, '$readready before pipe HUP' );

   close( $P2 );

   $readready = 0;
   $loop->loop_once( 0.1 );

   is( $readready, 1, '$readready after pipe HUP' );

   $loop->unwatch_io(
      handle => $P1,
      on_read_ready => 1,
   );

   # Check that combined read/write handlers can cancel each other

   ( $S1, $S2 ) = $loop->socketpair() or die "Cannot socketpair - $!";

   my $callcount = 0;
   $loop->watch_io(
      handle => $S1,
      on_read_ready => sub {
         $callcount++;
         $loop->unwatch_io( handle => $S1, on_read_ready => 1, on_write_ready => 1 );
      },
      on_write_ready => sub {
         $callcount++;
         $loop->unwatch_io( handle => $S1, on_read_ready => 1, on_write_ready => 1 );
      },
   );

   $S2->close;

   $loop->loop_once( 0.1 );

   is( $callcount, 1, 'read/write_ready can cancel each other' );
}

=head2 timer

Tests the Loop's ability to handle timer events

=cut

use constant count_tests_timer => 8;
sub run_tests_timer
{
   my $done = 0;

   $loop->enqueue_timer( delay => 2 * AUT, code => sub { $done = 1; } );

   is_oneref( $loop, '$loop has refcount 1 after enqueue_timer' );

   time_between {
      my $now = time;
      $loop->loop_once( 5 * AUT );

      # poll() might have returned just a little early, such that the TimerQueue
      # doesn't think anything is ready yet. We need to handle that case.
      while( !$done ) {
         die "It should have been ready by now" if( time - $now > 5 * AUT );
         $loop->loop_once( 0.1 * AUT );
      }
   } 1.5, 2.5, 'loop_once(5) while waiting for timer';

   my $cancelled_fired = 0;
   my $id = $loop->enqueue_timer( delay => 1 * AUT, code => sub { $cancelled_fired = 1 } );
   $loop->cancel_timer( $id );
   undef $id;

   $loop->loop_once( 2 * AUT );

   ok( !$cancelled_fired, 'cancelled timer does not fire' );

   $id = $loop->enqueue_timer( delay => 1 * AUT, code => sub { $done = 2; } );
   $id = $loop->requeue_timer( $id, delay => 2 * AUT );

   $done = 0;

   time_between {
      $loop->loop_once( 1 * AUT );

      is( $done, 0, '$done still 0 so far' );

      my $now = time;
      $loop->loop_once( 5 * AUT );

      # poll() might have returned just a little early, such that the TimerQueue
      # doesn't think anything is ready yet. We need to handle that case.
      while( !$done ) {
         die "It should have been ready by now" if( time - $now > 5 * AUT );
         $loop->loop_once( 0.1 * AUT );
      }
   } 1.5, 2.5, 'requeued timer of delay 2';

   is( $done, 2, '$done is 2 after requeued timer' );
}

=head2 signal

Tests the Loop's ability to watch POSIX signals

=cut

use constant count_tests_signal => 11;
sub run_tests_signal
{
   my $caught;

   $loop->watch_signal( TERM => sub { $caught = 1 } );

   is_oneref( $loop, '$loop has refcount 1 after watch_signal()' );

   $loop->loop_once( 0.1 );

   is( $caught, undef, '$caught idling' );

   kill SIGTERM, $$;

   $loop->loop_once( 0.1 );

   is( $caught, 1, '$caught after raise' );

   is_oneref( $loop, '$loop has refcount 1 before unwatch_signal()' );

   $loop->unwatch_signal( 'TERM' );

   is_oneref( $loop, '$loop has refcount 1 after unwatch_signal()' );

   my ( $cA, $cB );

   my $idA = $loop->attach_signal( TERM => sub { $cA = 1 } );
   my $idB = $loop->attach_signal( TERM => sub { $cB = 1 } );

   is_oneref( $loop, '$loop has refcount 1 after 2 * attach_signal()' );

   kill SIGTERM, $$;

   $loop->loop_once( 0.1 );

   is( $cA, 1, '$cA after raise' );
   is( $cB, 1, '$cB after raise' );

   $loop->detach_signal( 'TERM', $idA );

   undef $cA;
   undef $cB;

   kill SIGTERM, $$;

   $loop->loop_once( 0.1 );

   is( $cA, undef, '$cA after raise' );
   is( $cB, 1,     '$cB after raise' );

   $loop->detach_signal( 'TERM', $idB );

   dies_ok( sub { $loop->attach_signal( 'this signal name does not exist', sub {} ) },
            'Bad signal name fails' );
}

=head2 idle

Tests the Loop's support for idle handlers

=cut

use constant count_tests_idle => 10;
sub run_tests_idle
{
   my $called = 0;

   my $id = $loop->watch_idle( when => 'later', code => sub { $called++ } );

   ok( defined $id, 'idle watcher id is defined' );

   is( $called, 0, 'deferred sub not yet invoked' );

   time_between { $loop->loop_once( 3 * AUT ) } undef, 1.0, 'loop_once(3) with deferred sub';

   is( $called, 1, 'deferred sub called after loop_once' );

   $loop->watch_idle( when => 'later', code => sub {
      $loop->watch_idle( when => 'later', code => sub { $called++ } )
   } );

   $loop->loop_once( 1 );

   is( $called, 1, 'inner deferral not yet invoked' );

   $loop->loop_once( 1 );

   is( $called, 2, 'inner deferral now invoked' );

   $id = $loop->watch_idle( when => 'later', code => sub { $called = 20 } );

   $loop->unwatch_idle( $id );

   time_between { $loop->loop_once( 1 * AUT ) } 0.5, 1.5, 'loop_once(1) with unwatched deferral';

   is( $called, 2, 'unwatched deferral not called' );

   $loop->later( sub { $called++ } );

   $loop->loop_once( 1 );

   is( $called, 3, '$loop->later() shortcut works' );
}

=head2 child

Tests the Loop's support for watching child processes by PID

=cut

use constant count_tests_child => 6;
sub run_tests_child
{
   my $kid = fork();
   defined $kid or die "Cannot fork() - $!";

   if( $kid == 0 ) {
      exit( 3 );
   }

   my $exitcode;

   $loop->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

   is_oneref( $loop, '$loop has refcount 1 after watch_child' );
   ok( !defined $exitcode, '$exitcode not defined before ->loop_once' );

   undef $exitcode;
   wait_for { defined $exitcode };

   ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit' );
   is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after child exit' );

   # We require that SIGTERM perform its default action; i.e. terminate the
   # process. Ensure this definitely happens, in case the test harness has it
   # ignored or handled elsewhere.
   local $SIG{TERM} = "DEFAULT";

   $kid = fork();
   defined $kid or die "Cannot fork() - $!";

   if( $kid == 0 ) {
      sleep( 10 );
      # Just in case the parent died already and didn't kill us
      exit( 0 );
   }

   $loop->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

   kill SIGTERM, $kid;

   undef $exitcode;
   wait_for { defined $exitcode };

   ok( WIFSIGNALED($exitcode),          'WIFSIGNALED($exitcode) after SIGTERM' );
   is( WTERMSIG($exitcode),    SIGTERM, 'WTERMSIG($exitcode) after SIGTERM' );
}

=head2 control

Tests that the C<loop_once> and C<loop_forever> methods behave correctly

=cut

use constant count_tests_control => 3;
sub run_tests_control
{
   time_between { $loop->loop_once( 2 * AUT ) } 1.5, 2.5, 'loop_once(2) when idle';

   $loop->later( sub { $loop->loop_stop } );

   local $SIG{ALRM} = sub { die "Test timed out before ->loop_stop" };
   alarm( 1 );

   $loop->loop_forever;

   alarm( 0 );

   ok( 1, '$loop->loop_forever interruptable by ->loop_stop' );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
