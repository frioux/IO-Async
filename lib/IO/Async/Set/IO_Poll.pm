#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set::IO_Poll;

use strict;

our $VERSION = '0.10';

use base qw( IO::Async::Loop::IO_Poll IO::Async::Set );

use warnings qw();

=head1 NAME

C<IO::Async::Set::IO_Poll> - backward-compatibility wrapper around
C<IO::Async::Loop::IO_Poll>

=head1 SYNOPSIS

This class should not be used in new code, and is provided for backward
compatibility for older applications that still use it. It has been renamed
to C<IO::Async::Loop::IO_Poll>. Any application using this class should simply
change

 use IO::Async::Set::IO_Poll;

 my $set = IO::Async::Set::IO_Poll->new( .... );

into

 use IO::Async::Loop::IO_Poll;

 my $loop = IO::Async::Loop::IO_Poll->new( .... );

The behaviour has not otherwise changed.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $set = IO::Async::Set::IO_Poll->new( %params )

This function wraps a call to C<< IO::Async::Set::IO_Poll->new() >>.

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   warnings::warnif 'deprecated',
      "Use of IO::Async::Set::IO_Poll is deprecated; use IO::Async::Loop::IO_Poll instead";

   return $class->SUPER::new( %params );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Async::Loop::IO_Poll> - a Loop using an C<IO::Poll> object

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
