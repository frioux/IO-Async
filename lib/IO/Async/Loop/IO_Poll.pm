#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::Loop::IO_Poll;

use strict;
use warnings;

use Carp;

our $VERSION = '0.32';

use base qw( IO::Async::Loop::Poll );

=head1 NAME

C<IO::Async::Loop::IO_Poll> - compatibility wrapper for
L<IO::Async::Loop::Poll>

=head1 SYNOPSIS

This class should not be used in nwe code. It has been renamed to
L<IO::Async::Loop::Poll>. Any application still using this class should simply
change

 use IO::Async::Loop::IO_Poll;

 my $loop = IO::Async::Loop::IO_Poll->new( ... );

into

 use IO::Async::Loop::Poll;

 my $loop = IO::Async::Loop::Poll->new( ... );

The behaviour has not otherwise changed.

=cut

die "IO::Async::Loop::IO_Poll is now called IO::Async::Loop::Poll. Please update your code";

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
