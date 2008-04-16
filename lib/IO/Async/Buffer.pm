#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006,2007 -- leonerd@leonerd.org.uk

package IO::Async::Buffer;

use strict;

our $VERSION = '0.10';

=head1 NAME

C<IO::Async::Buffer> - backward-compatibility wrapper around
C<IO::Async::Stream>

=head1 SYNOPSIS

This class should not be used in new code. It has been renamed to
C<IO::Async::Stream>. Any application using this class should simply change

 use IO::Async::Buffer;

 my $buffer = IO::Async::Buffer->new( .... );

into

 use IO::Async::Stream;

 my $stream = IO::Async::Stream->new( .... );

The behaviour has not otherwise changed.

=cut

die "IO::Async::Buffer is now deprecated. Please use IO::Async::Stream instead\n";

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Async::Stream> - read and write buffers around an IO handle

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
