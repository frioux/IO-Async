#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::DetachedCode;

use strict;

our $VERSION = '0.09';

use IO::Async::Buffer;

use Carp;

use Socket;

use constant LENGTH_OF_I => length( pack( "I", 0 ) );

=head1 NAME

C<IO::Async::DetachedCode> - a class that allows a block of code to execute
asynchronously in a detached child process

=head1 SYNOPSIS

Usually this object would be constructed indirectly, via an C<IO::Async::Set>:

 use IO::Async::Set::...;
 my $set = IO::Async::Set::...

 $set->enable_childmanager;

 my $code = $set->detach_code(
    code => sub {
       my ( $number ) = @_;
       return is_prime( $number );
    }
 );

 $code->call
    args => [ 123454321 ],
    on_return => sub {
       my $isprime = shift;
       print "123454321 " . ( $isprime ? "is" : "is not" ) . " a prime number\n";
    },
    on_error => sub {
       print STDERR "Cannot determine if it's prime - $_[0]\n";
    },
 );

 $set->loop_forever;

It can also be used directly. In this case, extra effort must be taken to pass
an C<IO::Async::Set> object:

 my $set = IO::Async::Set::...

 my $code = IO::Async::DetachedCode->new(
    set => $set,
    code => sub { ... },
 );

=head1 DESCRIPTION

This module provides a class that allows a block of code to "detach" from the
main process, and execute independently in its own child process. The object
itself acts as a proxy to this code block, allowing arguments to be passed to
it each time it is called, and returning results back to a callback function
in the main process.

The object represents the code block itself, rather than one specific
invocation of it. It can be called multiple times, by the C<call()> method.
Multiple outstanding invocations can be queued up; they will be executed in
the order they were queued, and results returned in that order.

The default marshalling code can only cope with plain scalars or C<undef>
values; no references, objects, or IO handles may be passed to the function
each time it is called. If references are required, code based on L<Storable>
may be used instead, to pass these. See the documentation on the C<marshaller>
parameter of C<new()> method.

The C<IO::Async> framework generally provides mechanisms for multiplexing IO
tasks between different handles, so there aren't many occasions when such
detached code is necessary. Two cases where this does become useful are:

=over 4

=item 1.

When a large amount of computationally-intensive work needs to be performed
(for example, the C<is_prime()> test in the example in the C<SYNOPSIS>).

=item 2.

When an OS or library-level function needs to be called, that will block, and
no asynchronous version is supplied.

=back

=cut

=head1 CONSTRUCTOR

=cut

=head2 $code = IO::Async::DetachedCode->new( %params )

This function returns a new instance of a C<IO::Async::DetachedCode> object.
The C<%params> hash takes the following keys:

=over 8

=item set => IO::Async::Set

A reference to an C<IO::Async::Set> object. The set must have the child
manager enabled.

=item code => CODE

A block of code to call in the child process. It will be invoked in list
context each time the C<call()> method is is called, passing in the arguments
given. The result will be given to the C<on_result> or C<on_return> callback
provided to the C<call()> method.

=item stream => STRING: C<socket> or C<pipe>

Optional string, specifies which sort of stream will be used to attach to the
child process. C<socket> uses only one file descriptor in the parent process,
but not all systems may be able to use it. If the system does not allow
C<PF_UNIX> socket pairs, then C<pipe> can be used instead. This will use two
file descriptors in the parent process, however.

If not supplied, the C<socket> method is used.

=item marshaller => STRING: C<flat> or C<storable>

Optional string, specifies the way that call arguments and return values are
marshalled over the stream that connects the child and parent processes.
The C<flat> method is small, simple and fast, but can only cope with strings
or C<undef>; cannot cope with any references. The C<storable> method uses the
L<Storable> module to marshall arbitrary reference structures.

If not supplied, the C<flat> method is used.

=back

Since the code block will be called multiple times within the same child
process, it must take care not to modify any global state that might affect
subsequent calls. Since it executes in a child process, it cannot make any
modifications to the state of the parent program. Therefore, all the data
required to perform its task must be represented in the call arguments, and
all of the result must be represented in the return values.

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $set = delete $params{set} or croak "Expected a 'set'";

   my $code = delete $params{code};
   ref $code eq "CODE" or croak "Expected a CODE reference as 'code'";

   my $marshaller;

   if( !defined $params{marshaller} or $params{marshaller} eq "flat" ) {
      require IO::Async::DetachedCode::FlatMarshaller;
      $marshaller = IO::Async::DetachedCode::FlatMarshaller->new();
   }
   elsif( $params{marshaller} eq "storable" ) {
      require IO::Async::DetachedCode::StorableMarshaller;
      $marshaller = IO::Async::DetachedCode::StorableMarshaller->new();
   }
   else {
      croak "Unrecognised marshaller type '$params{marshaller}'";
   }

   my $self = bless {
      next_id => 0,
      set     => $set,
      code    => $code,

      result_handler => {},
      marshaller     => $marshaller,
   }, $class;

   my ( $childread, $mywrite );
   my ( $myread, $childwrite );

   my $streamtype = $params{stream};

   if( !defined $streamtype or $streamtype eq "socket" ) {
      socketpair( my $myend, my $childend, PF_UNIX, SOCK_STREAM, 0 ) or
         croak "Cannot socketpair(PF_UNIX) - $!";

      $mywrite = $myread = $myend;
      $childwrite = $childread = $childend;
   }
   elsif( $streamtype eq "pipe" ) {
      pipe( $childread, $mywrite ) or croak "Cannot pipe() - $!";
      pipe( $myread, $childwrite ) or croak "Cannot pipe() - $!";
   }
   else {
      croak "Unrecognised stream type '$streamtype'";
   }

   my $kid = $set->detach_child(
      code => sub { 
         foreach( 0 .. IO::Async::ChildManager::OPEN_MAX_FD() ) {
            next if $_ == 2;
            next if $_ == fileno $childread;
            next if $_ == fileno $childwrite;

            POSIX::close( $_ );
         }

         $self->_child_loop( $childread, $childwrite ),
      },
      on_exit => sub { $self->_child_error( 'exit', @_ ) },
   );

   $self->{kid} = $kid;

   close( $childread );
   close( $childwrite );

   my $iobuffer = IO::Async::Buffer->new(
      read_handle  => $myread,
      write_handle => $mywrite,

      on_incoming_data => sub { $self->_socket_incoming( $_[1], $_[2] ) },
   );

   $self->{iobuffer} = $iobuffer;

   $set->add( $iobuffer );

   return $self;
}

sub DESTROY
{
   my $self = shift;

   $self->shutdown;
}

=head1 METHODS

=cut

=head2 $code->call( %params )

This method queues one invocation of the code block to be executed in the
child process. The C<%params> hash takes the following keys:

=over 8

=item args => ARRAY

A reference to the array of arguments to pass to the code.

=item on_result => CODE

A callback that is invoked when the code has been executed. If the code
returned normally, it is called as:

 $on_result->( 'return', @values )

If the code threw an exception, or some other error occured such as a closed
connection or the process died, it is called as:

 $on_result->( 'error', $exception_name )

=back

or

=over 8

=item on_return => CODE and on_error => CODE

Two callbacks to use in either of the circumstances given above. They will be
called directly, without the leading 'return' or 'error' value.

=back

The C<args> key must always be supplied. Either the C<on_result> or both the
C<on_return> and C<on_error> keys must also be supplied.

=cut

sub call
{
   my $self = shift;
   my ( %params ) = @_;

   my $args = delete $params{args};
   ref $args eq "ARRAY" or croak "Expected 'args' to be an array";

   my $on_result;
   if( defined $params{on_result} ) {
      $on_result = delete $params{on_result};
      ref $on_result eq "CODE" or croak "Expected 'on_result' to be a CODE reference";
   }
   elsif( defined $params{on_return} and defined $params{on_error} ) {
      my $on_return = delete $params{on_return};
      ref $on_return eq "CODE" or croak "Expected 'on_return' to be a CODE reference";
      my $on_error  = delete $params{on_error};
      ref $on_error eq "CODE" or croak "Expected 'on_error' to be a CODE reference";

      $on_result = sub {
         my $result = shift;
         $on_return->( @_ ) if $result eq "return";
         $on_error->( @_)   if $result eq "error";
      };
   }
   else {
      croak "Expected either 'on_result' or 'on_return' and 'on_error' keys";
   }

   my $callid = $self->{next_id}++;

   my $data = $self->{marshaller}->marshall_args( $callid, $args );
   my $request = $self->_marshall_record( 'c', $callid, $data );

   $self->{iobuffer}->send( pack( "I", length $request ) . $request );

   my $handlermap = $self->{result_handler};
   $handlermap->{$callid} = $on_result;
}

=head2 $code->shutdown

This method requests that the detached child process stops running. All
pending calls to the code are finished with a 'shutdown' error, and the child
process itself exits.

It is not normally necessary to call this method during normal exit of the
containing program. It is only required if the detact code is to be dropped,
and recreated in a different way.

=cut

sub shutdown
{
   my $self = shift;

   $self->{shutting_down} = 1;

   if( defined $self->{iobuffer} ) {
      $self->{set}->remove( $self->{iobuffer} );
      undef $self->{iobuffer};
   }

   my $handlermap = $self->{result_handler};

   foreach my $id ( keys %$handlermap ) {
      $handlermap->{$id}->( 'shutdown' );
      delete $handlermap->{$id};
   }
}

# Internal
sub _socket_incoming
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   if( $closed ) {
      $self->_child_error( 'closed' );
      return 0;
   }

   return 0 unless length( $$buffref ) >= LENGTH_OF_I;

   my $reclen = unpack( "I", $$buffref );
   return 0 unless length( $$buffref ) >= $reclen + LENGTH_OF_I;

   substr( $$buffref, 0, LENGTH_OF_I, "" );
   my $record = substr( $$buffref, 0, $reclen, "" );

   my ( $type, $id, $data ) = $self->_unmarshall_record( $record );

   my $handlermap = $self->{result_handler};
   if( !exists $handlermap->{$id} ) {
      $self->_child_error( 'badretid', $id );
      return 1;
   }
   my $handler = $handlermap->{$id};

   if( $type eq "r" ) {
      my $ret = $self->{marshaller}->unmarshall_ret( $id, $data );
      $handler->( "return", @$ret );
   }
   elsif( $type eq "e" ) {
      $handler->( "error", $data );
   }

   delete $handlermap->{$id};
   return 1;
}

sub _child_error
{
   my $self = shift;
   my ( $cause, @args ) = @_;

   return if $self->{shutting_down};

   my $handlermap = $self->{result_handler};

   foreach my $id ( keys %$handlermap ) {
      $handlermap->{$id}->( 'error', $cause, @args );
      delete $handlermap->{$id};
   }

   $self->shutdown;

   return 0;
}

sub _marshall_record
{
   my $self = shift;
   my ( $type, $id, $data ) = @_;

   return pack( "a1 I a*", $type, $id, $data );
}

sub _unmarshall_record
{
   my $self = shift;
   my ( $record ) = @_;

   return unpack( "a1 I a*", $record );
}

##### Child process loop

sub _read_exactly
{
   $_[1] = "";

   while( length $_[1] < $_[2] ) {
      my $n = read( $_[0], $_[1], $_[2]-length $_[1], length $_[1] );
      defined $n or return undef;
      $n or die "EXIT";
   }
}

sub _child_loop
{
   my $self = shift;
   my ( $inhandle, $outhandle ) = @_;

   my $code = $self->{code};

   while( 1 ) {
      my $n = _read_exactly( $inhandle, my $lenbuffer, 4 );
      defined $n or die "Cannot read - $!";

      my $reclen = unpack( "I", $lenbuffer );

      $n = _read_exactly( $inhandle, my $record, $reclen );
      defined $n or die "Cannot read - $!";

      my ( $type, $id, $data ) = $self->_unmarshall_record( $record );
      $type eq "c" or die "Unexpected record type $type\n";

      my $args = $self->{marshaller}->unmarshall_args( $id, $data );

      my @ret;
      my $ok = eval { @ret = $code->( @$args ); 1 };

      my $result;
      if( $ok ) {
         my $data = $self->{marshaller}->marshall_ret( $id, \@ret );
         $result = $self->_marshall_record( 'r', $id, $data );
      }
      else {
         my $e = "$@"; # Force stringification
         $result = $self->_marshall_record( 'e', $id, $e );
      }

      # Prepend record length
      $result = pack( "I", length( $result ) ) . $result;

      while( length $result ) {
         $n = $outhandle->syswrite( $result );
         defined $n or die "Cannot syswrite - $!";
         $n or die "EXIT";
         substr( $result, 0, $n, "" );
      }
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 TODO

=over 4

=item *

Allow other argument/return value marshalling code - perhaps an arbitrary
object.

=item *

Pooling of multiple child processes - perhaps even dynamic. Default one
process, allow dynamic creation of more if it's busy.

=item *

Fall back on a pipe pair if socketpair doesn't work.

=back

=head1 BUGS

=over 4

=item *

The child process is not shut down, and the connecting socket or pipes not
closed when the application using the DetachedCode drops its last reference.
This is due to an internal reference being kept. A workaround for this is to
make sure always to call the C<shutdown()> method. A proper fix will be
included in a later version.

=back

=head1 NOTES

For the record, 123454321 is 11111 * 11111, a square number, and therefore not
prime.

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
