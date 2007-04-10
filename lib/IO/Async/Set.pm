#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set;

use strict;

our $VERSION = '0.04';

use Carp;

=head1 NAME

C<IO::Async::Set> - a class that maintains a set of C<IO::Async::Notifier>
objects.

=head1 SYNOPSIS

This module would not be used directly; see the subclasses:

=over 4

=item L<IO::Async::Set::Select>

=item L<IO::Async::Set::IO_Perl>

=item L<IO::Async::Set::GMainLoop>

=back

=head1 DESCRIPTION


This module provides an abstract class to store a set of
C<IO::Async::Notifier> objects or subclasses of them. It handles all of the
lower-level set manipulation actions, and leaves the actual IO readiness 
testing/notification to the concrete class that implements it.

It also provides access to an C<IO::Async::SignalProxy> object. Only once such
object would need to be constructed and added to the set in order to handle
signals. Accessing the object via the containing set allows for simpler code
that handles signals, so it does not need to carry extra references to the
signal proxy object.

=cut

# Internal constructor used by subclasses
sub __new
{
   my $class = shift;

   my $self = bless {
      notifiers => {}, # {nkey} = notifier
      sigproxy  => undef,
   }, $class;

   return $self;
}

=head1 METHODS

=cut

# Internal method
sub _nkey
{
   my $self = shift;
   my ( $notifier ) = @_;

   # We key the notifiers by their reading fileno; because every notifier
   # needs to have one.
   my $nkey = $notifier->read_fileno;

   defined $nkey or croak "Cannot operate on a notifer that is not read-bound to a handle with a fileno";

   return $nkey;
}

=head2 $set->add( $notifier )

This method adds another notifier object to the stored collection. The object
may be a C<IO::Async::Notifier>, or any subclass of it.

=cut

sub add
{
   my $self = shift;
   my ( $notifier ) = @_;

   if( defined $notifier->parent ) {
      croak "Cannot add a child notifier directly - add its parent";
   }

   if( defined $notifier->__memberof_set ) {
      croak "Cannot add a notifier that is already a member of a set";
   }

   $self->_add_noparentcheck( $notifier );
}

sub _add_noparentcheck
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $nkey = $self->_nkey( $notifier );

   $self->{notifiers}->{$nkey} = $notifier;

   $notifier->__memberof_set( $self );

   $self->__notifier_want_writeready( $notifier, $notifier->want_writeready );

   $self->_add_noparentcheck( $_ ) for $notifier->children;

   return;
}

=head2 $set->remove( $notifier )

This method removes a notifier object from the stored collection.

=cut

sub remove
{
   my $self = shift;
   my ( $notifier ) = @_;

   if( defined $notifier->parent ) {
      croak "Cannot remove a child notifier directly - remove its parent";
   }

   $self->_remove_noparentcheck( $notifier );
}

sub _remove_noparentcheck
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $nkey = $self->_nkey( $notifier );

   exists $self->{notifiers}->{$nkey} or croak "Notifier does not exist in collection";

   delete $self->{notifiers}->{$nkey};

   $notifier->__memberof_set( undef );

   $self->_notifier_removed( $notifier );

   $self->_remove_noparentcheck( $_ ) for $notifier->children;

   return;
}

# Default 'do-nothing' implementation - meant for subclasses to override
sub _notifier_removed
{
   # Ignore
}

# For ::Notifier to call
sub __notifier_want_writeready
{
   my $self = shift;
   my ( $notifier, $want_writeready ) = @_;
   # Ignore
}

=head2 $sigproxy = $set->get_sigproxy

This method returns the associated C<IO::Async::SignalProxy> object for the
set. If there is not yet such a proxy, a new one is constructed and added to
the set.

=cut

sub get_sigproxy
{
   my $self = shift;

   return $self->{sigproxy} if defined $self->{sigproxy};

   require IO::Async::SignalProxy;
   my $sigproxy = IO::Async::SignalProxy->new();
   $self->add( $sigproxy );

   return $self->{sigproxy} = $sigproxy;
}

=head2 $set->attach_signal( $signal, $code )

This method adds a new signal handler to the associated
C<IO::Async::SignalProxy> object. It is equivalent to calling the C<attach()>
method on the object returned from the set's C<get_sigproxy()> method.

=cut

sub attach_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   my $sigproxy = $self->get_sigproxy;
   $sigproxy->attach( $signal, $code );
}

=head2 $set->detach_signal( $signal )

This method removes a signal handler from the associated
C<IO::Async::SignalProxy> object. It is equivalent to calling the C<detach()>
method on the object returned from the set's C<get_sigproxy()> method.

=cut

sub detach_signal
{
   my $self = shift;
   my ( $signal ) = @_;

   my $sigproxy = $self->get_sigproxy;
   $sigproxy->detach( $signal );

   # TODO: Consider "refcount" signals and cleanup if zero. How do we know if
   # anyone else has a reference to the signal proxy though? Tricky...
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
