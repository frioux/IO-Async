#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2011 -- leonerd@leonerd.org.uk

package IO::Async::Listener;

use strict;
use warnings;
use base qw( IO::Async::Handle );

our $VERSION = '0.54';

use IO::Async::Handle;
use IO::Async::OS;

use Errno qw( EAGAIN EWOULDBLOCK );

use Socket qw(
   sockaddr_family
   SOL_SOCKET SO_ACCEPTCONN SO_REUSEADDR SO_TYPE
   AF_INET6 IPPROTO_IPV6 IPV6_V6ONLY
);

use Carp;

=head1 NAME

C<IO::Async::Listener> - listen on network sockets for incoming connections

=head1 SYNOPSIS

 use IO::Async::Listener;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 my $listener = IO::Async::Listener->new(
    on_stream => sub {
       my ( undef, $stream ) = @_;

       $stream->configure(
          on_read => sub {
             my ( $self, $buffref, $eof ) = @_;
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

 $loop->run;

This object can also be used indirectly via an C<IO::Async::Loop>:

 use IO::Async::Stream;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 $loop->listen(
    service  => "echo",
    socktype => 'stream',

    on_stream => sub {
       ...
    },

    on_resolve_error => sub { print STDERR "Cannot resolve - $_[0]\n"; },
    on_listen_error  => sub { print STDERR "Cannot listen\n"; },
 );

 $loop->run;

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

=head2 on_stream $stream

An alternative to C<on_accept>, this an instance of L<IO::Async::Stream> when
a new client connects. This is provided as a convenience for the common case
that a Stream object is required as the transport for a Protocol object.

=head2 on_socket $socket

Similar to C<on_stream>, but constructs an instance of L<IO::Async::Socket>.
This is most useful for C<SOCK_DGRAM> or C<SOCK_RAW> sockets.

=head2 on_accept_error $socket, $errno

Optional. Invoked if the C<accept> syscall indicates an error (other than
C<EAGAIN> or C<EWOULDBLOCK>). If not provided, failures of C<accept> will
simply be ignored.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_accept => CODE

=item on_stream => CODE

=item on_socket => CODE

CODE reference for the event handlers. Because of the mutually-exclusive
nature of their behaviour, only one of these may be set at a time. Setting one
will remove the other two.

=item handle => IO

The IO handle containing an existing listen-mode socket.

=back

=cut

my @acceptor_events  = qw( on_accept on_stream on_socket );

sub configure
{
   my $self = shift;
   my %params = @_;

   if( grep exists $params{$_}, @acceptor_events ) {
      grep( defined $_, @params{@acceptor_events} ) <= 1 or
         croak "Can only set at most one of 'on_accept', 'on_stream' or 'on_socket'";

      # Don't exists-test, so we'll clear the other two
      $self->{$_} = delete $params{$_} for @acceptor_events;
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

   unless( grep $self->can_event( $_ ), @acceptor_events ) {
      croak "Expected to be able to 'on_accept', 'on_stream' or 'on_socket'";
   }

   if( keys %params ) {
      croak "Cannot pass though configuration keys to underlying Handle - " . join( ", ", keys %params );
   }
}

sub on_read_ready
{
   my $self = shift;

   my $socket = $self->read_handle;
   my $handle = $socket->accept;

   if( defined $handle ) {
      $handle->blocking( 0 );

      if( $self->can_event( "on_stream" ) ) {
         # TODO: It doesn't make sense to put a SOCK_DGRAM in an
         # IO::Async::Stream but currently we don't detect this
         require IO::Async::Stream;
         $self->invoke_event( on_stream => IO::Async::Stream->new( handle => $handle ) );
      }
      elsif( $self->can_event( "on_socket" ) ) {
         require IO::Async::Socket;
         $self->invoke_event( on_socket => IO::Async::Socket->new( handle => $handle ) );
      }
      # on_accept needs to be last in case of multiple layers of subclassing
      elsif( $self->can_event( "on_accept" ) ) {
         $self->invoke_event( on_accept => $handle );
      }
      else {
         die "ARG! Missing on_accept,on_stream,on_socket!";
      }
   }
   elsif( $! == EAGAIN or $! == EWOULDBLOCK ) {
      # ignore
   }
   else {
      $self->maybe_invoke_event( on_accept_error => $socket, $! );
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
with this key, instead of in another array of its own. This should be in a
format recognised by L<IO::Async::OS>'s C<extract_addrinfo> method. See also
the C<EXAMPLES> section.

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

In either case, the following keys are also taken:

=over 8

=item on_listen => CODE

Optional. A callback that is invoked when the listening socket is ready.

 $on_listen->( $listener )

=item on_listen_error => CODE

A continuation this is invoked after all of the addresses have been tried, and
none of them succeeded. It will be passed the most significant error that
occurred, and the name of the operation it occurred in. Errors from the
C<listen(2)> syscall are considered most significant, then C<bind(2)>, then
C<sockopt(2)>, then finally C<socket(2)>.

=item on_fail => CODE

Optional. A callback that is invoked if a syscall fails while attempting to
create a listening sockets. It is passed the name of the syscall that failed,
the arguments that were passed to it, and the error generated. I.e.

 $on_fail->( "socket", $family, $socktype, $protocol, $! );

 $on_fail->( "sockopt", $sock, $optname, $optval, $! );

 $on_fail->( "bind", $sock, $address, $! );

 $on_fail->( "listen", $sock, $queuesize, $! );

=item queuesize => INT

Optional. The queue size to pass to the C<listen(2)> calls. If not supplied,
then 3 will be given instead.

=item reuseaddr => BOOL

Optional. If true or not supplied then the C<SO_REUSEADDR> socket option will
be set. To prevent this, pass a false value such as 0.

=item v6only => BOOL

Optional. If defined, sets or clears the C<IPV6_V6ONLY> socket option on
C<PF_INET6> sockets. This option disables the ability of C<PF_INET6> socket to
accept connections from C<AF_INET> addresses. Not all operating systems allow
this option to be disabled.

=back

As a convenience, it also supports a C<handle> argument, which is passed
directly to C<configure>.

=cut

sub listen
{
   my $self = shift;
   my ( %params ) = @_;

   my $loop = $self->loop;
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

      my $v6only = $params{v6only};

      my ( $listenerr, $binderr, $sockopterr, $socketerr );

      foreach my $addr ( @$addrlist ) {
         my ( $family, $socktype, $proto, $address ) = IO::Async::OS->extract_addrinfo( $addr );

         my $sock;

         unless( $sock = IO::Async::OS->socket( $family, $socktype, $proto ) ) {
            $socketerr = $!;
            $on_fail->( socket => $family, $socktype, $proto, $! ) if $on_fail;
            next;
         }

         if( $reuseaddr ) {
            unless( $sock->sockopt( SO_REUSEADDR, 1 ) ) {
               $sockopterr = $!;
               $on_fail->( sockopt => $sock, SO_REUSEADDR, 1, $! ) if $on_fail;
               next;
            }
         }

         if( defined $v6only and $family == AF_INET6 ) {
            unless( $sock->setsockopt( IPPROTO_IPV6, IPV6_V6ONLY, $v6only ) ) {
               $sockopterr = $!;
               $on_fail->( sockopt => $sock, IPV6_V6ONLY, $v6only, $! ) if $on_fail;
               next;
            }
         }

         unless( $sock->bind( $address ) ) {
            $binderr = $!;
            $on_fail->( bind => $sock, $address, $! ) if $on_fail;
            next;
         }

         unless( $sock->listen( $queuesize ) ) {
            $listenerr = $!;
            $on_fail->( listen => $sock, $queuesize, $! ) if $on_fail;
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

      defined $gai_hints{socktype} or defined $gai_hints{protocol} or
         carp "Attempting to ->listen without either 'socktype' or 'protocol' hint is not portable";

      $loop->resolver->getaddrinfo(
         host    => $host,
         service => $service,
         passive => 1,
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

=head1 EXAMPLES

=head2 Listening on UNIX Sockets

The C<handle> argument can be passed an existing socket already in listening
mode, making it possible to listen on other types of socket such as UNIX
sockets.

 use IO::Async::Listener;
 use IO::Socket::UNIX;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 my $listener = IO::Async::Listener->new(
    on_stream => sub {
       my ( undef, $stream ) = @_;

       $stream->configure(
          on_read => sub {
             my ( $self, $buffref, $eof ) = @_;
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

 $loop->run;

=head2 Passing Plain Socket Addresses

The C<addr> or C<addrs> parameters should contain a definition of a plain
socket address in a form that the L<IO::Async::OS> C<extract_addrinfo>
method can use.

This example shows how to use the C<Socket> functions to construct one for
TCP port 8001 on address 10.0.0.1:

 $listener->listen(
    addr => {
       family   => "inet",
       socktype => "stream",
       port     => 8001,
       ip       => "10.0.0.1",
    },
    ...
 );

This example shows another way to listen on a UNIX socket, similar to the
earlier example:

 $listener->listen(
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
