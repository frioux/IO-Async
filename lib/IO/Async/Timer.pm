#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::Timer;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.23';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<IO::Async::Timer> - event callback after some timed delay

=head1 SYNOPSIS

 use IO::Async::Timer;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $timer = IO::Async::Timer->new(
    mode => "countdown",
    delay => 10,

    on_expire => sub {
       print "Sorry, your time's up\n";
       $loop->loop_stop;
    },
 );

 $loop->add( $timer );

 $loop->loop_forever;

=head1 DESCRIPTION

This module provides a class of C<IO::Async::Notifier> for implementing timed
delays. A C<Timer> object implements a countdown timer, which invokes its
callback after the given period from when it was started. After it has expired
the Timer may be started again, when it will wait the same period then invoke
the callback again. A timer that is currently running may be stopped or reset.

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

=item mode => STRING

The type of timer to create. Currently the only allowed mode is C<countdown>
but more types may be added in the future. Can only be given at construction
time.

=item on_expire => CODE

CODE reference to callback to invoke when the timer expires. If not supplied,
the subclass method will be called instead.

=item delay => NUM

The delay in seconds after starting the timer until it expires. Cannot be
changed if the timer is running.

=back

Once constructed, the C<Timer> will need to be added to the C<Loop> before it
will work. It will also need to be started by the C<start> method.

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;

   my $mode = delete $params->{mode} or croak "Expected a 'mode'";

   # Might define some other modes later
   $mode eq "countdown" or croak "Expected 'mode' to be 'countdown'";

   $self->{mode} = $mode;

   $self->SUPER::_init( $params );
}

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

sub _add_to_loop
{
   my $self = shift;
   $self->start if delete $self->{pending};
}

sub _remove_from_loop
{
   my $self = shift;
   $self->stop;
}

=head1 METHODS

=cut

=head2 $running = $timer->is_running

Returns true if the Timer has been started, and has not yet expired, or been
stopped.

=cut

sub is_running
{
   my $self = shift;

   defined $self->{id};
}

=head2 $timer->start

Starts the Timer. Throws an error if it was already running.

If the Timer is not yet in a Loop, the actual start will be deferred until it
is added. Once added, it will be running, and will expire at the given
duration after the time it was added.

=cut

sub start
{
   my $self = shift;

   my $loop = $self->get_loop;
   if( !defined $loop ) {
      $self->{pending} = 1;
      return;
   }

   defined $self->{id} and croak "Cannot start a Timer that is already running";

   if( !$self->{cb} ) {
      weaken( my $weakself = $self );

      if( $self->{on_expire} ) {
         $self->{cb} = sub {
            undef $weakself->{id};
            $weakself->{on_expire}->( $weakself );
         };
      }
      else {
         $self->{cb} = sub {
            undef $weakself->{id};
            $weakself->on_expire;
         };
      }
   }

   $self->{id} = $loop->enqueue_timer(
      delay => $self->{delay},
      code => $self->{cb},
   );
}

=head2 $timer->stop

Stops the Timer if it is running.

=cut

sub stop
{
   my $self = shift;

   my $loop = $self->get_loop or croak "Cannot stop a Timer that is not in a Loop";

   defined $self->{id} or return; # nothing to do but no error

   $loop->cancel_timer( $self->{id} );

   undef $self->{id};
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

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
