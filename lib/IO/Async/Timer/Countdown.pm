#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009-2010 -- leonerd@leonerd.org.uk

package IO::Async::Timer::Countdown;

use strict;
use warnings;
use base qw( IO::Async::Timer );

our $VERSION = '0.32';

use Carp;

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

This subclass of L<IO::Async::Timer> implements one-shot fixed delays.
The object implements a countdown timer, which invokes its callback after the
given period from when it was started. After it has expired the Timer may be
started again, when it will wait the same period then invoke the callback
again. A timer that is currently running may be stopped or reset.

For a C<Timer> object that repeatedly runs a callback at regular intervals,
see instead L<IO::Async::Timer::Periodic>. For a C<Timer> that invokes its
callback at a fixed time in the future, see L<IO::Async::Timer::Absolute>.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters:

=head2 on_expire

Invoked when the timer expires.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_expire => CODE

CODE reference for the C<on_expire> event.

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
      ref $on_expire or croak "Expected 'on_expire' as a reference";

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

   return $self->_capture_weakself( sub {
      my ( $self ) = @_;

      undef $self->{id};

      $self->invoke_event( "on_expire" );
   } );
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
    $stream->add_child( $watchdog );

    $stream = IO::Async::Stream->new(
       handle => $newclient,

       on_read => sub {
          my ( $self, $buffref, $closed ) = @_;
          $watchdog->reset;

          ...
       },

       on_closed => sub {
          $watchdog->stop;
       },
    ) );

    $watchdog->start;

    $loop->add( $watchdog );
 }

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
