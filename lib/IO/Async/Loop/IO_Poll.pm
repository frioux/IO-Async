#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::Loop::IO_Poll;

use strict;
use warnings;

use Carp;

our $VERSION = '0.29';

use base qw( IO::Async::Loop::Poll );

=head1 NAME

C<IO::Async::Loop::IO_Poll> - compatibility wrapper for
L<IO::Async::Loop::Poll>

=head1 DESCRIPTION

This class is a compatibility wrapper for programs that expect to find the
Loop subclass which uses L<IO::Poll> under this name. It was renamed to
C<IO::Async::Loop::Poll>. The API is exactly the same, only under a different
name.

Any program still referring to this class directly should be changed. This
object constructor will print a warning when the object is created.

=cut

sub new
{
   carp "IO::Async::Loop::IO_Poll is deprecated, and now called IO::Async::Loop::Poll. Please update your code";
   shift->SUPER::new( @_ );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
