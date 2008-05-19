#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2008 -- leonerd@leonerd.org.uk

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

# Keep perl happy; keep Britain tidy
1;
