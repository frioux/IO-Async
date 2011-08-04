#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009-2011 -- leonerd@leonerd.org.uk

package IO::Async::Timer::Periodic;

use strict;
use warnings;
use base qw( IO::Async::Timer );

our $VERSION = '0.43';

use Carp;

=head1 NAME

C<IO::Async::Timer::Periodic> - event callback at regular intervals

=head1 SYNOPSIS

 use IO::Async::Timer::Periodic;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 my $timer = IO::Async::Timer::Periodic->new(
    interval => 60,

    on_tick => sub {
       print "You've had a minute\n";
    },
 );

 $timer->start;

 $loop->add( $timer );

 $loop->loop_forever;

=head1 DESCRIPTION

This subclass of L<IO::Async::Timer> implements repeating events at regular
clock intervals. The timing is not subject to how long it takes the callback
to execute, but runs at regular intervals beginning at the time the timer was
started, then adding each interval thereafter.

For a C<Timer> object that only runs a callback once, after a given delay, see
instead L<IO::Async::Timer::Countdown>. A Countdown timer can also be used to
create repeating events that fire at a fixed delay after the previous event
has finished processing. See als the examples in
C<IO::Async::Timer::Countdown>.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters:

=head2 on_tick

Invoked on each interval of the timer.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_tick => CODE

CODE reference for the C<on_tick> event.

=item interval => NUM

The interval in seconds between invocations of the callback or method. Cannot
be changed if the timer is running.

=item first_interval => NUM

Optional. If defined, the interval in seconds after calling the C<start>
method before the first invocation of the callback or method. Thereafter, the
regular C<interval> will be used. If not supplied, the first interval will be
the same as the others.

Even if this value is zero, the first invocation will be made asynchronously,
by the containing C<Loop> object, and not synchronously by the C<start> method
itself.

=back

Once constructed, the timer object will need to be added to the C<Loop> before
it will work. It will also need to be started by the C<start> method.

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   if( exists $params{on_tick} ) {
      my $on_tick = delete $params{on_tick};
      ref $on_tick or croak "Expected 'on_tick' as a reference";

      $self->{on_tick} = $on_tick;
      undef $self->{cb}; # Will be lazily constructed when needed
   }

   if( exists $params{interval} ) {
      $self->is_running and croak "Cannot configure 'interval' of a running timer\n";

      my $interval = delete $params{interval};
      $interval > 0 or croak "Expected a 'interval' as a positive number";

      $self->{interval} = $interval;
   }

   if( exists $params{first_interval} ) {
      $self->is_running and croak "Cannot configure 'first_interval' of a running timer\n";

      my $first_interval = delete $params{first_interval};
      $first_interval >= 0 or croak "Expected a 'first_interval' as a non-negative number";

      $self->{first_interval} = $first_interval;
   }

   unless( $self->can_event( 'on_tick' ) ) {
      croak 'Expected either a on_tick callback or an ->on_tick method';
   }

   $self->SUPER::configure( %params );
}

sub _next_interval
{
   my $self = shift;
   return $self->{first_interval} if defined $self->{first_interval};
   return $self->{interval};
}

sub start
{
   my $self = shift;

   # Only actually define a time if we've got a loop; otherwise it'll just
   # become start-pending. We'll calculate it properly when it gets added to
   # the Loop
   if( my $loop = $self->loop ) {
      if( !defined $self->{next_time} ) {
         $self->{next_time} = $loop->time + $self->_next_interval;
      }
      else {
         $self->{next_time} += $self->_next_interval;
      }
   }

   $self->SUPER::start;
}

sub stop
{
   my $self = shift;
   $self->SUPER::stop;

   undef $self->{next_time};
}

sub _make_cb
{
   my $self = shift;

   return $self->_capture_weakself( sub {
      my $self = shift;

      undef $self->{first_interval};

      undef $self->{id};
      $self->start;

      $self->invoke_event( on_tick => );
   } );
}

sub _make_enqueueargs
{
   my $self = shift;

   return time => $self->{next_time};
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
