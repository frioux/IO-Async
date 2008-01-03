#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Resolver;

use strict;

our $VERSION = '0.10';

use Carp;

my $started = 0;
my %METHODS;

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

# Plain function, not a method
sub register_resolver
{
   my ( $name, $code ) = @_;

   croak "Cannot register new resolver methods once the resolver has been started" if $started;

   croak "Already have a resolver method called '$name'" if exists $METHODS{$name};
   $METHODS{$name} = $code;
}

# Now register the inbuilt methods

register_resolver( 'getpwnam', sub { return getpwnam( $_[0] ) or die "$!" } );
register_resolver( 'getpwuid', sub { return getpwuid( $_[0] ) or die "$!" } );

register_resolver( 'getgrnam', sub { return getgrnam( $_[0] ) or die "$!" } );
register_resolver( 'getgrgid', sub { return getgrgid( $_[0] ) or die "$!" } );

register_resolver( 'getservbyname', sub { return getservbyname( $_[0], $_[1] ) or die "$!" } );
register_resolver( 'getservbyport', sub { return getservbyport( $_[0], $_[1] ) or die "$!" } );

register_resolver( 'gethostbyname', sub { return gethostbyname( $_[0] ) or die "$!" } );
register_resolver( 'gethostbyaddr', sub { return gethostbyaddr( $_[0], $_[1] ) or die "$!" } );

register_resolver( 'getnetbyname', sub { return getnetbyname( $_[0] ) or die "$!" } );
register_resolver( 'getnetbyaddr', sub { return getnetbyaddr( $_[0], $_[1] ) or die "$!" } );

register_resolver( 'getprotobyname',   sub { return getprotobyname( $_[0] ) or die "$!" } );
register_resolver( 'getprotobynumber', sub { return getprotobynumber( $_[0] ) or die "$!" } );

# Keep perl happy; keep Britain tidy
1;

__END__
