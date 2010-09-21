#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2010 -- leonerd@leonerd.org.uk

package IO::Async::Connector;

use strict;
use warnings;

our $VERSION = '0.30';

use POSIX qw( EINPROGRESS );
use Socket qw( SOL_SOCKET SO_ERROR );

use Carp;

=head1 NAME

C<IO::Async::Connector> - perform non-blocking socket connections

=head1 SYNOPSIS

This object is used indirectly via an C<IO::Async::Loop>:

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 $loop->connect(
    host     => "www.example.com",
    service  => "http",
    socktype => 'stream',

    on_connected => sub {
       my ( $sock ) = @_;
       print "Now connected via $sock\n";
       ...
    },

    on_resolve_error => sub { print STDERR "Cannot resolve - $_[0]\n"; },
    on_connect_error => sub { print STDERR "Cannot connect\n"; },
 );

=head1 DESCRIPTION

This module extends an C<IO::Async::Loop> to give it the ability to create
socket connections in a non-blocking manner.

There are two modes of operation. Firstly, a list of addresses can be provided
which will be tried in turn. Alternatively as a convenience, if a host and
service name are provided instead of a list of addresses, these will be
resolved using the underlying loop's C<resolve()> method into the list of
addresses.

When attempting to connect to any among a list of addresses, there may be
failures among the first attempts, before a valid connection is made. For
example, the resolver may have returned some IPv6 addresses, but only IPv4
routes are valid on the system. In this case, the first C<connect()> syscall
will fail. This isn't yet a fatal error, if there are more addresses to try,
perhaps some IPv4 ones.

For this reason, the error reporting cannot report which failure is
responsible for the failure to connect. On success, the C<on_connected>
continuation is invoked with a connected socket. When all addresses have been
tried and failed, C<on_connect_error> is invoked, though no error string can
be provided, as there isn't a "clear winner" which is responsible for the
failure.

To be aware of individual failures, the optional C<on_fail> callback can be
used. This will be invoked on each individual C<socket()> or C<connect()>
failure, which may be useful for debugging or logging.

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
      # That was most unexpected. getpeername() fails because we're not
      # connected, yet read() succeeds.
      warn "getpeername() fails with $peername_errno ($peername_errstr) but read() is successful\n";
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
   my $address;

   while( my $addr = shift @$addrlist ) {
      ( my ( $family, $socktype, $proto ), $address ) = @$addr;

      $sock = $loop->socket( $family, $socktype, $proto ) and last;

      undef $sock;
      $on_fail->( "socket", $family, $socktype, $proto, $! ) if $on_fail;
   }

   if( not $sock and not @$addrlist ) {
      # Have now ran out of addresses to use
      $on_connect_error->();
      return;
   }

   $sock->blocking( 0 );

   my $ret = connect( $sock, $address );
   if( $ret ) {
      # Succeeded already? Dubious, but OK. Can happen e.g. with connections to
      # localhost, or UNIX sockets, or something like that.
      $on_connected->( $sock );
      return; # All done
   }
   elsif( $! != EINPROGRESS ) {
      $on_fail->( "connect", $sock, $address, $! ) if $on_fail;
      $self->_connect_addresses( $addrlist, $on_connected, $on_connect_error, $on_fail );
      return;
   }

   $loop->watch_io(
      handle => $sock,

      on_write_ready => sub {
         # Whatever happens we want to remove this watch, it's now done its job.
         # Do it early before we forget

         $loop->unwatch_io( handle => $sock, on_write_ready => 1 );

         my $err = _get_sock_err( $sock );

         if( !defined $err ) {
             $on_connected->( $sock );
             return;
         }

         $on_fail->( "connect", $sock, $address, $err ) if $on_fail;

         # Try the next one
         $self->_connect_addresses( $addrlist, $on_connected, $on_connect_error, $on_fail );
         return;
      },
   );

   # All done for now; all we can do is wait on that to complete
   return;
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

=item addr => ARRAY

Shortcut for passing a single address to connect to; it may be passed directly
with this key, instead of in another array on its own.

The address (or each element of the C<addrs> array) should be a reference to
an array, with at least the following elements:

 [ $family, $socktype, $protocol, $address ]

The first three arguments will be passed to a C<socket()> call and, if
successful, the fourth to a C<connect()> call on the resulting socket. Any
trailing elements will be ignored.

=item on_connected => CODE

A continuation that is invoked on a successful C<connect()> call to a valid
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
none of them succeeded. Because there is no one error message that stands out
as particularly noteworthy, none is given to this continuation. To track
individual errors, see the C<on_fail> callback.

=item on_fail => CODE

Optional. After an individual C<socket()> or C<connect()> syscall has failed,
this callback is invoked to inform of the error. It is passed the name of the
syscall that failed, the arguments that were passed to it, and the error it
generated. I.e.

 $on_fail->( "socket", $family, $socktype, $protocol, $! );

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

=item family => INT

=item socktype => INT

=item protocol => INT

=item flags => INT

Optional. Other arguments to pass along with C<host> and C<service> to the
C<getaddrinfo()> call.

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

It is sometimes necessary to pass the C<socktype> hint to the resolver when
resolving the host/service names into an address, as some OS's C<getaddrinfo>
functions require this hint.

=cut

sub connect
{
   my $self = shift;
   my ( %params ) = @_;

   my $timeout = $params{timeout};
   $timeout = 30 if !defined $timeout;

   # Callbacks
   my $on_connected;
   if( $on_connected = delete $params{on_connected} ) {
      # all fine
   }
   elsif( my $on_stream = delete $params{on_stream} ) {
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

   if( exists $params{host} and exists $params{service} ) {
      my $on_resolve_error = $params{on_resolve_error} or croak "Expected 'on_resolve_error' callback";

      my $host    = $params{host}    or croak "Expected 'host'";
      my $service = $params{service} or croak "Expected 'service'";

      my $loop = $self->{loop};

      my $family   = $params{family}   || 0;

      my $socktype;
      if( $params{type} ) {
         carp( "'type' deprecated, use 'socktype' instead" );
         $socktype = $params{type} || 0;
      }
      else {
         $socktype = $params{socktype} || 0;
      }

      my $protocol = $params{protocol} || 0;
      my $flags    = $params{flags}    || 0;

      $loop->resolve(
         type => 'getaddrinfo',
         data => [ $host, $service, $family, $socktype, $protocol, $flags ],

         on_error => $on_resolve_error,

         on_resolved => sub {
            my @addrs = @_;
            $self->_connect_addresses( \@addrs, $on_connected, $on_connect_error, $on_fail );
         },
      );
   }
   elsif( exists $params{addrs} or exists $params{addr} ) {
      my @addrs = exists $params{addrs} ? @{ $params{addrs} } : ( $params{addr} );
      $self->_connect_addresses( \@addrs, $on_connected, $on_connect_error, $on_fail );
   }
   else {
      croak "Expected 'host' and 'service' or 'addrs' or 'addr' arguments";
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
