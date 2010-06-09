#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::Timer::Periodic;

use strict;
use warnings;
use base qw( IO::Async::Timer );

our $VERSION = '0.29';

use Carp;
use Scalar::Util qw( weaken );
use Time::HiRes qw( time );

=head1 NAME

C<IO::Async::Timer::Periodic> - event callback at regular intervals

=head1 SYNOPSIS

 use IO::Async::Timer::Periodic;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

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

This module provides a subclass of L<IO::Async::Timer> for implementing
repeating events at regular intervals. The object invokes its callback at
regular clock intervals. The timing is not subject to how long it takes the
callback to execute, but runs at regular intervals beginning at the time the
timer was started, then adding each interval thereafter.

For a C<Timer> object that only runs a callback once, after a given delay, see
instead L<IO::Async::Timer::Countdown>.

This object may be used in one of two ways; with a callback function, or as a
base class.

=over 4

=item Callbacks

If the C<on_tick> key is supplied to the constructor, it should contain a
CODE reference to a callback function to be invoked at the appropriate time:

 $on_tick->( $self )

=item Base Class

If a subclass is built, then it can override the C<on_tick> method.

 $self->on_tick()

=back

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_tick => CODE

CODE reference to callback to invoke each interval. If not supplied, the
subclass method will be called instead.

=item interval => NUM

The interval in seconds between invocations of the callback or method. Cannot
be changed if the timer is running.

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

   if( !$self->{on_tick} and !$self->can( 'on_tick' ) ) {
      croak 'Expected either a on_tick callback or an ->on_tick method';
   }

   $self->SUPER::configure( %params );
}

sub start
{
   my $self = shift;

   my $now = time;
   if( !defined $self->{next_time} ) {
      $self->{next_time} = time + $self->{interval};
   }
   else {
      $self->{next_time} += $self->{interval};
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
   weaken( my $weakself = $self );

   if( $self->{on_tick} ) {
      return sub {
         undef $weakself->{id};
         $weakself->start;
         $weakself->{on_tick}->( $weakself );
      };
   }
   else {
      return sub {
         undef $weakself->{id};
         $weakself->start;
         $weakself->on_tick;
      };
   }
}

sub _make_enqueueargs
{
   my $self = shift;

   return time => $self->{next_time};
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
