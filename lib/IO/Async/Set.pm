#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set;

use strict;

our $VERSION = '0.10';

use base qw( IO::Async::Loop );

use Carp;
use warnings qw();

=head1 NAME

C<IO::Async::Set> - backward-compatibility wrapper around
C<IO::Async::Loop>

=head1 SYNOPSIS

This class should not be used in new code, and is provided for backward
compatibility for older applications that still use it. It has been renamed
to C<IO::Async::Loop>. Any subclass of this class should simply change

 use base qw( IO::Async::Set );

into

 use base qw( IO::Async::Loop );

The behaviour has not otherwise changed.

=cut

=head1 DEPRECATED METHODS

This also provides wrappers for methods that have been removed from
C<IO::Async::Set>.

=cut

=head2 $sigproxy = $set->get_sigproxy

This method returns the associated C<IO::Async::SignalProxy> object for the
loop. If there is not yet such a proxy, a new one is constructed and added to
the loop.

Use of this method is deprecated as not all C<IO::Async::Loop> subclasses will
be able to support it. All signal handling should be done by calling
C<attach_signal()> or C<detach_signal()> directly.

=cut

sub get_sigproxy
{
   my $self = shift;

   warnings::warnif "deprecated",
      "IO::Async::Set->get_sigproxy is deprecated; use ->attach_signal() or ->detach_signal() instead";

   return $self->_get_sigproxy;
}

=head2 $manager = $set->get_childmanager

This method returns the associated C<IO::Async::ChildManager> object for the
loop. If there is not yet such an object (namely; that the
C<enable_childmanager()> method has not yet been called), an exception is
thrown.

Use of this method is deprecated as not all C<IO::Async::Loop> subclasses will
be able to support it. All child management should be done by calling
C<watch_child()>, C<detach_child()>, or C<spawn_child()> directly.

=cut

sub get_childmanager
{
   my $self = shift;

   warnings::warnif "deprecated",
      "IO::Async::Set->get_childmanager is deprecated; use ->watch_child(), ->detach_child() or ->spawn_child() instead";

   return $self->{childmanager} if defined $self->{childmanager};
   croak "ChildManager not enabled in Loop";
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Async::Stream> - read and write buffers around an IO handle

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
