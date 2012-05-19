#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2011 -- leonerd@leonerd.org.uk

package IO::Async::Connector;

use strict;
use warnings;

our $VERSION = '0.48';

use POSIX qw( EINPROGRESS );
use Socket qw( SOL_SOCKET SO_ERROR );

use CPS qw( kpar kforeach );

use Carp;

use constant HAVE_MSWIN32 => ( $^O eq "MSWin32" );

=head1 NAME

C<IO::Async::Connector> - perform non-blocking socket connections

=head1 SYNOPSIS

This object is used indirectly via an C<IO::Async::Loop>:

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 $loop->connect(
    host     => "www.example.com",
    service  => "http",
    socktype => 'stream',

    on_connected => sub {
       my ( $sock ) = @_;
       print "Now connected via $sock\n";
       ...
    },

    on_resolve_error => sub { die "Cannot resolve - $_[-1]\n"; },
    on_connect_error => sub { die "Cannot connect - $_[0] failed $_[-1]\n"; },
 );

=head1 DESCRIPTION

This module extends an C<IO::Async::Loop> to give it the ability to create
socket connections in a non-blocking manner.

There are two modes of operation. Firstly, a list of addresses can be provided
which will be tried in turn. Alternatively as a convenience, if a host and
service name are provided instead of a list of addresses, these will be
resolved using the underlying loop's C<resolve> method into the list of
addresses.

When attempting to connect to any among a list of addresses, there may be
failures among the first attempts, before a valid connection is made. For
example, the resolver may have returned some IPv6 addresses, but only IPv4
routes are valid on the system. In this case, the first C<connect(2)> syscall
will fail. This isn't yet a fatal error, if there are more addresses to try,
perhaps some IPv4 ones.

For this reason, it is possible that the operation eventually succeeds even
though some system calls initially fail. To be aware of individual failures,
the optional C<on_fail> callback can be used. This will be invoked on each
individual C<socket(2)> or C<connect(2)> failure, which may be useful for
debugging or logging.

Because this module simply uses the C<getaddrinfo> resolver, it will be fully
IPv6-aware if the underlying platform's resolver is. This allows programs to
be fully IPv6-capable.

=cut

# Internal constructor
sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $loop = delete $params{loop} or croak "Expected a 'loop'";

   my $self = bless {
      loop => $loop,
   }, $class;

   return $self;
}

=head1 METHODS

=cut

## Utility function
sub _get_sock_err
{
   my ( $sock ) = @_;

   my $err = $sock->getsockopt( SOL_SOCKET, SO_ERROR );

   if( defined $err ) {
      # 0 means no error, but is still defined
      return undef if !$err;

      $! = $err;
      return $!;
   }

   # It seems we can't call getsockopt to query SO_ERROR. We'll try getpeername
   if( defined getpeername( $sock ) ) {
      return undef;
   }

   my $peername_errno = $!+0;
   my $peername_errstr = "$!";

   # Not connected so we know this ought to fail
   if( read( $sock, my $buff, 1 ) ) {
      # That was most unexpected. getpeername fails because we're not
      # connected, yet read succeeds.
      warn "getpeername fails with $peername_errno ($peername_errstr) but read is successful\n";
      warn "Please see http://rt.cpan.org/Ticket/Display.html?id=38382\n";

      $! = $peername_errno;
      return $!;
   }

   return $!;
}

sub _connect_addresses
{
   my $self = shift;
   my ( $addrlist, $on_connected, $on_connect_error, $on_fail ) = @_;

   my $loop = $self->{loop};

   my $sock;
   my ( $connecterr, $binderr, $socketerr );

   kforeach( $addrlist,
      sub {
         my ( $addr, $knext, $klast ) = @_;
         my ( $family, $socktype, $protocol, $localaddr, $peeraddr ) = 
            @{$addr}{qw( family socktype protocol localaddr peeraddr )};

         $sock = $loop->socket( $family, $socktype, $protocol );

         if( !$sock ) {
            $socketerr = $!;
            $on_fail->( "socket", $family, $socktype, $protocol, $! ) if $on_fail;
            goto &$knext;
         }

         if( $localaddr and not $sock->bind( $localaddr ) ) {
            $binderr = $!;
            $on_fail->( "bind", $sock, $localaddr, $! ) if $on_fail;
            undef $sock;
            goto &$knext;
         }

         $sock->blocking( 0 );

         # TODO: $sock->connect returns success masking EINPROGRESS
         my $ret = connect( $sock, $peeraddr );
         if( $ret ) {
            # Succeeded already? Dubious, but OK. Can happen e.g. with connections to
            # localhost, or UNIX sockets, or something like that.
            goto &$klast;
         }
         # On MSWin32 this is reported as EWOULDBLOCK
         elsif( $! == EINPROGRESS or HAVE_MSWIN32 && $! == POSIX::EWOULDBLOCK ) {
            $loop->watch_io(
               handle => $sock,
               on_write_ready => sub {
                  $loop->unwatch_io( handle => $sock, on_write_ready => 1 );

                  my $err = _get_sock_err( $sock );

                  goto &$klast if !defined $err;

                  $connecterr = $!;
                  $on_fail->( "connect", $sock, $peeraddr, $err ) if $on_fail;
                  undef $sock;
                  goto &$knext;
               },
            );
         }
         else {
            $connecterr = $!;
            $on_fail->( "connect", $sock, $peeraddr, $! ) if $on_fail;
            undef $sock;
            goto &$knext;
         }
      },
      sub {
         if( $sock ) {
            return $on_connected->( $sock );
         }
         else {
            return $on_connect_error->( connect => $connecterr ) if $connecterr;
            return $on_connect_error->( bind    => $binderr    ) if $binderr;
            return $on_connect_error->( socket  => $socketerr  ) if $socketerr;
            # If it gets this far then something went wrong
            die 'Oops; $loop->connect failed but no error cause was found';
         }
      }
   );
}

=head2 $loop->connect( %params )

This method performs a non-blocking connection to a given address or set of
addresses, and invokes a continuation when the socket is connected.

In plain address mode, the C<%params> hash takes the following keys:

=over 8

=item addrs => ARRAY

Reference to an array of (possibly-multiple) address structures to attempt to
connect to. Each should be in the layout described for C<addr>. Such a layout
is returned by the C<getaddrinfo> named resolver.

=item addr => HASH or ARRAY

Shortcut for passing a single address to connect to; it may be passed directly
with this key, instead of in another array on its own. This should be in a
format recognised by L<IO::Async::Loop>'s C<extract_addrinfo> method. See also
the C<EXAMPLES> section.

=item local_addrs => ARRAY

=item local_addr => HASH or ARRAY

Optional. Similar to the C<addrs> or C<addr> parameters, these specify a local
address or set of addresses to C<bind(2)> the socket to before
C<connect(2)>ing it.

=item on_connected => CODE

A continuation that is invoked on a successful C<connect(22)> call to a valid
socket. It will be passed the connected socket handle, as an C<IO::Socket>
object.

 $on_connected->( $handle )

=item on_stream => CODE

An alternative to C<on_connected>, a continuation that is passed an instance
of L<IO::Async::Stream> when the socket is connected. This is provided as a
convenience for the common case that a Stream object is required as the
transport for a Protocol object.

 $on_stream->( $stream )

=item on_socket => CODE

Similar to C<on_stream>, but constructs an instance of L<IO::Async::Socket>.
This is most useful for C<SOCK_DGRAM> or C<SOCK_RAW> sockets.

 $on_socket->( $socket )

=item on_connect_error => CODE

A continuation that is invoked after all of the addresses have been tried, and
none of them succeeded. It will be passed the most significant error that
occurred, and the name of the operation it occurred in. Errors from the
C<connect(2)> syscall are considered most significant, then C<bind(2)>, then
finally C<socket(2)>.

 $on_connect_error->( $syscall, $! )

=item on_fail => CODE

Optional. After an individual C<socket(2)> or C<connect(2)> syscall has failed,
this callback is invoked to inform of the error. It is passed the name of the
syscall that failed, the arguments that were passed to it, and the error it
generated. I.e.

 $on_fail->( "socket", $family, $socktype, $protocol, $! );

 $on_fail->( "bind", $sock, $address, $! );

 $on_fail->( "connect", $sock, $address, $! );

Because of the "try all" nature when given a list of multiple addresses, this
callback may be invoked multiple times, even before an eventual success.

=back

When performing the resolution step too, the C<addrs> or C<addr> keys are
ignored, and instead the following keys are taken:

=over 8

=item host => STRING

=item service => STRING

The hostname and service name to connect to.

=item local_host => STRING

=item local_service => STRING

Optional. The hostname and/or service name to C<bind(2)> the socket to locally
before connecting to the peer.

=item family => INT

=item socktype => INT

=item protocol => INT

=item flags => INT

Optional. Other arguments to pass along with C<host> and C<service> to the
C<getaddrinfo> call.

=item socktype => STRING

Optionally may instead be one of the values C<'stream'>, C<'dgram'> or
C<'raw'> to stand for C<SOCK_STREAM>, C<SOCK_DGRAM> or C<SOCK_RAW>. This
utility is provided to allow the caller to avoid a separate C<use Socket> only
for importing these constants.

=item on_resolve_error => CODE

A continuation that is invoked when the name resolution attempt fails. This is
invoked in the same way as the C<on_error> continuation for the C<resolve>
method.

=back

It is necessary to pass the C<socktype> hint to the resolver when resolving
the host/service names into an address, as some OS's C<getaddrinfo> functions
require this hint. A warning is emitted if neither C<socktype> nor C<protocol>
hint is defined when performing a C<getaddrinfo> lookup. To avoid this warning
while still specifying no particular C<socktype> hint (perhaps to invoke some
OS-specific behaviour), pass C<0> as the C<socktype> value.

=cut

sub connect
{
   my $self = shift;
   my ( %params ) = @_;

   # Callbacks
   my $on_connected;
   if( $on_connected = delete $params{on_connected} ) {
      # all fine
   }
   elsif( my $on_stream = delete $params{on_stream} ) {
      require IO::Async::Stream;
      # TODO: It doesn't make sense to put a SOCK_DGRAM in an
      # IO::Async::Stream but currently we don't detect this
      $on_connected = sub {
         my ( $handle ) = @_;
         $on_stream->( IO::Async::Stream->new( handle => $handle ) );
      };
   }
   elsif( my $on_socket = delete $params{on_socket} ) {
      require IO::Async::Socket;
      $on_connected = sub {
         my ( $handle ) = @_;
         $on_socket->( IO::Async::Socket->new( handle => $handle ) );
      };
   }
   else {
      croak "Expected 'on_connected' or 'on_stream' callback";
   }

   my $on_connect_error = $params{on_connect_error} or croak "Expected 'on_connect_error' callback";

   my $on_fail = $params{on_fail};

   my $loop = $self->{loop};

   my %gai_hints;
   exists $params{$_} and $gai_hints{$_} = $params{$_} for qw( family socktype protocol flags );

   if( exists $params{host} or exists $params{local_host} or exists $params{local_port} ) {
      # We'll be making a ->getaddrinfo call
      defined $gai_hints{socktype} or defined $gai_hints{protocol} or
         carp "Attempting to ->connect without either 'socktype' or 'protocol' hint is not portable";
   }

   my @localaddrs;
   my @peeraddrs;

   kpar(
      sub {
         my ( $k ) = @_;
         if( exists $params{host} and exists $params{service} ) {
            my $on_resolve_error = $params{on_resolve_error} or croak "Expected 'on_resolve_error' callback";

            my $host    = $params{host}    or croak "Expected 'host'";
            my $service = $params{service} or croak "Expected 'service'";

            $loop->resolver->getaddrinfo(
               host    => $host,
               service => $service,
               %gai_hints,

               on_error => $on_resolve_error,

               on_resolved => sub {
                  @peeraddrs = @_;
                  goto &$k;
               },
            );
         }
         elsif( exists $params{addrs} or exists $params{addr} ) {
            @peeraddrs = exists $params{addrs} ? @{ $params{addrs} } : ( $params{addr} );
            goto &$k;
         }
         else {
            croak "Expected 'host' and 'service' or 'addrs' or 'addr' arguments";
         }
      },
      sub {
         my ( $k ) = @_;
         if( defined $params{local_host} or defined $params{local_service} ) {
            my $on_resolve_error = $params{on_resolve_error} or croak "Expected 'on_resolve_error' callback";

            # Empty is fine on either of these
            my $host    = $params{local_host};
            my $service = $params{local_service};

            $loop->resolver->getaddrinfo(
               host    => $host,
               service => $service,
               %gai_hints,

               on_error => $on_resolve_error,

               on_resolved => sub {
                  @localaddrs = @_;
                  goto &$k;
               },
            );
         }
         elsif( exists $params{local_addrs} or exists $params{local_addr} ) {
            @localaddrs = exists $params{local_addrs} ? @{ $params{local_addrs} } : ( $params{local_addr} );
            goto &$k;
         }
         else {
            @localaddrs = ( {} );
            goto &$k;
         }
      },
      sub {
         my @addrs;

         foreach my $local ( @localaddrs ) {
            my ( $l_family, $l_socktype, $l_protocol, $l_addr ) = 
               $loop->extract_addrinfo( $local, 'local_addr' );
            foreach my $peer ( @peeraddrs ) {
               my ( $p_family, $p_socktype, $p_protocol, $p_addr ) = 
                  $loop->extract_addrinfo( $peer );

               next if $l_family   and $p_family   and $l_family   != $p_family;
               next if $l_socktype and $p_socktype and $l_socktype != $p_socktype;
               next if $l_protocol and $p_protocol and $l_protocol != $p_protocol;

               push @addrs, {
                  family    => $l_family   || $p_family,
                  socktype  => $l_socktype || $p_socktype,
                  protocol  => $l_protocol || $p_protocol,
                  localaddr => $l_addr,
                  peeraddr  => $p_addr,
               };
            }
         }

         $self->_connect_addresses( \@addrs, $on_connected, $on_connect_error, $on_fail );
      }
   );
}

=head1 EXAMPLES

=head2 Passing Plain Socket Addresses

The C<addr> or C<addrs> parameters should contain a definition of a plain
socket address in a form that the L<IO::Async::Loop> C<extract_addrinfo>
method can use.

This example shows how to use the C<Socket> functions to construct one for TCP
port 8001 on address 10.0.0.1:

 $loop->connect(
    addr => {
       family   => "inet",
       socktype => "stream",
       port     => 8001,
       ip       => "10.0.0.1",
    },
    ...
 );

This example shows another way to connect to a UNIX socket at F<echo.sock>.

 $loop->connect(
    addr => {
       family   => "unix",
       socktype => "stream",
       path     => "echo.sock",
    },
    ...
 );

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
