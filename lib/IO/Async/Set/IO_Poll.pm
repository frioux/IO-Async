#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set::IO_Poll;

use strict;

our $VERSION = '0.10';

=head1 NAME

C<IO::Async::Set::IO_Poll> - backward-compatibility wrapper around
C<IO::Async::Loop::IO_Poll>

=head1 SYNOPSIS

This class should not be used in new code. It has been renamed to
C<IO::Async::Loop::IO_Poll>. Any application using this class should simply
change

 use IO::Async::Set::IO_Poll;

 my $set = IO::Async::Set::IO_Poll->new( .... );

into

 use IO::Async::Loop::IO_Poll;

 my $loop = IO::Async::Loop::IO_Poll->new( .... );

The behaviour has not otherwise changed.

=cut

die "IO::Async::Set::IO_Poll is now deprecated. Please use IO::Async::Loop::IO_Poll instead\n";

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Async::Loop::IO_Poll> - a Loop using an C<IO::Poll> object

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
