#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::Timer::Countdown;

use strict;
use warnings;
use base qw( IO::Async::Timer );

our $VERSION = '0.28';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<IO::Async::Timer::Countdown> - event callback after a fixed delay

=head1 SYNOPSIS

 use IO::Async::Timer::Countdown;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $timer = IO::Async::Timer::Countdown->new(
    delay => 10,

    on_expire => sub {
       print "Sorry, your time's up\n";
       $loop->loop_stop;
    },
 );

 $timer->start;

 $loop->add( $timer );

 $loop->loop_forever;

=head1 DESCRIPTION

This module provides a subclass of L<IO::Async::Timer> for implementing
one-shot fixed delays. The object implements a countdown timer, which invokes
its callback after the given period from when it was started. After it has
expired the Timer may be started again, when it will wait the same period then
invoke the callback again. A timer that is currently running may be stopped or
reset.

For a C<Timer> object that repeatedly runs a callback at regular intervals,
see instead L<IO::Async::Timer::Periodic>.

This object may be used in one of two ways; with a callback function, or as a
base class.

=over 4

=item Callbacks

If the C<on_expire> key is supplied to the constructor, it should contain a
CODE reference to a callback function to be invoked at the appropriate time:

 $on_expire->( $self )

=item Base Class

If a subclass is built, then it can override the C<on_expire> method.

 $self->on_expire()

=back

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_expire => CODE

CODE reference to callback to invoke when the timer expires. If not supplied,
the subclass method will be called instead.

=item delay => NUM

The delay in seconds after starting the timer until it expires. Cannot be
changed if the timer is running.

=back

Once constructed, the timer object will need to be added to the C<Loop> before
it will work. It will also need to be started by the C<start> method.

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   if( exists $params{on_expire} ) {
      my $on_expire = delete $params{on_expire};
      ref $on_expire eq "CODE" or croak "Expected 'on_expire' as a CODE reference";

      $self->{on_expire} = $on_expire;
      undef $self->{cb}; # Will be lazily constructed when needed
   }

   if( exists $params{delay} ) {
      $self->is_running and croak "Cannot configure 'delay' of a running timer\n";

      my $delay = delete $params{delay};
      $delay > 0 or croak "Expected a 'delay' as a positive number";

      $self->{delay} = $delay;
   }

   if( !$self->{on_expire} and !$self->can( 'on_expire' ) ) {
      croak 'Expected either a on_expire callback or an ->on_expire method';
   }

   $self->SUPER::configure( %params );
}

sub _make_cb
{
   my $self = shift;
   weaken( my $weakself = $self );

   if( $self->{on_expire} ) {
      return sub {
         undef $weakself->{id};
         $weakself->{on_expire}->( $weakself );
      };
   }
   else {
      return sub {
         undef $weakself->{id};
         $weakself->on_expire;
      };
   }
}

sub _make_enqueueargs
{
   my $self = shift;

   return delay => $self->{delay};
}

=head2 $timer->reset

If the timer is running, restart the countdown period from now. If the timer
is not running, this method has no effect.

=cut

sub reset
{
   my $self = shift;

   my $loop = $self->get_loop or croak "Cannot reset a Timer that is not in a Loop";

   return if !$self->is_running;

   $self->{id} = $loop->requeue_timer(
      $self->{id},
      delay => $self->{delay},
   );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 EXAMPLES

=head2 Watchdog Timer

Because the C<reset> method restarts a running countdown timer back to its
full period, it can be used to implement a watchdog timer. This is a timer
which will not expire provided the method is called at least as often as it
is configured. If the method fails to be called, the timer will eventually
expire and run its callback.

For example, to expire an accepted connection after 30 seconds of inactivity:

 ...

 on_accept => sub {
    my ( $newclient ) = @_;

    my $stream;

    my $watchdog = IO::Async::Timer::Countdown->new(
       delay => 30,

       on_expire => sub { $stream->close },
    );

    my $stream = IO::Async::Stream->new(
       handle => $newclient,

       on_read => sub {
          my ( $self, $buffref, $closed ) = @_;
          $stream->reset;

          ...
       },

       on_closed => sub {
          $watchdog->stop;
       },
    ) );

    $watchdog->start;

    $loop->add( $stream );
    $loop->add( $watchdog );
 }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
