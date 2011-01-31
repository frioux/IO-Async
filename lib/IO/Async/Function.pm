#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011 -- leonerd@leonerd.org.uk

package IO::Async::Function;

use strict;
use warnings;

our $VERSION = '0.37';

use base qw( IO::Async::Notifier );

use Carp;

use Storable qw( freeze thaw );

use IO::Async::Process;

=head1 NAME

C<IO::Async::Function> - call a function asynchronously

=head1 SYNOPSIS

 use IO::Async::Function;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $function = IO::Async::Function->new(
    code => sub {
       my ( $number ) = @_;
       return is_prime( $number );
    },
 );

 $loop->add( $function );

 $function->call(
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

This subclass of L<IO::Async::Notifier> wraps a function body in a collection
of worker processes, to allow it to execute independently of the main process.
The object acts as a proxy to the function, allowing invocations to be made by
passing in arguments, and invoking a continuation in the main process when the
function returns.

Because the function executes in a child process, the arguments and return
values are passed to it over a file handle, using L<Storable>. This can cope
with most kinds of Perl data, including plain numbers and strings, references
to hashes or arrays, and self-referential or even cyclic data structures. Note
however that passing C<CODE> references or IO handles is not supported.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item code => CODE

The body of the function to execute.

=item min_workers => INT

=item max_workers => INT

The lower and upper bounds of worker processes to try to keep running. The
actual number running at any time will be kept somewhere between these bounds
according to load.

=item exit_on_die => BOOL

Optional boolean, controls what happens after the C<code> throws an
exception. If missing or false, the worker will continue running to process
more requests. If true, the worker will be shut down. A new worker might be
constructed by the C<call> method to replace it, if necessary.

=item setup => ARRAY

Optional array reference. Specifies the C<setup> key to pass to the underlying
L<IO::Async::Process> when setting up new worker processes.

=back

=cut

sub _init
{
   my $self = shift;
   $self->SUPER::_init( @_ );

   $self->{min_workers} = 1;
   $self->{max_workers} = 8;

   $self->{workers} = {};

   $self->{pending_queue} = [];
}

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( exit_on_die )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   foreach (qw( min_workers max_workers )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
      # TODO: something about retuning
   }

   my $need_restart;

   foreach (qw( code setup )) {
      $need_restart++, $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->SUPER::configure( %params );

   if( $need_restart and $self->get_loop ) {
      $self->stop;
      $self->start;
   }
}

sub _add_to_loop
{
   my $self = shift;
   $self->SUPER::_add_to_loop( @_ );

   $self->start;
}

sub _remove_from_loop
{
   my $self = shift;

   $self->stop;

   $self->SUPER::_remove_from_loop( @_ );
}

=head1 METHODS

=cut

=head2 $function->start

Start the worker processes

=cut

sub start
{
   my $self = shift;

   $self->_new_worker for 1 .. $self->{min_workers};
}

=head2 $function->stop

Stop the worker processes

=cut

sub stop
{
   my $self = shift;

   foreach my $worker ( values %{ $self->{workers} } ) {
      $self->_stop_worker( $worker );
   }
}

=head2 $function->call( %params )

Schedules an invocation of the contained function to be executed on one of the
worker processes. If a non-busy worker is available now, it will be called
immediately. If not, it will be queued and sent to the next free worker that
becomes available.

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

=item on_return => CODE and on_error => CODE

An alternative to C<on_result>. Two continuations to use in either of the
circumstances given above. They will be called directly, without the leading
'return' or 'error' value.

=back

=cut

sub call
{
   my $self = shift;
   my %params = @_;

   # TODO: possibly just queue this?
   $self->get_loop or croak "Cannot ->call on a Function not yet in a Loop";

   my $args = delete $params{args};
   ref $args eq "ARRAY" or croak "Expected 'args' to be an array";

   my $request = freeze( $args );

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
         $on_error->( @_ )  if $result eq "error";
      };
   }
   else {
      croak "Expected either 'on_result' or 'on_return' and 'on_error' keys";
   }

   my $worker = $self->_get_worker;

   if( !$worker ) {
      push @{ $self->{pending_queue} }, [ $request, $on_result ];
      return;
   }

   $self->_call_worker( $worker, $request, $on_result );
}

=head2 $count = $function->workers

Returns the total number of worker processes available

=cut

sub workers
{
   my $self = shift;
   return scalar keys %{ $self->{workers} };
}

=head2 $count = $function->workers_busy

Returns the number of worker processes that are currently busy

=cut

sub workers_busy
{
   my $self = shift;
   return scalar grep { $_->{busy} } values %{ $self->{workers} };
}

###
# Worker Management
###

sub _read_exactly
{
   $_[1] = "";

   while( length $_[1] < $_[2] ) {
      my $n = read( $_[0], $_[1], $_[2]-length $_[1], length $_[1] );
      defined $n or return undef;
      $n or die "EXIT";
   }
}

sub _new_worker
{
   my $self = shift;

   my @on_result_queue;

   my $worker = {
      on_result_queue => \@on_result_queue,
   };

   my $code = $self->{code};

   my $proc = $worker->{process} = IO::Async::Process->new(
      code => sub {
         while(1) {
            my $n = _read_exactly( \*STDIN, my $lenbuffer, 4 );
            defined $n or die "Cannot read - $!";

            my $len = unpack( "I", $lenbuffer );

            $n = _read_exactly( \*STDIN, my $record, $len );
            defined $n or die "Cannot read - $!";

            my $args = thaw( $record );

            my @ret;
            my $ok = eval { @ret = $code->( @$args ); 1 };

            if( $ok ) {
               unshift @ret, "r";
            }
            else {
               @ret = ( "e", "$@" );
            }

            my $result = freeze( \@ret );
            print STDOUT pack("I", length $result) . $result;
         }
      },
      setup => $self->{setup},
      stdin  => { via => "pipe_write" },
      stdout => {
         on_read => $self->_capture_weakself( sub {
            my $self = shift;
            my ( $stream, $buffref, $eof ) = @_;

            if( $eof ) {
               my $on_result = shift @on_result_queue;
               $on_result->( "eof" ) if $on_result;
               return;
            }

            return 0 unless length( $$buffref ) >= 4;
            my $len = unpack( "I", $$buffref );
            return 0 unless length( $$buffref ) >= 4 + $len;

            my $record = thaw( substr( $$buffref, 4, $len ) );
            substr( $$buffref, 0, 4 + $len ) = "";

            (shift @on_result_queue)->( @$record );

            return 1;
         } ),
      },
      on_finish => $self->_capture_weakself( sub {
         my $self = shift;
         my ( $proc ) = @_;

         if( @on_result_queue ) {
            print STDERR "TODO: on_result_queue to be flushed\n";
         }

         delete $self->{workers}{$proc->pid};

         $self->_new_worker if $self->workers < $self->{min_workers};

         $self->_dispatch_pending;
      } ),
   );

   $self->add_child( $proc );

   return $self->{workers}{$proc->pid} = $worker;
}

sub _get_worker
{
   my $self = shift;

   foreach ( sort keys %{ $self->{workers} } ) {
      return $self->{workers}{$_} if !$self->{workers}{$_}{busy};
   }

   if( $self->workers < $self->{max_workers} ) {
      return $self->_new_worker;
   }

   return undef;
}

sub _stop_worker
{
   my $self = shift;
   my ( $worker ) = @_;

   my $process = $worker->{process};

   $process->stdin->close;

   delete $self->{workers}{$process->pid};
}

sub _call_worker
{
   my $self = shift;
   my ( $worker, $request, $on_result ) = @_;

   push @{ $worker->{on_result_queue} }, $self->_capture_weakself( sub {
      my $self = shift;
      my $type = shift;

      $worker->{busy} = 0;

      if( $type eq "eof" ) {
         $on_result->( error => "closed" );
         $self->_stop_worker( $worker ), return;
      }
      elsif( $type eq "r" ) {
         $on_result->( return => @_ );
      }
      elsif( $type eq "e" ) {
         $on_result->( error => @_ );
         $self->_stop_worker( $worker ), return if $self->{exit_on_die};
      }
      else {
         die "Unrecognised type from worker - $type\n";
      }

      $self->_dispatch_pending;
   } );

   $worker->{process}->stdin->write( pack("I", length $request) . $request );
   $worker->{busy} = 1;
}

sub _dispatch_pending
{
   my $self = shift;

   my $worker = $self->_get_worker or return;
   my $next = shift @{ $self->{pending_queue} } or return;

   $self->_call_worker( $worker, @$next );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
