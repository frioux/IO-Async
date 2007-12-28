#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006,2007 -- leonerd@leonerd.org.uk

package IO::Async::Buffer;

use strict;

our $VERSION = '0.10';

use base qw( IO::Async::Stream );

use warnings qw();

=head1 NAME

C<IO::Async::Buffer> - backward-compatibility wrapper around
C<IO::Async::Stream>

=head1 SYNOPSIS

This class should not be used in new code, and is provided for backward
compatibility for older applications that still use it. It has been renamed
to C<IO::Async::Stream>. Any application using this class should simply change

 use IO::Async::Buffer;

 my $buffer = IO::Async::Buffer->new( .... );

into

 use IO::Async::Stream;

 my $stream = IO::Async::Stream->new( .... );

The behaviour has not otherwise changed.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $buffer = IO::Async::Buffer->new( %params )

This function wraps a call to C<< IO::Async::Stream->new() >>. It will
translate the following deprecated options as well:

=over 8

=item on_incoming_data => CODE

This option is deprecated and should not be used in new code. It is maintained
as a backward-compatibility synonym for C<on_read>.

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   warnings::warnif 'deprecated',
      "Use of IO::Async::Buffer is deprecated; use IO::Async::Stream instead";

   if( $params{on_incoming_data} ) {
      warnings::warnif 'deprecated',
         "The 'on_incoming_data' callback is deprecated; use 'on_read' instead";

      $params{on_read} = delete $params{on_incoming_data};
   }

   return $class->SUPER::new( %params );
}

=head1 DEPRECATED METHODS

This class also provides wrappers for methods that have been renamed between
C<IO::Async::Buffer> and C<IO::Async::Stream>.

=head2 $buffer->send( $data )

A synonym for C<write()>.

=cut

sub send
{
   warnings::warnif 'deprecated',
      "IO::Async::Buffer->send() is deprecated; use ->write() instead";

   # Use write next time
   no warnings 'redefine';
   *send = \&IO::Async::Stream::write;

   # Jump to it now - subsequent calls will go direct
   goto &IO::Async::Stream::write;
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
