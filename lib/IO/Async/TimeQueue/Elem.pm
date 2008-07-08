#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2008 -- leonerd@leonerd.org.uk

package IO::Async::TimeQueue::Elem;

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

# Keep perl happy; keep Britain tidy
1;
