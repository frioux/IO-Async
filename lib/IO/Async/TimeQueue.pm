#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006,2007 -- leonerd@leonerd.org.uk

package IO::Async::TimeQueue;

use strict;

our $VERSION = '0.14';

use Carp;
use Heap::Fibonacci;

BEGIN {
   if ( eval { Time::HiRes::time(); 1 } ) {
      Time::HiRes->import( qw( time ) );
   }
}

=head1 NAME

C<IO::Async::TimeQueue> - a queue of future timed event callbacks

=head1 DESCRIPTION

This class is not intended to be used by external code; it is used by
C<IO::Async::Loop::Select> and C<IO::Async::Loop::IO_Poll> to implement the
timer features.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $queue = IO::Async::TimeQueue->new()

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $self = bless {
      heap => Heap::Fibonacci->new,
   }, $class;

   return $self;
}

=head1 METHODS

=cut

=head2 $time = $queue->next_time

Returns the time of the next event on the queue, or C<undef> if no events
are left.

=cut

sub next_time
{
   my $self = shift;

   my $heap = $self->{heap};

   my $top = $heap->top;

   return defined $top ? $top->time : undef;
}

=head2 $id = $queue->enqueue( %params )

Adds a new event to the queue. An ID value is returned, which may be passed
to the C<cancel()> method to cancel this timer. This value may be an object
reference, so care should be taken not to store it unless it is required. If
it is stored, it should be released after the timer code has fired, or it has
been canceled, in order to free the object itself.

The C<%params> takes the following keys:

=over 8

=item time => NUM

The absolute system timestamp to run the event.

=item delay => NUM

The delay after now at which to run the event.

=item now => NUM

The time to consider as now; defaults to C<time()> if not specified.

=item code => CODE

CODE reference to the callback function to run at the allotted time.

=back

Either C<time> or C<delay> must be specified.

=cut

sub enqueue
{
   my $self = shift;
   my ( %params ) = @_;

   my $time;
   if( exists $params{time} ) {
      $time = delete $params{time};
   }
   elsif( exists $params{delay} ) {
      my $now = exists $params{now} ? $params{now} : time();

      $time = $now + delete $params{delay};
   }
   else {
      croak "Expected either 'time' or 'delay' keys";
   }

   my $code = delete $params{code};
   ref $code eq "CODE" or croak "Expected 'code' to be a CODE reference";

   my $heap = $self->{heap};

   my $elem = IO::Async::TimeQueue::Elem->new( $time, $code );
   $heap->add( $elem );

   return $elem;
}

=head2 $queue->cancel( $id )

Cancels a previously-enqueued timer event by removing it from the queue.

=cut

sub cancel
{
   my $self = shift;
   my ( $id ) = @_;

   my $heap = $self->{heap};
   $heap->delete( $id );
}

=head2 $count = $queue->fire( %params )

Call all the event callbacks that should have run by now. The number of
callbacks actually invoked will be returned.

The C<%params> hash takes the following keys:

=over 8

=item now => NUM

The time to consider as now; defaults to C<time()> if not specified.

=back

=cut

sub fire
{
   my $self = shift;
   my ( %params ) = @_;

   my $now = exists $params{now} ? $params{now} : time();

   my $heap = $self->{heap};

   my $count = 0;

   while( defined( my $top = $heap->top ) ) {
      last if( $top->time > $now );

      $top->code->();
      $count++;

      $heap->extract_top;
   }

   return $count;
}

# Keep perl happy; keep Britain tidy
1;

package IO::Async::TimeQueue::Elem;

use strict;
use base qw( Heap::Elem );

# The internal implementation of Heap::Elem changed at 0.80 to be an ARRAY
# typed object, with a 'val' accessor for the user data, where before it's a
# plain HASH to be accessed directly. We therefore supply two sets of methods
# here, and set up the right ones depending on the version.

sub new_HASH
{
   my $self = shift;
   my $class = ref $self || $self;

   my ( $time, $code ) = @_;

   my $new = $class->SUPER::new();

   $new->{time} = $time;
   $new->{code} = $code;

   return $new;
}

sub time_HASH
{
   my $self = shift;
   return $self->{time};
}

sub code_HASH
{
   my $self = shift;
   return $self->{code};
}

sub new_VAL
{
   my $self = shift;
   my $class = ref $self || $self;

   my ( $time, $code ) = @_;

   my $new = $class->SUPER::new(
      time => $time,
      code => $code,
   );

   return $new;
}

sub time_VAL
{
   my $self = shift;
   return $self->val->{time};
}

sub code_VAL
{
   my $self = shift;
   return $self->val->{code};
}

if( $Heap::Elem::VERSION < 0.80 ) {
  *new  = \&new_HASH;
  *time = \&time_HASH;
  *code = \&code_HASH;
}
else {
  *new  = \&new_VAL;
  *time = \&time_VAL;
  *code = \&code_VAL;
}

# This only uses methods so is transparent to HASH or ARRAY
sub cmp
{
   my $self = shift;
   my $other = shift;

   $self->time <=> $other->time;
}

1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
