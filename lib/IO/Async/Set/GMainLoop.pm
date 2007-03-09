#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set::GMainLoop;

use strict;

our $VERSION = '0.03';

use base qw( IO::Async::Set );

use Carp;

=head1 NAME

C<IO::Async::Set::GMainLoop> - a class that maintains a set of
C<IO::Async::Notifier> objects by using the C<Glib::MainLoop> object.

=head1 SYNOPSIS

 use IO::Async::Set::GMainLoop;

 my $set = IO::Async::Set::GMainLoop->new();

 $set->add( ... );

 ...
 # Rest of GLib/Gtk program that uses GLib::MainContext

=head1 DESCRIPTION

This subclass of C<IO::Async::Notifier> uses the C<Glib::MainLoop> to perform
read-ready and write-ready tests.

The appropriate C<Glib::IO> sources are added or removed from the
C<Glib::MainLoop> when notifiers are added or removed from the set, or when
they change their C<want_writeready> status. The callbacks are called
automatically by Glib itself; no special methods on this set object are
required.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $set = IO::Async::Set::GMainLoop->new()

This function returns a new instance of a C<IO::Async::Set::GMainLoop> object.
It takes no special arguments.

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   # Test if Glib::main_depth exists - a good hint on whether Glib is loaded
   unless( Glib->can( 'main_depth' ) ) {
      croak 'Cannot construct '.__PACKAGE__.' unless Glib is already loaded';
   }

   unless( defined Glib::MainContext->default ) {
      croak 'Cannot construct '.__PACKAGE__.' unless a Glib::MainContext exists';
   }

   my $self = $class->__new( %args );

   $self->{sourceid} = {};  # {$nkey} -> [ $readid, $writeid ]

   return $self;
}

=head1 METHODS

There are no special methods in this subclass, other than those provided by
the C<IO::Async::Set> base class.

=cut

# override
sub _notifier_removed
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $nkey = $self->_nkey( $notifier );

   my $sourceids = delete $self->{sourceid}->{$nkey};

   Glib::Source->remove( $sourceids->[0] );

   if( defined $sourceids->[1] ) {
      Glib::Source->remove( $sourceids->[1] );
   }
}

# override
# For ::Notifier to call
sub __notifier_want_writeready
{
   my $self = shift;
   my ( $notifier, $want_writeready ) = @_;

   my $nkey = $self->_nkey( $notifier );

   # Fetch the IDs array from storage, or build and store a new one if it's
   # not found
   my $sourceids = ( $self->{sourceid}->{$nkey} ||= [] );

   if( !defined $sourceids->[0] ) {
      $sourceids->[0] = Glib::IO->add_watch(
         $notifier->read_fileno,
         ['in', 'hup'],
         sub {
            $notifier->on_read_ready;
            # Must yield true value or else GLib will remove this IO source
            return 1;
         }
      );
   }

   if( !defined $sourceids->[1] and $want_writeready ) {
      $sourceids->[1] = Glib::IO->add_watch(
         $notifier->write_fileno,
         ['out'],
         sub {
            $notifier->on_write_ready;
            # Must yield true value or else GLib will remove this IO source
            return 1;
         }
      );
   }
   elsif( defined $sourceids->[1] and !$want_writeready ) {
      Glib::Source->remove( $sourceids->[1] );
      undef $sourceids->[1];
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<Glib> - Perl wrappers for the GLib utility and Object libraries

=item *

L<Gtk2> - Perl interface to the 2.x series of the Gimp Toolkit library

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
