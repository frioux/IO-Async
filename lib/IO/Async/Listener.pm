#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2010 -- leonerd@leonerd.org.uk

package IO::Async::Listener;

use strict;
use warnings;
use base qw( IO::Async::Handle );

our $VERSION = '0.34';

use IO::Async::Handle;

use POSIX qw( EAGAIN );
use Socket::GetAddrInfo qw( :Socket6api AI_PASSIVE );

use Socket qw( sockaddr_family SOL_SOCKET SO_ACCEPTCONN SO_REUSEADDR SO_TYPE );

use Carp;

=head1 NAME

C<IO::Async::Listener> - listen on network sockets for incoming connections

=head1 SYNOPSIS

 use IO::Async::Listener;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $listener = IO::Async::Listener->new(
    on_stream => sub {
       my ( undef, $stream ) = @_;

       $stream->configure(
          on_read => sub {
             my ( $self, $buffref, $closed ) = @_;
             $self->write( $$buffref );
             $$buffref = "";
             return 0;
          },
       );
       
       $loop->add( $stream );
    },
 );

 $loop->add( $listener );

 $listener->listen(
    service  => "echo",
    socktype => 'stream',

    on_resolve_error => sub { print STDERR "Cannot resolve - $_[0]\n"; },
    on_listen_error  => sub { print STDERR "Cannot listen\n"; },
 );

 $loop->loop_forever;

This object can also be used indirectly via an C<IO::Async::Loop>:

 use IO::Async::Stream;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 $loop->listen(
    service  => "echo",
    socktype => 'stream',

    on_accept => sub {
       ...
    },

    on_resolve_error => sub { print STDERR "Cannot resolve - $_[0]\n"; },
    on_listen_error  => sub { print STDERR "Cannot listen\n"; },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This subclass of L<IO::Async::Handle> adds behaviour which watches a socket in
listening mode, to accept incoming connections on them.

A Listener can be constructed and given a existing socket in listening mode.
Alternatively, the Listener can construct a socket by calling the C<listen>
method. Either a list of addresses can be provided, or a service name can be
looked up using the underlying loop's C<resolve> method.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters:

=head2 on_accept $clientsocket

Invoked whenever a new client connects to the socket.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_accept => CODE

CODE reference for the C<on_accept> event.

=item on_stream => CODE

An alternative to C<on_accept>, a continuation that is passed an instance
of L<IO::Async::Stream> when a new client connects. This is provided as a
convenience for the common case that a Stream object is required as the
transport for a Protocol object.

 $on_stream->( $self, $stream )

=item on_socket => CODE

Similar to C<on_stream>, but constructs an instance of L<IO::Async::Socket>.
This is most useful for C<SOCK_DGRAM> or C<SOCK_RAW> sockets.

 $on_socket->( $self, $socket )

=item handle => IO

The IO handle containing an existing listen-mode socket.

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   if( exists $params{on_accept} ) {
      $self->{on_accept} = delete $params{on_accept};
   }
   elsif( exists $params{on_stream} ) {
      my $on_stream = delete $params{on_stream};
      require IO::Async::Stream;
      # TODO: It doesn't make sense to put a SOCK_DGRAM in an
      # IO::Async::Stream but currently we don't detect this
      $self->{on_accept} = sub {
         my ( $self, $handle ) = @_;
         $on_stream->( $self, IO::Async::Stream->new( handle => $handle ) );
      };
   }
   elsif( exists $params{on_socket} ) {
      my $on_socket = delete $params{on_socket};
      require IO::Async::Socket;
      $self->{on_accept} = sub {
         my ( $self, $handle ) = @_;
         $on_socket->( $self, IO::Async::Socket->new( handle => $handle ) );
      };
   }

   croak "Cannot set 'on_read_ready' on a Listener" if exists $params{on_read_ready};

   if( exists $params{handle} ) {
      my $handle = delete $params{handle};
      # Sanity check it - it may be a bare GLOB ref, not an IO::Socket-derived handle
      defined getsockname( $handle ) or croak "IO handle $handle does not have a sockname";

      # So now we know it's at least some kind of socket. Is it listening?
      # SO_ACCEPTCONN would tell us, but not all OSes implement it. Since it's
      # only a best-effort sanity check, we won't mind if the OS doesn't.
      my $acceptconn = getsockopt( $handle, SOL_SOCKET, SO_ACCEPTCONN );
      !defined $acceptconn or unpack( "I", $acceptconn ) or croak "Socket is not accepting connections";

      # This is a bit naughty but hopefully nobody will mind...
      bless $handle, "IO::Socket" if ref( $handle ) eq "GLOB";

      $self->SUPER::configure( read_handle => $handle );
   }

   if( !$self->{on_accept} and !$self->can( 'on_accept' ) ) {
      croak 'Expected either a on_accept callback or an ->on_accept method';
   }

   if( keys %params ) {
      croak "Cannot pass though configuration keys to underlying Handle - " . join( ", ", keys %params );
   }
}

sub on_read_ready
{
   my $self = shift;

   my $newclient = $self->read_handle->accept();

   if( defined $newclient ) {
      $newclient->blocking( 0 );

      # TODO: make class/callback
      if( $self->{on_accept} ) {
         $self->{on_accept}->( $self, $newclient );
      }
      else {
         $self->on_accept( $newclient );
      }
   }
   elsif( $! == EAGAIN ) {
      # No client ready after all. Perhaps we're sharing the listen
      # socket with other processes? Anyway; not fatal, just ignore it
   }
   else {
      # TODO: make a callback
      die "Cannot accept - $!";
   }
}

=head1 METHODS

=cut

sub is_listening
{
   my $self = shift;

   return ( defined $self->sockname );
}

=head2 $name = $listener->sockname

Returns the C<sockname> of the underlying listening socket

=cut

sub sockname
{
   my $self = shift;

   my $handle = $self->read_handle or return undef;
   return $handle->sockname;
}

=head2 $family = $listener->family

Returns the socket address family of the underlying listening socket

=cut

sub family
{
   my $self = shift;

   my $sockname = $self->sockname or return undef;
   return sockaddr_family( $sockname );
}

=head2 $socktype = $listener->socktype

Returns the socket type of the underlying listening socket

=cut

sub socktype
{
   my $self = shift;

   my $handle = $self->read_handle or return undef;
   return $handle->sockopt(SO_TYPE);
}

=head2 $listener->listen( %params )

This method sets up a listening socket using the addresses given, and will
invoke the C<on_accept> callback each time a new connection is accepted on the
socket. Addresses may be given directly, or they may be looked up using the
system's name resolver.

If multiple addresses are given, or resolved from the service and hostname,
then each will be attempted in turn until one succeeds.

In plain address mode, the C<%params> hash takes the following keys:

=over 8

=item addrs => ARRAY

Reference to an array of (possibly-multiple) address structures to attempt to
listen on. Each should be in the layout described for C<addr>. Such a layout
is returned by the C<getaddrinfo> named resolver.

=item addr => ARRAY

Shortcut for passing a single address to listen on; it may be passed directly
with this key, instead of in another array of its own.

The address (or each element of the C<addrs> array) should be a reference to
either a hash with the following keys:
 
 family, socktype, protocol, addr

or an array, with the following elements:

 [ $family, $socktype, $protocol, $address ]

The first three arguments will be passed to a C<socket()> call and, if
successful, the fourth to a C<bind()> call on the resulting socket. The socket
will then be C<listen()>ed to put it into listening mode. Any trailing
elements in this array will be ignored. Note that C<$address> must be a packed
socket address, such as returned by C<pack_sockaddr_in> or
C<pack_sockaddr_un>. See also the C<EXAMPLES> section,

=back

In named resolver mode, the C<%params> hash takes the following keys:

=over 8

=item service => STRING

The service name to listen on.

=item host => STRING

The hostname to listen on. Optional. Will listen on all addresses if not
supplied.

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

In either case, the following keys are also taken:

=over 8

=item on_listen => CODE

Optional. A callback that is invoked when the listening socket is ready.

 $on_listen->( $listener )

=item on_listen_error => CODE

A continuation this is invoked after all of the addresses have been tried, and
none of them succeeded. It will be passed the most significant error that
occurred, and the name of the operation it occurred in. Errors from the
C<listen()> syscall are considered most significant, then C<bind()>, then
C<sockopt()>, then finally C<socket()>.

=item on_fail => CODE

Optional. A callback that is invoked if a syscall fails while attempting to
create a listening sockets. It is passed the name of the syscall that failed,
the arguments that were passed to it, and the error generated. I.e.

 $on_fail->( "socket", $family, $socktype, $protocol, $! );

 $on_fail->( "sockopt", $sock, $optname, $optval, $! );

 $on_fail->( "bind", $sock, $address, $! );

 $on_fail->( "listen", $sock, $queuesize, $! );

=item queuesize => INT

Optional. The queue size to pass to the C<listen()> calls. If not supplied,
then 3 will be given instead.

=item reuseaddr => BOOL

Optional. If true or not supplied then the C<SO_REUSEADDR> socket option will
be set. To prevent this, pass a false value such as 0.

=back

As a convenience, it also supports a C<handle> argument, which is passed
directly to C<configure>.

=cut

sub listen
{
   my $self = shift;
   my ( %params ) = @_;

   my $loop = $self->get_loop;
   defined $loop or croak "Cannot listen when not a member of a Loop"; # TODO: defer?

   if( exists $params{handle} ) {
      my $handle = $params{handle};
      $self->configure( handle => $handle );
      return;
   }

   # Shortcut
   if( $params{addr} and not $params{addrs} ) {
      $params{addrs} = [ delete $params{addr} ];
   }

   my $on_listen = $params{on_listen}; # optional
   !defined $on_listen or ref $on_listen or croak "Expected 'on_listen' to be a reference";

   my $on_listen_error = $params{on_listen_error};
   ref $on_listen_error or croak "Expected 'on_listen_error' as a reference";

   my $on_fail = $params{on_fail};
   !defined $on_fail or ref $on_fail or croak "Expected 'on_fail' to be a reference";

   my $queuesize = $params{queuesize} || 3;

   if( my $addrlist = $params{addrs} ) {
      my $reuseaddr = 1;
      $reuseaddr = 0 if defined $params{reuseaddr} and not $params{reuseaddr};

      my ( $listenerr, $binderr, $sockopterr, $socketerr );

      foreach my $addr ( @$addrlist ) {
         my ( $family, $socktype, $proto, $address ) = 
            ref $addr eq "ARRAY" ? @$addr
                                 : @{$addr}{qw( family socktype protocol addr )};

         my $sock;

         unless( $sock = $loop->socket( $family, $socktype, $proto ) ) {
            $socketerr = $!;
            $on_fail->( "socket", $family, $socktype, $proto, $! ) if $on_fail;
            next;
         }

         if( $reuseaddr ) {
            unless( $sock->sockopt( SO_REUSEADDR, 1 ) ) {
               $sockopterr = $!;
               $on_fail->( "sockopt", $sock, SO_REUSEADDR, 1, $! ) if $on_fail;
               next;
            }
         }

         unless( $sock->bind( $address ) ) {
            $binderr = $!;
            $on_fail->( "bind", $sock, $address, $! ) if $on_fail;
            next;
         }

         unless( $sock->listen( $queuesize ) ) {
            $listenerr = $!;
            $on_fail->( "listen", $sock, $queuesize, $! ) if $on_fail;
            next;
         }

         $self->SUPER::configure( read_handle => $sock );

         $on_listen->( $self ) if defined $on_listen;

         return;
      }

      # If we got this far, then none of the addresses succeeded
      return $on_listen_error->( listen  => $listenerr  ) if $listenerr;
      return $on_listen_error->( bind    => $binderr    ) if $binderr;
      return $on_listen_error->( sockopt => $sockopterr ) if $sockopterr;
      return $on_listen_error->( socket  => $socketerr  ) if $socketerr;
      die 'Oops; $loop->listen failed but no error cause was found';
   }

   elsif( defined $params{service} ) {
      my $on_resolve_error = delete $params{on_resolve_error};
      ref $on_resolve_error or croak "Expected 'on_resolve_error' as a reference";

      my $host = delete $params{host} || "";

      my $service = delete $params{service};
      defined $service or $service = ""; # might be 0

      my %gai_hints;
      exists $params{$_} and $gai_hints{$_} = $params{$_} for qw( family socktype protocol flags );

      $gai_hints{flags} |= AI_PASSIVE;

      $loop->resolver->getaddrinfo(
         host    => $host,
         service => $service,
         %gai_hints,

         on_resolved => sub {
            $self->listen( 
               %params,
               addrs => [ @_ ],
            );
         },

         on_error => $on_resolve_error,
      );
   }

   else {
      croak "Expected either 'service' or 'addrs' or 'addr' arguments";
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 EXAMPLES

=head2 Listening on UNIX Sockets

The C<handle> argument can be passed an existing socket already in listening
mode, making it possible to listen on other types of socket such as UNIX
sockets.

 use IO::Async::Listener;
 use IO::Socket::UNIX;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $listener = IO::Async::Listener->new(
    on_stream => sub {
       my ( undef, $stream ) = @_;

       $stream->configure(
          on_read => sub {
             my ( $self, $buffref, $closed ) = @_;
             $self->write( $$buffref );
             $$buffref = "";
             return 0;
          },
       );
       
       $loop->add( $stream );
    },
 );

 $loop->add( $listener );

 my $socket = IO::Socket::UNIX->new(
    Local => "echo.sock",
    Listen => 1,
 ) or die "Cannot make UNIX socket - $!\n";

 $listener->listen(
    handle => $socket,
 );

 $loop->loop_forever;

=head2 Passing Packed Socket Addresses

The C<addr> or C<addrs> parameters should contain a packed socket address.
This example shows how to use the C<Socket> functions to construct one for
TCP port 8001 on address 10.0.0.1:

 use Socket qw( PF_INET SOCK_STREAM pack_sockaddr_in inet_aton );

 ...

 $listener->listen(
    addr => {
       family   => PF_INET,
       socktype => SOCK_STREAM,
       addr     => pack_sockaddr_in( 8001, inet_aton( "10.0.0.1" ) ),
    },
    ...
 );

This example shows another way to listen on a UNIX socket, similar to the
earlier example:

 use Socket qw( PF_UNIX SOCK_STREAM pack_sockaddr_un );

 ...

 $listener->listen(
    addr => {
       family   => PF_UNIX,
       socktype => SOCK_STREAM,
       addr     => pack_sockaddr_un( "echo.sock" ),
    },
    ...
 );

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
