#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007-2011 -- leonerd@leonerd.org.uk

package IO::Async::Resolver;

use strict;
use warnings;
use base qw( IO::Async::Function );

our $VERSION = '0.40';

BEGIN {
   # We're going to implement methods called getaddrinfo and getnameinfo. We
   # therefore need import them with different names prefixed with underscores

   my @constants = qw(
      AI_NUMERICHOST AI_PASSIVE
      NI_NUMERICHOST NI_NUMERICSERV NI_DGRAM
      EAI_NONAME
   );

   # Perl 5.13.9 or above has Socket::getaddrinfo support in core.
   # Before that we need to use Socket::GetAddrInfo
   if( require Socket and defined &Socket::getaddrinfo ) {
      Socket->import( @constants );

      *_getaddrinfo = \&Socket::getaddrinfo;
      *_getnameinfo = \&Socket::getnameinfo;
   }
   else {
      # We can't just perform an empty import and call fully-qualified because
      # Socket::GetAddrInfo's import method does special magic
      require Socket::GetAddrInfo;
      Socket::GetAddrInfo->import( qw( :newapi getaddrinfo getnameinfo ), @constants );

      my $stash = do { no strict 'refs'; \%{__PACKAGE__."::"} };
      $stash->{_getaddrinfo} = delete $stash->{getaddrinfo};
      $stash->{_getnameinfo} = delete $stash->{getnameinfo};
   }
}

BEGIN {
   # More cheating
   require IO::Async::Loop;
   *_getfamilybyname   = \&IO::Async::Loop::_getfamilybyname;
   *_getsocktypebyname = \&IO::Async::Loop::_getsocktypebyname;
}

use Time::HiRes qw( alarm );

use Carp;

my $started = 0;
my %METHODS;

=head1 NAME

C<IO::Async::Resolver> - performing name resolutions asynchronously

=head1 SYNOPSIS

This object is used indirectly via an C<IO::Async::Loop>:

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 $loop->resolver->getaddrinfo(
    host    => "www.example.com",
    service => "http",

    on_resolved => sub {
       foreach my $addr ( @_ ) {
          printf "http://www.example.com can be reached at " .
             "socket(%d,%d,%d) + connect('%v02x')\n",
             @{$addr}{qw( family socktype protocol addr )};
       }
    },

    on_error => sub {
       print "Cannot look up www.example.com - $_[-1]\n";
    },
 );

 $loop->resolve( type => 'getpwuid', data => [ $< ],
    on_resolved => sub {
       print "My passwd ent: " . join( "|", @_ ) . "\n";
    },

    on_error => sub {
       print "Cannot look up my passwd ent - $_[-1]\n";
    },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This module extends an C<IO::Async::Loop> to use the system's name resolver
functions asynchronously. It provides a number of named resolvers, each one
providing an asynchronous wrapper around a single resolver function.

Because the system may not provide asynchronous versions of its resolver
functions, this class is implemented using a C<IO::Async::Function> object
that wraps the normal (blocking) functions. In this case, name resolutions
will be performed asynchronously from the rest of the program, but will likely
be done by a single background worker process, so will be processed in the
order they were requested; a single slow lookup will hold up the queue of
other requests behind it. To mitigate this, multiple worker processes can be
used; see the C<workers> argument to the constructor.

The C<idle_timeout> parameter for the underlying C<IO::Async::Function> object
is set to a default of 30 seconds, and C<min_workers> is set to 0. This
ensures that there are no spare processes sitting idle during the common case
of no outstanding requests.

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;
   $self->SUPER::_init( @_ );

   $params->{code} = sub {
      my ( $type, $timeout, @data ) = @_;

      if( my $code = $METHODS{$type} ) {
         local $SIG{ALRM} = sub { die "Timed out\n" };

         alarm( $timeout );
         my @ret = eval { $code->( @data ) };
         alarm( 0 );

         die $@ if $@;
         return @ret;
      }
      else {
         die "Unrecognised resolver request '$type'";
      }
   };

   $params->{idle_timeout} = 30;
   $params->{min_workers}  = 0;

   $started = 1;
}

=head1 METHODS

=cut

=head2 $loop->resolve( %params )

Performs a single name resolution operation, as given by the keys in the hash.

The C<%params> hash keys the following keys:

=over 8

=item type => STRING

Name of the resolution operation to perform. See BUILT-IN RESOLVERS for the
list of available operations.

=item data => ARRAY

Arguments to pass to the resolver function. Exact meaning depends on the
specific function chosen by the C<type>; see BUILT-IN RESOLVERS.

=item timeout => NUMBER

Optional. Timeout in seconds, after which the resolver operation will abort
with a timeout exception. If not supplied, a default of 10 seconds will apply.

=item on_resolved => CODE

A continuation that is invoked when the resolver function returns a successful
result. It will be passed the array returned by the resolver function.

=item on_error => CODE

A continuation that is invoked when the resolver function fails. It will be
passed the exception thrown by the function.

=back

=cut

sub resolve
{
   my $self = shift;
   my %args = @_;

   my $type = $args{type};
   defined $type or croak "Expected 'type'";

   # Legacy
   $type = "getaddrinfo_array" if $type eq "getaddrinfo";

   exists $METHODS{$type} or croak "Expected 'type' to be an existing resolver method, got '$type'";

   my $on_resolved = $args{on_resolved};
   ref $on_resolved or croak "Expected 'on_resolved' to be a reference";

   my $on_error = $args{on_error};
   ref $on_error or croak "Expected 'on_error' to be a reference";

   my $timeout = $args{timeout} || 10;

   $self->call(
      args      => [ $type, $timeout, @{$args{data}} ],
      on_return => $on_resolved,
      on_error  => $on_error,
   );
}

=head2 $resolver->getaddrinfo( %args )

A shortcut wrapper around the C<getaddrinfo> resolver, taking its arguments in
a more convenient form.

=over 8

=item host => STRING

=item service => STRING

The host and service names to look up. At least one must be provided.

=item family => INT or STRING

=item socktype => INT or STRING

=item protocol => INT

Hint values used to filter the results.

=item flags => INT

Flags to control the C<getaddrinfo(3)> function. See the C<AI_*> constants in
L<Socket::GetAddrInfo> for more detail.

=item passive => BOOL

If true, sets the C<AI_PASSIVE> flag. This is provided as a convenience to
avoid the caller from having to import the C<AI_PASSIVE> constant from
whichever of C<Socket> or C<Socket::GetAddrInfo> it happens to be provided by.

=item timeout => NUMBER

Time in seconds after which to abort the lookup with a C<Timed out> exception

=item on_resolved => CODE

Callback which is invoked after a successful lookup. Will be passed a list of
HASH references; each containing one result. Each result will contain fields
called C<family>, C<socktype>, C<protocol> and C<addr>. If requested by
C<AI_CANONNAME> then the C<canonname> field will also be valid.

 $on_resolved->( @addrs )

=item on_error => CODE

Callback which is invoked after a failed lookup, including for a timeout.

 $on_error->( $exception )

=back

As a specific optimsation, this method will try to perform a lookup of numeric
values synchronously, rather than asynchronously, if it looks likely to
succeed.

Specifically, if the service name is entirely numeric, and the hostname looks
like an IPv4 or IPv6 string, a synchronous lookup will first be performed
using the C<AI_NUMERICHOST> flag. If this gives an C<EAI_NONAME> error, then
the lookup is performed asynchronously instead.

=cut

sub getaddrinfo
{
   my $self = shift;
   my %args = @_;

   my $host    = $args{host}    || "";
   my $service = $args{service} || "";
   my $flags   = $args{flags}   || 0;

   $flags |= AI_PASSIVE if $args{passive};

   $args{family}   = _getfamilybyname( $args{family} )     if defined $args{family};
   $args{socktype} = _getsocktypebyname( $args{socktype} ) if defined $args{socktype};

   # It's likely this will succeed with AI_NUMERICHOST if host contains only
   # [\d.] (IPv4) or [[:xdigit:]:] (IPv6)
   # Technically we should pass AI_NUMERICSERV but not all platforms support
   # it, but since we're checking service contains only \d we should be fine.

   # These address tests don't have to be perfect as if it fails we'll get
   # EAI_NONAME and just try it asynchronously anyway
   if( ( $host =~ m/^[\d.]+$/ or $host =~ m/^[[:xdigit:]:]$/ ) and
       $service =~ m/^\d+$/ ) {

       my ( $err, @results ) = _getaddrinfo( $host, $service,
          { %args, flags => $flags | AI_NUMERICHOST }
       );

       if( !$err ) {
          $args{on_resolved}->( @results );
          return;
       }
       elsif( $err == EAI_NONAME ) {
          # fallthrough to async case
       }
       else {
          $args{on_error}->( "$err\n" );
          return;
       }
   }

   $self->resolve(
      type    => "getaddrinfo_hash",
      # I really want hash slices
      data    => [ map { exists $args{$_} ? ( $_ => $args{$_} ) : () } qw( host service family socktype protocol flags ) ],
      timeout => $args{timeout},
      on_resolved => $args{on_resolved},
      on_error    => $args{on_error},
   );
}

=head2 $resolver->getnameinfo( %args )

A shortcut wrapper around the C<getnameinfo> resolver, taking its arguments in
a more convenient form.

=over 8

=item addr => STRING

The packed socket address to look up.

=item flags => INT

Flags to control the C<getnameinfo(3)> function. See the C<NI_*> constants in
L<Socket::GetAddrInfo> for more detail.

=item numerichost => BOOL

=item numericserv => BOOL

=item dgram => BOOL

If true, set the C<NI_NUMERICHOST>, C<NI_NUMERICSERV> or C<NI_DGRAM> flags.

=item numeric => BOOL

If true, sets both C<NI_NUMERICHOST> and C<NI_NUMERICSERV> flags.

=item timeout => NUMBER

Time in seconds after which to abort the lookup with a C<Timed out> exception

=item on_resolved => CODE

Callback which is invoked after a successful lookup. 

 $on_resolved->( $host, $service )

=item on_error => CODE

Callback which is invoked after a failed lookup, including for a timeout.

 $on_error->( $exception )

=back

As a specific optimsation, this method will try to perform a lookup of numeric
values synchronously, rather than asynchronously, if both the
C<NI_NUMERICHOST> and C<NI_NUMERICSERV> flags are given.

=cut

sub getnameinfo
{
   my $self = shift;
   my %args = @_;

   my $on_resolved = $args{on_resolved};
   ref $on_resolved or croak "Expected 'on_resolved' to be a reference";

   my $flags = $args{flags} || 0;

   $flags |= NI_NUMERICHOST if $args{numerichost};
   $flags |= NI_NUMERICSERV if $args{numericserv};
   $flags |= NI_DGRAM       if $args{dgram};

   $flags |= NI_NUMERICHOST|NI_NUMERICSERV if $args{numeric};

   if( $flags & (NI_NUMERICHOST|NI_NUMERICSERV) ) {
      # This is a numeric-only lookup that can be done synchronously
      my ( $err, $host, $service ) = _getnameinfo( $args{addr}, $flags );
      if( $err ) {
         $args{on_error}->( "$err\n" );
      }
      else {
         $on_resolved->( $host, $service );
      }
      return;
   }

   $self->resolve(
      type    => "getnameinfo",
      data    => [ $args{addr}, $flags ],
      timeout => $args{timeout},
      on_resolved => sub {
         $on_resolved->( @{ $_[0] } ); # unpack the ARRAY ref
      },
      on_error    => $args{on_error},
   );
}

=head1 FUNCTIONS

=cut

=head2 register_resolver( $name, $code )

Registers a new named resolver function that can be called by the C<resolve>
method. All named resolvers must be registered before the object is
constructed.

=over 8

=item $name

The name of the resolver function; must be a plain string. This name will be
used by the C<type> argument to the C<resolve()> method, to identify it.

=item $code

A CODE reference to the resolver function body. It will be called in list
context, being passed the list of arguments given in the C<data> argument to
the C<resolve()> method. The returned list will be passed to the
C<on_resolved> callback. If the code throws an exception at call time, it will
be passed to the C<on_error> continuation. If it returns normally, the list of
values it returns will be passed to C<on_resolved>.

=back

=cut

# Plain function, not a method
sub register_resolver
{
   my ( $name, $code ) = @_;

   croak "Cannot register new resolver methods once the resolver has been started" if $started;

   croak "Already have a resolver method called '$name'" if exists $METHODS{$name};
   $METHODS{$name} = $code;
}

=head1 BUILT-IN RESOLVERS

The following resolver names are implemented by the same-named perl function,
taking and returning a list of values exactly as the perl function does:

 getpwnam getpwuid
 getgrnam getgrgid
 getservbyname getservbyport
 gethostbyname gethostbyaddr
 getnetbyname getnetbyaddr
 getprotobyname getprotobynumber

=cut

# Now register the inbuilt methods

register_resolver getpwnam => sub { return getpwnam( $_[0] ) or die "$!\n" };
register_resolver getpwuid => sub { return getpwuid( $_[0] ) or die "$!\n" };

register_resolver getgrnam => sub { return getgrnam( $_[0] ) or die "$!\n" };
register_resolver getgrgid => sub { return getgrgid( $_[0] ) or die "$!\n" };

register_resolver getservbyname => sub { return getservbyname( $_[0], $_[1] ) or die "$!\n" };
register_resolver getservbyport => sub { return getservbyport( $_[0], $_[1] ) or die "$!\n" };

register_resolver gethostbyname => sub { return gethostbyname( $_[0] ) or die "$!\n" };
register_resolver gethostbyaddr => sub { return gethostbyaddr( $_[0], $_[1] ) or die "$!\n" };

register_resolver getnetbyname => sub { return getnetbyname( $_[0] ) or die "$!\n" };
register_resolver getnetbyaddr => sub { return getnetbyaddr( $_[0], $_[1] ) or die "$!\n" };

register_resolver getprotobyname   => sub { return getprotobyname( $_[0] ) or die "$!\n" };
register_resolver getprotobynumber => sub { return getprotobynumber( $_[0] ) or die "$!\n" };

# The Socket::GetAddrInfo-based ones

=pod

The following three resolver names are implemented using the the
C<Socket::GetAddrInfo> module.

 getaddrinfo_hash
 getaddrinfo_array
 getnameinfo

The C<getaddrinfo_hash> resolver takes arguments in a hash of name/value pairs
and returns a list of hash structures, as the C<getaddrinfo> function does under
the C<:newapi> tag. For neatness it takes all its arguments as named values;
taking the host and service names from arguments called C<host> and C<service>
respectively; all the remaining arguments are passed into the hints hash.

The C<getaddrinfo_array> resolver behaves more like the C<:Socket6api> version
of the function. It takes hints in a flat list, and mangles the result of the
function, so that the returned value is more useful to the caller. It splits
up the list of 5-tuples into a list of ARRAY refs, where each referenced array
contains one of the tuples of 5 values.

As an extra convenience to the caller, both resolvers will also accept plain
string names for the C<family> argument, converting C<inet> and possibly
C<inet6> into the appropriate C<AF_*> value, and for the C<socktype> argument,
converting C<stream>, C<dgram> or C<raw> into the appropriate C<SOCK_*> value.

For backward-compatibility with older code, the resolver name C<getaddrinfo>
is currently aliased to C<getaddrinfo_array>; but any code that wishes to rely
on the array-like nature of its arguments and return values, should request it
specifically by name, as this alias will be changed in a later version of
C<IO::Async>.

The C<getnameinfo> resolver returns its result in the same form as C<:newapi>.

Because this module simply uses the system's C<getaddrinfo> resolver, it will
be fully IPv6-aware if the underlying platform's resolver is. This allows
programs to be fully IPv6-capable.

=cut

register_resolver getaddrinfo_hash => sub {
   my %args = @_;

   my $host    = delete $args{host};
   my $service = delete $args{service};

   $args{family}   = _getfamilybyname( $args{family} )     if defined $args{family};
   $args{socktype} = _getsocktypebyname( $args{socktype} ) if defined $args{socktype};

   my ( $err, @addrs ) = _getaddrinfo( $host, $service, \%args );

   die "$err\n" if $err;

   return @addrs;
};

register_resolver getaddrinfo_array => sub {
   my ( $host, $service, $family, $socktype, $protocol, $flags ) = @_;

   $family   = _getfamilybyname( $family );
   $socktype = _getsocktypebyname( $socktype );

   my %hints;
   $hints{family}   = $family   if defined $family;
   $hints{socktype} = $socktype if defined $socktype;
   $hints{protocol} = $protocol if defined $protocol;
   $hints{flags}    = $flags    if defined $flags;

   my ( $err, @addrs ) = _getaddrinfo( $host, $service, \%hints );

   die "$err\n" if $err;

   # Convert the @addrs list into a list of ARRAY refs of 5 values each
   return map {
      [ $_->{family}, $_->{socktype}, $_->{protocol}, $_->{addr}, $_->{canonname} ]
   } @addrs;
};

register_resolver getnameinfo => sub {
   my ( $addr, $flags ) = @_;

   my ( $err, $host, $service ) = _getnameinfo( $addr, $flags || 0 );

   die "$err\n" if $err;

   return [ $host, $service ];
};

=head1 EXAMPLES

The following somewhat contrieved example shows how to implement a new
resolver function. This example just uses in-memory data, but a real function
would likely make calls to OS functions to provide an answer. In traditional
Unix style, a pair of functions are provided that each look up the entity by
either type of key, where both functions return the same type of list. This is
purely a convention, and is in no way required or enforced by the
C<IO::Async::Resolver> itself.

 @numbers = qw( zero  one   two   three four
                five  six   seven eight nine  );

 register_resolver getnumberbyindex => sub {
    my ( $index ) = @_;
    die "Bad index $index" unless $index >= 0 and $index < @numbers;
    return ( $index, $numbers[$index] );
 };

 register_resolver getnumberbyname => sub {
    my ( $name ) = @_;
    foreach my $index ( 0 .. $#numbers ) {
       return ( $index, $name ) if $numbers[$index] eq $name;
    }
    die "Bad name $name";
 };

=head1 TODO

=over 4

=item *

Look into (system-specific) ways of accessing asynchronous resolvers directly

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
