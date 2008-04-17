#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package IO::Async::Listener;

use strict;

our $VERSION = '0.14_1';

use IO::Async::Notifier;

use POSIX qw( EAGAIN );
use IO::Socket; # For the actual sockets that are created
use Socket::GetAddrInfo qw( :Socket6api AI_PASSIVE );

use Carp;

=head1 NAME

C<IO::Async::Listener> - listen on network sockets for incoming connections

=head1 SYNOPSIS

This object is used indirectly via an C<IO::Async::Loop>:

 use Socket qw( SOCK_STREAM );

 use IO::Async::Stream;

 use IO::Async::Loop::IO_Poll;
 my $loop = IO::Async::Loop::IO_Poll->new();

 $loop->enable_childmanager;

 $loop->listen(
    service  => "echo",
    socktype => SOCK_STREAM,

    on_accept => sub {
       my ( $newclient ) = @_;

       $loop->add( IO::Async::Stream->new(
          handle => $newclient,

          on_read => sub {
             my ( $self, $buffref, $closed ) = @_;
             $self->write( $$buffref );
             $$buffref = "";
             return 0;
          },
       ) );
    },

    on_resolve_error => sub { print STDERR "Cannot resolve - $_[0]\n"; },
    on_error         => sub { print STDERR "Cannot $_[0] - $_[-1]\n"; },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This module extends an C<IO::Async::Loop> to give it the ability to create
listening sockets, and accept incoming connections on them.

There are two modes of operation. Firstly, a list of addresses can be provided
which will be listened on. Alternatively as a convenience, if a service name
is provided instead of a list of addresses, then these will be resolved using
the underlying loop's C<resolve()> method into a list of addresses.

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

=head2 $loop->listen( %params )

This method sets up a listening socket per address it is given, and will
invoke a callback each time a new connection is accepted on a socket.
Addresses may be given directly, or they may be looked up using the
system's name resolver.

In plain address mode, the C<%params> hash takes the following keys:

=over 8

=item addrs => ARRAY

Reference to an array of (possibly-multiple) address structures to listen on.
Each should be in the layout described for C<addr>. Such a layout is returned
by the C<getaddrinfo> named resolver.

=item addr => ARRAY

Shortcut for passing a single address to listen on; it may be passed directly
with this key, instead of in another array of its own.

The address (or each element of the C<addrs> array) should be a reference to
an array, with at least the following elements:

 [ $family, $socktype, $protocol, $address ]

The first three arguments will be passed to a C<socket()> call and, if
successful, the fourth to a C<bind()> call on the resulting socket. The socket
will then be C<listen()>ed to put it into listening mode. Any trailing
elements in this array will be ignored.

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

=item on_resolve_error => CODE

A callback that is invoked when the name resolution attempt fails. This is
invoked in the same way as the C<on_error> callback for the C<resolve> method.

=back

In either case, the following keys are also taken:

=over 8

=item on_accept => CODE

A callback that is invoked whenever a new client connects to any of the
sockets being listened on. It is passed the new socket handle

 $on_accept->( $clientsocket );

=item on_listen => CODE

Optional. A callback that is invoked when each listening socket is ready.
Typically this would be used in the name resolver case, in order to inspect
the socket's sockname address, or otherwise inspect the filehandle.

 $on_listen->( $listensocket );

=item on_error => CODE

A callback that is invoked if a syscall fails while attempting to create the
listening sockets. It is passed the name of the syscall that failed, the
arguments that were passed to it, and the error generated. I.e.

 $on_error->( "socket", $family, $socktype, $protocol, $! );

 $on_error->( "bind", $sock, $address, $! );

 $on_error->( "listen", $sock, $queuesize, $! );

=item queuesize => INT

Optional. The queue size to pass to the C<listen()> calls. If not supplied,
then 3 will be given instead.

=back

If more than one address is provided or resolved, then a separate listening
socket will be created on each.

=cut

sub listen
{
   my $self = shift;
   my ( %params ) = @_;

   my $on_accept = $params{on_accept};
   ref $on_accept eq "CODE" or croak "Expected 'on_accept' as CODE reference";

   my $on_listen = $params{on_listen}; # optional
   !defined $on_listen or ref $on_listen eq "CODE" or croak "Expected 'on_listen' to be a CODE reference";

   my $on_error = $params{on_error};
   ref $on_error eq "CODE" or croak "Expected 'on_error' as a CODE reference";

   my $queuesize = $params{queuesize} || 3;

   my $loop = $self->{loop};

   # Shortcut
   if( $params{addr} and not $params{addrs} ) {
      $params{addrs} = [ delete $params{addr} ];
   }

   if( my $addrlist = $params{addrs} ) {
      foreach my $addr ( @$addrlist ) {
         my ( $family, $socktype, $proto, $address ) = @$addr;

         my $sock = IO::Socket->new();

         unless( $sock->socket( $family, $socktype, $proto ) ) {
            $on_error->( "socket", $family, $socktype, $proto, $! );
            next;
         }

         unless( $sock->bind( $address ) ) {
            $on_error->( "bind", $sock, $address, $! );
            next;
         }

         unless( $sock->listen( $queuesize ) ) {
            $on_error->( "listen", $sock, $queuesize, $! );
            next;
         }

         $on_listen->( $sock ) if defined $on_listen;

         my $notifier = IO::Async::Notifier->new(
            read_handle => $sock,
            on_read_ready => sub {
               my $newclient = $sock->accept();
               defined $newclient or $! == EAGAIN or die "Cannot accept - $!";

               $on_accept->( $newclient );
               # TODO: Consider what it might return
            },
         );

         $loop->add( $notifier );
      }
   }

   elsif( defined $params{service} ) {
      my $on_resolve_error = delete $params{on_resolve_error};
      ref $on_resolve_error eq "CODE" or croak "Expected 'on_resolve_error' as CODE reference";

      my $host = delete $params{host} || "";

      my $service = delete $params{service};
      defined $service or $service = ""; # might be 0

      my $family   = delete $params{family} || 0;
      my $socktype = delete $params{socktype} || 0;
      my $protocol = delete $params{protocol} || 0;

      my $flags = ( delete $params{flags} || 0 ) | AI_PASSIVE;

      $loop->resolve(
         type => 'getaddrinfo',
         data => [ $host, $service, $family, $socktype, $protocol, $flags ],

         on_resolved => sub {
            $loop->listen( 
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

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
