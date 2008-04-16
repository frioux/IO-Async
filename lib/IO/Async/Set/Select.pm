#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set::Select;

use strict;

our $VERSION = '0.10';

=head1 NAME

C<IO::Async::Set::Select> - backward-compatibility wrapper around
C<IO::Async::Loop::Select>

=head1 SYNOPSIS

This class should not be used in new code. It has been renamed to
C<IO::Async::Loop::Select>. Any application using this class should simply
change

 use IO::Async::Set::Select;

 my $set = IO::Async::Set::Select->new( .... );

into

 use IO::Async::Loop::Select;

 my $loop = IO::Async::Loop::Select->new( .... );

The behaviour has not otherwise changed.

=cut

die "IO::Async::Set::Select is now deprecated. Please use IO::Async::Loop::Select instead\n";

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Async::Loop::Select> - a Loop using the C<select()> syscall

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
