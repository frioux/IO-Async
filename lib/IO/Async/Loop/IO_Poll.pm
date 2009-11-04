#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::Loop::IO_Poll;

use strict;
use warnings;

our $VERSION = '0.25';

use base qw( IO::Async::Loop::Poll );

=head1 NAME

C<IO::Async::Loop::IO_Poll> - compatibility wrapper for
L<IO::Async::Loop::Poll>

=head1 DESCRIPTION

This class is a compatibility wrapper for programs that expect to find the
Loop subclass which uses L<IO::Poll> under this name. It was renamed to
C<IO::Async::Loop::Poll>.

Any program still referring to this class directly should be changed.

=cut

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
