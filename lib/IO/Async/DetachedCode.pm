#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2008 -- leonerd@leonerd.org.uk

package IO::Async::DetachedCode;

use strict;
use warnings;

our $VERSION = '0.31';

use IO::Async::Stream;

use Carp;
use Scalar::Util qw( weaken );

use constant LENGTH_OF_I => length( pack( "I", 0 ) );

=head1 NAME

C<IO::Async::DetachedCode> - execute code asynchronously in child processes

=head1 SYNOPSIS

This object is used indirectly via an C<IO::Async::Loop>:

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $code = $loop->detach_code(
    code => sub {
       my ( $number ) = @_;
       return is_prime( $number );
    }
 );

 $code->call(
    args => [ 123454321 ],
    on_return => sub {
       my $isprime = shift;
       print "123454321 " . ( $isprime ? "is" : "is not" ) . " a prime number\n";
    },
    on_error => sub {
       print STDERR "Cannot determine if it's prime - $_[0]\n";
    },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This module provides a class that allows a block of code to "detach" from the
main process, and execute independently in its own child processes. The object
itself acts as a proxy to this code block, allowing arguments to be passed to
it each time it is called, and returning results back to a continuation in the
main process.

The object represents the code block itself, rather than one specific
invocation of it. It can be called multiple times, by the C<call()> method.
Multiple outstanding invocations can be called; they will be dispatched in
the order they were queued. If only one worker process is used then results
will be returned in the order they were called. If multiple are used, then
each request will be sent in the order called, but timing differences between
each worker may mean results are returned in a different order.

The default marshalling code can only cope with plain scalars or C<undef>
values; no references, objects, or IO handles may be passed to the function
each time it is called. If references are required then code based on
L<Storable> may be used instead to pass these. See the documentation on the
C<marshaller> parameter of C<new()> method. Beware that, because the code
executes in a child process, passing such items as IO handles will not work.

The C<IO::Async> framework generally provides mechanisms for multiplexing IO
tasks between different handles, so there aren't many occasions when such
detached code is necessary. Two cases where this does become useful are:

=over 4

=item 1.

When a large amount of computationally-intensive work needs to be performed
(for example, the C<is_prime()> test in the example in the C<SYNOPSIS>).

=item 2.

When a blocking OS syscall or library-level function needs to be called, and
no nonblocking or asynchronous version is supplied. This is used by
C<IO::Async::Resolver>.

=back

=cut

=head1 CONSTRUCTOR

=cut

=head2 $code = $loop->detach_code( %params )

This function returns a new instance of a C<IO::Async::DetachedCode> object.
The C<%params> hash takes the following keys:

=over 8

=item code => CODE

A block of code to call in the child process. It will be invoked in list
context each time the C<call()> method is is called, passing in the arguments
given. The result will be given to the C<on_result> or C<on_return>
continuation provided to the C<call()> method.

=item stream => STRING: C<socket> or C<pipe>

Optional string, specifies which sort of stream will be used to attach to each
worker. C<socket> uses only one file descriptor per worker in the parent
process, but not all systems may be able to use it. If the system does not
support C<socketpair()>, then C<pipe> can be used instead. This will use
two file descriptors per worker in the parent process, however.

If not supplied, the underlying Loop's C<pipequad()> method is used, which
will select an appropriate method. Usually this default will be sufficient.

=item marshaller => STRING: C<flat> or C<storable>

Optional string, specifies the way that call arguments and return values are
marshalled over the stream that connects the worker and parent processes. The
C<flat> marshaller is small, simple and fast, but can only cope with strings
or C<undef>; cannot cope with any references. The C<storable> marshaller uses
the L<Storable> module to marshall arbitrary reference structures.

If not supplied, the C<flat> method is used.

=item workers => INT

Optional integer, specifies the number of parallel workers to create.

If not supplied, 1 is used.

=item exit_on_die => BOOL

Optional boolean, controls what happens after the C<code> throws an
exception. If missing or false, the worker will continue running to process
more requests. If true, the worker will be shut down. A new worker might be
constructed by the C<call> method to replace it, if necessary.

=item setup => ARRAY

Optional array reference. Specifies the C<setup> key to pass to the underlying
C<detach_child> when detaching the code block. If not supplied, a default one
will be created which just closes C<STDIN> and C<STDOUT>; C<STDERR> will be
left unaffected.

=back

Since the code block will be called multiple times within the same child
process, it must take care not to modify any of its state that might affect
subsequent calls. Since it executes in a child process, it cannot make any
modifications to the state of the parent program. Therefore, all the data
required to perform its task must be represented in the call arguments, and
all of the result must be represented in the return values.

=cut

# This object class has to be careful not to leave any $self references in
# registered callback code. To acheive this, all callbacks are plain functions
# rather than methods, and all take a plain unblessed hashref for the state.
# Hashrefs of this state are stored in the 'inners' arrayref of the main $self
# object, one per worker process.
#
# This allows the DESTROY handler to work properly when the user code drops
# the last reference to this object.

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $loop = delete $params{loop} or croak "Expected a 'loop'";

   my $code = delete $params{code};
   ref $code or croak "Expected a reference as 'code'";

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

   my $streamtype = $params{stream};

   !defined $streamtype or $streamtype eq "socket" or $streamtype eq "pipe" or
      croak "Unrecognised stream type '$streamtype'";

   my $workers = $params{workers} || 1;

   # Squash this down to a boolean
   my $exit_on_die =  $params{exit_on_die} ? 1 : 0;

   # Provide a child setup list if one wasn't given
   my $setup = $params{setup};

   $setup ||= [
      stdin  => 'close',
      stdout => 'close',
      # stderr is kept by default
   ];

   my $self = bless {
      next_id     => 0,
      code        => $code,
      loop        => $loop,
      streamtype  => $streamtype,
      marshaller  => $marshaller,
      workers     => $workers,
      setup       => $setup,
      exit_on_die => $exit_on_die,

      inners => [],

      queue  => [],
   }, $class;

   $self->_detach_child foreach( 1 .. $workers );

   return $self;
}

sub _detach_child
{
   my $self = shift;

   my $loop = $self->{loop};

   # The inner object needs references to some members of the outer object
   my $inner = {
      loop           => $loop,
      result_handler => {},
      marshaller     => $self->{marshaller},
      busy           => 0,
      queue          => $self->{queue},
      inners         => $self->{inners},
      exit_on_die    => $self->{exit_on_die},
   };

   weaken( $inner->{loop} );

   # Not required to keep Loop's refcount happy; but does break a cycle here
   #weaken( $inner->{inners} );

   my ( $childread, $mywrite );
   my ( $myread, $childwrite );

   my $streamtype = $self->{streamtype};

   if( !defined $streamtype ) {
      ( $childread, $mywrite, $myread, $childwrite ) = $loop->pipequad() or
         croak "Cannot pipequad() - $!";
   }
   elsif( $streamtype eq "socket" ) {
      my ( $myend, $childend ) = $loop->socketpair() or
         croak "Cannot socketpair() - $!";

      $mywrite = $myread = $myend;
      $childwrite = $childread = $childend;
   }
   elsif( $streamtype eq "pipe" ) {
      ( $childread, $mywrite ) = $loop->pipepair() or croak "Cannot pipe() - $!";
      ( $myread, $childwrite ) = $loop->pipepair() or croak "Cannot pipe() - $!";
   }

   my $kid = $loop->spawn_child(
      code => sub { 
         $self->_child_loop( $childread, $childwrite, $inner ),
      },
      setup => [
         @{ $self->{setup} },
         $childread  => 'keep',
         $childwrite => 'keep',
      ],
      on_exit => sub { 
         my ( $pid, $exitcode, undef, undef ) = @_;
         _child_error( $inner, 'exit', $pid, $exitcode );
      },
   );

   $inner->{kid} = $kid;

   close( $childread );
   close( $childwrite );

   my $iostream = IO::Async::Stream->new(
      read_handle  => $myread,
      write_handle => $mywrite,

      on_read => sub { _socket_incoming( $inner, $_[1], $_[2] ) },
   );

   $inner->{iostream} = $iostream;

   # Not required to keep Loop's refcount happy; but does break a cycle here
   #weaken( $inner->{iostream} );

   $loop->add( $iostream );

   push @{ $self->{inners} }, $inner;

   return $inner;
}

sub DESTROY
{
   my $self = shift;

   $self->shutdown;
}

=head1 METHODS

=cut

=head2 $code->call( %params )

This method causes one invocation of the code block to be executed in a
free worker. If there are no free workers available at the time this method is
called, the request will be queued, to be sent to the first worker that later
becomes available. The request will already have been serialised by the
marshaller, so it will be safe to modify any referenced data structures in the
arguments after this call returns.

If the number of available workers is less than the number supplied to the
constructor (perhaps because some of them were shut down because of
C<exit_on_die>) and they are all busy, then a new one will be created to
perform this request.

The C<%params> hash takes the following keys:

=over 8

=item args => ARRAY

A reference to the array of arguments to pass to the code.

=item on_result => CODE

A continuation that is invoked when the code has been executed. If the code
returned normally, it is called as:

 $on_result->( 'return', @values )

If the code threw an exception, or some other error occured such as a closed
connection or the process died, it is called as:

 $on_result->( 'error', $exception_name )

=back

or

=over 8

=item on_return => CODE and on_error => CODE

Two continuations to use in either of the circumstances given above. They will
be called directly, without the leading 'return' or 'error' value.

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
      ref $on_result or croak "Expected 'on_result' to be a reference";
   }
   elsif( defined $params{on_return} and defined $params{on_error} ) {
      my $on_return = delete $params{on_return};
      ref $on_return or croak "Expected 'on_return' to be a reference";
      my $on_error  = delete $params{on_error};
      ref $on_error or croak "Expected 'on_error' to be a reference";

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
   my $request = _marshall_record( 'c', $callid, $data );

   my $inner;
   foreach( @{ $self->{inners} } ) {
      $inner = $_, last if !$_->{busy};
   }

   if( !$inner and @{ $self->{inners} } < $self->{workers} ) {
      $inner = $self->_detach_child;
   }

   if( $inner ) {
      _send_request( $inner, $callid, $request, $on_result );
   }
   else {
      push @{ $self->{queue} }, [ $callid, $request, $on_result ];
   }
}

=head2 $code->shutdown

This method requests that the detached worker processes stop running. All
pending calls to the code are finished with a 'shutdown' error, and the worker
processes exit.

=cut

sub shutdown
{
   my $self = shift;

   foreach my $inner ( @{ $self->{inners} } ) {
      # This is called from DESTROY, so all sorts of craziness might have
      # happened. We need to be extra-paranoid.
      if( defined $inner->{iostream} and defined $inner->{loop} ) {
         $inner->{loop}->remove( $inner->{iostream} );
         undef $inner->{iostream};
      }

      my $handlermap = $inner->{result_handler};

      foreach my $id ( keys %$handlermap ) {
         $handlermap->{$id}->( 'shutdown' );
         delete $handlermap->{$id};
      }
   }

   @{ $self->{inners} } = ();
}

=head2 $n_workers = $code->workers

This method in scalar context returns the number of workers currently running.

=head2 @worker_pids = $code->workers

This method in list context returns a list of the PID numbers of all the
currently running worker processes.

=cut

sub workers
{
   my $self = shift;

   return scalar @{ $self->{inners} } unless wantarray;
   return map { $_->{kid} } @{ $self->{inners} };
}

# INNER FUNCTION
sub _send_request
{
   my ( $inner, $callid, $request, $on_result ) = @_;

   my $handlermap = $inner->{result_handler};
   $handlermap->{$callid} = $on_result;

   $inner->{iostream}->write( pack( "I", length $request ) . $request );
   $inner->{busy} = 1;
}

# INNER FUNCTION
sub _socket_incoming
{
   my ( $inner, $buffref, $closed ) = @_;

   my $handlermap = $inner->{result_handler};

   if( $closed ) {
      _child_error( $inner, 'closed' );

      $inner->{loop}->remove( $inner->{iostream} );
      undef $inner->{iostream};

      return 0;
   }

   return 0 unless length( $$buffref ) >= LENGTH_OF_I;

   my $reclen = unpack( "I", $$buffref );
   return 0 unless length( $$buffref ) >= $reclen + LENGTH_OF_I;

   substr( $$buffref, 0, LENGTH_OF_I, "" );
   my $record = substr( $$buffref, 0, $reclen, "" );

   my ( $type, $id, $data ) = _unmarshall_record( $record );

   if( !exists $handlermap->{$id} ) {
      # Child returned a result for an ID we don't recognise
      carp "Unrecognised return ID $id from detached code child";
      return 1;
   }

   my $handler = delete $handlermap->{$id};
   $inner->{busy} = 0;

   if( $type eq "r" ) {
      my $ret = $inner->{marshaller}->unmarshall_ret( $id, $data );
      $handler->( "return", @$ret );
   }
   elsif( $type eq "e" ) {
      $handler->( "error", $data );

      if( $inner->{exit_on_die} ) {
         _child_error( $inner, 'die' );

         $inner->{loop}->remove( $inner->{iostream} );
         undef $inner->{iostream};
      }
   }

   if( @{ $inner->{queue} } ) {
      my ( $callid, $request, $on_result ) = @{ shift @{ $inner->{queue} } };
      _send_request( $inner, $callid, $request, $on_result );
   }

   return 1;
}

# INNER FUNCTION
sub _child_error
{
   my ( $inner, $cause, @args ) = @_;

   my $handlermap = $inner->{result_handler};

   foreach my $id ( keys %$handlermap ) {
      $handlermap->{$id}->( 'error', $cause, @args );
      delete $handlermap->{$id};
   }

   # Remove myself from the parent's inners list
   @{ $inner->{inners} } = grep { $_ != $inner } @{ $inner->{inners} };

   return 0;
}

# These are FUNCTIONS, not methods
# They don't need $self

sub _marshall_record
{
   my ( $type, $id, $data ) = @_;

   return pack( "a1 I a*", $type, $id, $data );
}

sub _unmarshall_record
{
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
   my ( $inhandle, $outhandle, $inner ) = @_;

   my $code = $self->{code};

   while( 1 ) {
      my $n = _read_exactly( $inhandle, my $lenbuffer, 4 );
      defined $n or die "Cannot read - $!";

      my $reclen = unpack( "I", $lenbuffer );

      $n = _read_exactly( $inhandle, my $record, $reclen );
      defined $n or die "Cannot read - $!";

      my ( $type, $id, $data ) = _unmarshall_record( $record );
      $type eq "c" or die "Unexpected record type $type\n";

      my $args = $inner->{marshaller}->unmarshall_args( $id, $data );

      my @ret;
      my $ok = eval { @ret = $code->( @$args ); 1 };

      my $result;
      if( $ok ) {
         my $data = $inner->{marshaller}->marshall_ret( $id, \@ret );
         $result = _marshall_record( 'r', $id, $data );
      }
      else {
         my $e = "$@"; # Force stringification
         $result = _marshall_record( 'e', $id, $e );
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

Dynamic pooling of multiple worker processes, with min/max watermarks.

=back

=head1 NOTES

For the record, 123454321 is 11111 * 11111, a square number, and therefore not
prime.

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
