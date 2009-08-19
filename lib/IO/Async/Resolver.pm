#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2008 -- leonerd@leonerd.org.uk

package IO::Async::Resolver;

use strict;
use warnings;

our $VERSION = '0.23';

use Socket::GetAddrInfo qw( :Socket6api getaddrinfo getnameinfo );

use Carp;

my $started = 0;
my %METHODS;

=head1 NAME

C<IO::Async::Resolver> - performing name resolutions asynchronously

=head1 SYNOPSIS

This object is used indirectly via an C<IO::Async::Loop>:

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 $loop->resolve( type => 'getpwuid', data => [ $< ],
    on_resolved => 
       sub { print "My passwd ent: " . join( "|", @_ ) . "\n" },

    on_error =>
       sub { print "Cannot look up my passwd ent - $_[0]\n" },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This module extends an C<IO::Async::Loop> to use the system's name resolver
functions asynchronously. It provides a number of named resolvers, each one
providing an asynchronous wrapper around a single resolver function.

Because the system may not provide asynchronous versions of its resolver
functions, this class is implemented using a C<IO::Async::DetachedCode> object
that wraps the normal (blocking) functions. In this case, name resolutions
will be performed asynchronously from the rest of the program, but will likely
be done by a single background worker process, so will be processed in the
order they were requested; a single slow lookup will hold up the queue of
other requests behind it. To mitigate this, multiple worker processes can be
used; see the C<workers> argument to the constructor.

=cut

# Internal constructor
sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $loop = delete $params{loop} or croak "Expected a 'loop'";

   my $workers = delete $params{workers};

   my $code = $loop->detach_code(
      code => sub {
         my ( $type, @data ) = @_;

         if( my $code = $METHODS{$type} ) {
            return $code->( @data );
         }
         else {
            die "Unrecognised resolver request '$type'";
         }
      },

      marshaller => 'storable',

      workers => $workers,
   );

   $started = 1;

   my $self = bless {
      code => $code,
   }, $class;

   return $self;
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
   exists $METHODS{$type} or croak "Expected 'type' to be an existing resolver method, got '$type'";

   my $on_resolved = $args{on_resolved};
   ref $on_resolved eq "CODE" or croak "Expected 'on_resolved' to be a CODE reference";

   my $on_error = $args{on_error};
   ref $on_error eq "CODE" or croak "Expected 'on_error' to be a CODE reference";

   my $code = $self->{code};
   $code->call(
      args      => [ $type, @{$args{data}} ],
      on_return => $on_resolved,
      on_error  => $on_error,
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

The C<IO::Async::DetachedCode> object underlying this class uses the
C<storable> argument marshalling type, which means complex data structures
can be passed by reference. Because the resolver will run in a separate
process, the function should make sure to return all of the result in the
returned list; i.e. modifications to call arguments will not be propagated
back to the caller.

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

register_resolver( 'getpwnam', sub { return getpwnam( $_[0] ) or die "$!\n" } );
register_resolver( 'getpwuid', sub { return getpwuid( $_[0] ) or die "$!\n" } );

register_resolver( 'getgrnam', sub { return getgrnam( $_[0] ) or die "$!\n" } );
register_resolver( 'getgrgid', sub { return getgrgid( $_[0] ) or die "$!\n" } );

register_resolver( 'getservbyname', sub { return getservbyname( $_[0], $_[1] ) or die "$!\n" } );
register_resolver( 'getservbyport', sub { return getservbyport( $_[0], $_[1] ) or die "$!\n" } );

register_resolver( 'gethostbyname', sub { return gethostbyname( $_[0] ) or die "$!\n" } );
register_resolver( 'gethostbyaddr', sub { return gethostbyaddr( $_[0], $_[1] ) or die "$!\n" } );

register_resolver( 'getnetbyname', sub { return getnetbyname( $_[0] ) or die "$!\n" } );
register_resolver( 'getnetbyaddr', sub { return getnetbyaddr( $_[0], $_[1] ) or die "$!\n" } );

register_resolver( 'getprotobyname',   sub { return getprotobyname( $_[0] ) or die "$!\n" } );
register_resolver( 'getprotobynumber', sub { return getprotobynumber( $_[0] ) or die "$!\n" } );

# The two Socket::GetAddrInfo-based ones

=pod

The following two resolver names are implemented using the same-named
functions from the C<Socket::GetAddrInfo> module.

 getaddrinfo getnameinfo

The C<getaddrinfo> resolver mangles the result of the function, so that the
returned value is more useful to the caller. It splits up the list of 5-tuples
into a list of ARRAY refs, where each referenced array contains one of the
tuples of 5 values. The C<getnameinfo> resolver returns its result unchanged.

=cut

register_resolver( 'getaddrinfo', sub {
   my @args = @_;

   my @res = getaddrinfo( @args );

   # getaddrinfo() uses a 1-element list as an error value
   die "$res[0]\n" if @res == 1;

   # Convert the @res list into a list of ARRAY refs of 5 values each
   my @ret;
   while( @res >= 5 ) {
      push @ret, [ splice( @res, 0, 5 ) ];
   }

   return @ret;
} );

register_resolver( 'getnameinfo', sub { return getnameinfo( @_ ) } );

# Keep perl happy; keep Britain tidy
1;

__END__

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

 register_resolver( 'getnumberbyindex', sub {
    my ( $index ) = @_;
    die "Bad index $index" unless $index >= 0 and $index < @numbers;
    return ( $index, $numbers[$index] );
 } );

 register_resolver( 'getnumberbyname', sub {
    my ( $name ) = @_;
    foreach my $index ( 0 .. $#numbers ) {
       return ( $index, $name ) if $numbers[$index] eq $name;
    }
    die "Bad name $name";
 } );

=head1 TODO

=over 4

=item *

Look into (system-specific) ways of accessing asynchronous resolvers directly

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
