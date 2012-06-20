#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2012 -- leonerd@leonerd.org.uk

package IO::Async::OS;

use strict;
use warnings;

our $VERSION = '0.50';

use Carp;

use Socket 1.95 qw(
   AF_INET AF_INET6 AF_UNIX INADDR_LOOPBACK SOCK_DGRAM SOCK_RAW SOCK_STREAM
   pack_sockaddr_in
);

use IO::Socket (); # empty import

use constant HAVE_MSWIN32 => ( $^O eq "MSWin32" );

=head1 NAME

C<IO::Async::OS> - operating system abstractions for C<IO::Async>

=head1 DESCRIPTION

This module acts as a class to provide a number of utility methods whose exact
behaviour may depend on the type of OS it is running on. It is provided as a
class so that specific kinds of operating system can override methods in it.

=cut

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

sub _getfamilybyname
{
   my ( $name ) = @_;

   return undef unless defined $name;

   return $name if $name =~ m/^\d+$/;

   return AF_INET    if $name eq "inet";
   return AF_INET6() if $name eq "inet6" and defined &AF_INET6;
   return AF_UNIX    if $name eq "unix";

   croak "Unrecognised socktype name '$name'";
}

sub _getsocktypebyname
{
   my ( $name ) = @_;

   return undef unless defined $name;

   return $name if $name =~ m/^\d+$/;

   return SOCK_STREAM if $name eq "stream";
   return SOCK_DGRAM  if $name eq "dgram";
   return SOCK_RAW    if $name eq "raw";

   croak "Unrecognised socktype name '$name'";
}

=head2 ( $S1, $S2 ) = IO::Async::OS->socketpair( $family, $socktype, $proto )

An abstraction of the C<socketpair(2)> syscall, where any argument may be
missing (or given as C<undef>).

If C<$family> is not provided, a suitable value will be provided by the OS
(likely C<AF_UNIX> on POSIX-based platforms). If C<$socktype> is not provided,
then C<SOCK_STREAM> will be used.

Additionally, this method supports building connected C<SOCK_STREAM> or
C<SOCK_DGRAM> pairs in the C<AF_INET> family even if the underlying platform's
C<socketpair(2)> does not, by connecting two normal sockets together.

C<$family> and C<$socktype> may also be given symbolically similar to the
behaviour of C<extract_addrinfo>.

=cut

sub socketpair
{
   my $self = shift;
   my ( $family, $socktype, $proto ) = @_;

   # PF_UNSPEC and undef are both false
   $family = _getfamilybyname( $family ) || AF_UNIX;

   # SOCK_STREAM is the most likely
   $socktype = _getsocktypebyname( $socktype ) || SOCK_STREAM;

   $proto ||= 0;

   my ( $S1, $S2 ) = IO::Socket->new->socketpair( $family, $socktype, $proto );
   return ( $S1, $S2 ) if defined $S1;

   return unless $family == AF_INET and ( $socktype == SOCK_STREAM or $socktype == SOCK_DGRAM );

   # Now lets emulate an AF_INET socketpair call

   my $Stmp = IO::Async::OS->socket( $family, $socktype ) or return;
   $Stmp->bind( pack_sockaddr_in( 0, INADDR_LOOPBACK ) ) or return;

   $S1 = IO::Async::OS->socket( $family, $socktype ) or return;

   if( $socktype == SOCK_STREAM ) {
      $Stmp->listen( 1 ) or return;
      $S1->connect( getsockname $Stmp ) or return;
      $S2 = $Stmp->accept or return;

      # There's a bug in IO::Socket here, in that $S2 's ->socktype won't
      # yet be set. We can apply a horribly hacky fix here
      #   defined $S2->socktype and $S2->socktype == $socktype or
      #     ${*$S2}{io_socket_type} = $socktype;
      # But for now we'll skip the test for it instead
   }
   else {
      $S2 = $Stmp;
      $S1->connect( getsockname $S2 ) or return;
      $S2->connect( getsockname $S1 ) or return;
   }

   return ( $S1, $S2 );
}

# TODO: Move this into its own file, have it loaded dynamically via $^O
if( HAVE_MSWIN32 ) {
   # Win32 doesn't have a socketpair(). We'll fake one up

   undef *socketpair;
   *socketpair = sub {
      my $self = shift;
      my ( $family, $socktype, $proto ) = @_;

      $family = _getfamilybyname( $family ) || AF_INET;

      # SOCK_STREAM is the most likely
      $socktype = _getsocktypebyname( $socktype ) || SOCK_STREAM;

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
}

=head2 ( $rd, $wr ) = IO::Async::OS->pipepair

An abstraction of the C<pipe(2)> syscall, which returns the two new handles.

=cut

sub pipepair
{
   my $self = shift;

   pipe( my ( $rd, $wr ) ) or return;
   return ( $rd, $wr );
}

=head2 ( $rdA, $wrA, $rdB, $wrB ) = IO::Async::OS->pipequad

This method is intended for creating two pairs of filehandles that are linked
together, suitable for passing as the STDIN/STDOUT pair to a child process.
After this function returns, C<$rdA> and C<$wrA> will be a linked pair, as
will C<$rdB> and C<$wrB>.

On platforms that support C<socketpair(2)>, this implementation will be
preferred, in which case C<$rdA> and C<$wrB> will actually be the same
filehandle, as will C<$rdB> and C<$wrA>. This saves a file descriptor in the
parent process.

When creating a C<IO::Async::Stream> or subclass of it, the C<read_handle>
and C<write_handle> parameters should always be used.

 my ( $childRd, $myWr, $myRd, $childWr ) = IO::Async::OS->pipequad;

 IO::Async::OS->open_child(
    stdin  => $childRd,
    stdout => $childWr,
    ...
 );

 my $str = IO::Async::Stream->new(
    read_handle  => $myRd,
    write_handle => $myWr,
    ...
 );
 IO::Async::OS->add( $str );

=cut

sub pipequad
{
   my $self = shift;

   # Prefer socketpair
   if( my ( $S1, $S2 ) = $self->socketpair ) {
      return ( $S1, $S2, $S2, $S1 );
   }

   # Can't do that, fallback on pipes
   my ( $rdA, $wrA ) = $self->pipepair or return;
   my ( $rdB, $wrB ) = $self->pipepair or return;

   return ( $rdA, $wrA, $rdB, $wrB );
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
