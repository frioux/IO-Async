#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::MergePoint;

use strict;

our $VERSION = '0.12';

use Carp;

=head1 NAME

C<IO::Async::MergePoint> - resynchronise diverged control flow

=head1 SYNOPSIS

 use IO::Async::MergePoint;

 my $merge = IO::Async::MergePoint->new(
    needs => [ "leaves", "water" ],

    on_finished => sub {
       my %items = @_;
       # Make tea using $items{leaves} and $items{water}
    }
 );

 Kettle->boil(
    on_boiled => sub { $merge->done( "water", $_[0] ) }
 );

 Cupboard->get_tea_leaves(
    on_fetched => sub { $merge->done( "leaves", $_[0] ) }
 );

=head1 DESCRIPTION

Often in program logic, multiple different steps need to be taken that are
independent of each other, but their total result is needed before the next
step can be taken. In synchonous code, the usual approach is to do them
sequentially. 

An C<IO::Async>-based program could do this, but if each step involves some IO
idle time, better overall performance can often be gained by running the steps
in parallel. A C<IO::Async::MergePoint> object can then be used to wait for
all of the steps to complete, before passing the combined result of each step
on to the next stage.

A merge point maintains a set of outstanding operations it is waiting on;
these are arbitrary string values provided at the object's construction. Each
time the C<done()> method is called, the named item is marked as being
complete. When all of the required items are so marked, the C<on_finished>
callback is invoked.

When an item is marked as complete, a value can also be provided, which would
contain the results of that step. The C<on_finished> callback is passed a hash
(in list form, rather than by reference) of the collected item values.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $merge = IO::Async::MergePoint->new( %params )

This function returns a new instance of a C<IO::Async::MergePoint> object. The
C<%params> hash takes the following keys:

=over 8

=item needs => ARRAY

An array containing unique item names to wait on. The order of this array is
not significant.

=item on_finished => CODE

CODE reference to the handler for when the merge point becomes ready.

=back

The C<on_finished> handler will be called when every key in the C<needs> list
has been notified by the C<done()> method. It will be called as

 $on_finished->( %items )

where the C<%items> hash will contain the item names that were waited on, and
the values passed to the C<done()> method for each one.

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   ref $params{needs} eq 'ARRAY' or croak "Expected 'needs' to be an ARRAY ref";
   ref $params{on_finished} eq 'CODE' or croak "Expected 'on_finished' to be a CODE ref";

   # Store these as a hash for ease of deletion
   my %needs = map { $_ => 1 } @{ $params{needs} };

   my $self = bless {
      needs => \%needs,
      items => {},
      on_finished => $params{on_finished},
   }, $class;

   return $self;
}

=head1 METHODS

=cut

=head2 $merge->done( $item, $value )

This method informs the merge point that the C<$item> is now ready, and
passes it a value to store, to be passed into the C<on_finished> callback. If
this call gives the final remaining item being waited for, the C<on_finished>
callback is called within it, and the method will not return until it has
completed.

=cut

sub done
{
   my $self = shift;
   my ( $item, $value ) = @_;

   exists $self->{needs}->{$item} or croak "$self does not need $item";

   delete $self->{needs}->{$item};
   $self->{items}->{$item} = $value;

   if( !keys %{ $self->{needs} } ) {
      $self->{on_finished}->( %{$self->{items}} );
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
