#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2012 -- leonerd@leonerd.org.uk

package # hide from CPAN
  IO::Async::Internals::TimeQueue;

use strict;
use warnings;
use base qw( Heap::Fibonacci );

use Carp;

use Heap::Fibonacci;
use Time::HiRes qw( time );

sub next_time
{
   my $self = shift;

   my $top = $self->top;

   return defined $top ? $top->time : undef;
}

sub enqueue
{
   my $self = shift;
   my ( %params ) = @_;

   my $code = delete $params{code};
   ref $code or croak "Expected 'code' to be a reference";

   defined $params{time} or croak "Expected 'time'";
   my $time = $params{time};

   my $elem = IO::Async::Internals::TimeQueue::Elem->new( $time, $code );
   $self->add( $elem );

   return $elem;
}

sub cancel
{
   my $self = shift;
   my ( $id ) = @_;

   $self->delete( $id );
}

sub fire
{
   my $self = shift;
   my ( %params ) = @_;

   my $now = exists $params{now} ? $params{now} : time;

   my $count = 0;

   while( defined( my $top = $self->top ) ) {
      last if( $top->time > $now );

      $self->extract_top;

      $top->code->();
      $count++;
   }

   return $count;
}

package # hide from CPAN
  IO::Async::Internals::TimeQueue::Elem;

use strict;
use base qw( Heap::Elem );

sub new
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

sub time
{
   my $self = shift;
   $self->val->{time} = $_[0] if @_;
   return $self->val->{time};
}

sub code
{
   my $self = shift;
   return $self->val->{code};
}

# This only uses methods so is transparent to HASH or ARRAY
sub cmp
{
   my $self = shift;
   my $other = shift;

   $self->time <=> $other->time;
}

0x55AA;
