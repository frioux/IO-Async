#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2012 -- leonerd@leonerd.org.uk

package IO::Async::OS;

use strict;
use warnings;

our $VERSION = '0.50';

use Carp;

use Socket qw(
   SOCK_STREAM
);

use IO::Socket (); # empty import

# This one isn't documented because it's not really overridable. It's largely
# here just for completeness
sub socket
{
   my $self = shift;
   my ( $family, $socktype, $proto ) = @_;

   croak "Cannot create a new socket without a family" unless $family;

   # SOCK_STREAM is the most likely
   defined $socktype or $socktype = SOCK_STREAM;

   defined $proto or $proto = 0;

   my $sock = eval {
      IO::Socket->new(
         Domain => $family, 
         Type   => $socktype,
         Proto  => $proto,
      );
   };
   return $sock if $sock;

   # That failed. Most likely because the Domain was unrecognised. This 
   # usually happens if getaddrinfo returns an AF_INET6 address but we don't
   # have a suitable class loaded. In this case we'll return a generic one.
   # It won't be in the specific subclass but that's the best we can do. And
   # it will still work as a generic socket.
   return IO::Socket->new->socket( $family, $socktype, $proto );
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
