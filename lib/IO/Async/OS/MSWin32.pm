#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2012 -- leonerd@leonerd.org.uk

package IO::Async::OS::MSWin32;

use strict;
use warnings;

our $VERSION = '0.51_002';

our @ISA = qw( IO::Async::OS::_Base );

use Carp;

use Socket qw( AF_INET SOCK_STREAM SOCK_DGRAM );

use IO::Socket (); # empty import

use constant HAVE_FAKE_ISREG_READY => 1;

use constant HAVE_SELECT_CONNECT_EVEC => 1;

use constant HAVE_CONNECT_EWOULDBLOCK => 1;

use constant HAVE_RENAME_OPEN_FILES => 0;

=head1 NAME

C<IO::Async::OS::MSWin32> - operating system abstractions on C<MSWin32> for C<IO::Async>

=head1 DESCRIPTION

This module contains OS support code for C<MSWin32>.

See instead L<IO::Async::OS>.

=cut

# Win32 doesn't have a socketpair(). We'll fake one up
sub socketpair
{
   my $self = shift;
   my ( $family, $socktype, $proto ) = @_;

   $family = $self->getfamilybyname( $family ) || AF_INET;

   # SOCK_STREAM is the most likely
   $socktype = $self->getsocktypebyname( $socktype ) || SOCK_STREAM;

   $proto ||= 0;

   if( $socktype == SOCK_STREAM ) {
      my $listener = IO::Socket::INET->new(
         LocalAddr => "127.0.0.1",
         LocalPort => 0,
         Listen    => 1,
         Blocking  => 0,
      ) or croak "Cannot socket() - $!";

      my $S1 = IO::Socket::INET->new(
         PeerAddr => $listener->sockhost,
         PeerPort => $listener->sockport
      ) or croak "Cannot socket() again - $!";

      my $S2 = $listener->accept or croak "Cannot accept() - $!";

      $listener->close;

      return ( $S1, $S2 );
   }
   elsif( $socktype == SOCK_DGRAM ) {
      my $S1 = IO::Socket::INET->new(
         LocalAddr => "127.0.0.1",
         Type      => SOCK_DGRAM,
         Proto     => "udp",
      ) or croak "Cannot socket() - $!";
      
      my $S2 = IO::Socket::INET->new(
         LocalAddr => "127.0.0.1",
         Type      => SOCK_DGRAM,
         Proto     => "udp",
      ) or croak "Cannot socket() again - $!";

      $S1->connect( $S2->sockname );
      $S2->connect( $S1->sockname );

      return ( $S1, $S2 );
   }
   else {
      croak "Unrecognised socktype $socktype";
   }
};

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
