#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011 -- leonerd@leonerd.org.uk

package IO::Async::Process;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.36';

use Carp;

use POSIX qw(
   WIFEXITED WEXITSTATUS
);

use IO::Async::MergePoint;

=head1 NAME

C<IO::Async::Process> - start and manage a child process

=head1 SYNOPSIS

 use IO::Async::Process;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $process = IO::Async::Process->new(
    command => [ "tr", "a-z", "n-za-m" ],
    stdin => {
       from => "hello world\n",
    },
    stdout => {
       on_read => sub {
          my ( $stream, $buffref ) = @_;
          $$buffref =~ s/^(.*)\n// or return 0;

          print "Rot13 of 'hello world' is '$1'\n";
       },
    },
    
    on_finish => sub {
       $loop->loop_stop;
    },
 );

 $loop->add( $process );

 $loop->loop_forever;

=head1 DESCRIPTION

This subclass of L<IO::Async::Notifier> starts a child process, and invokes a
callback when it exits. The child process can either execute a given block of
code (via C<fork()>), or a command.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters:

=head2 on_finish $exitcode

Invoked when the process exits by normal means.

=head2 on_exception $exception, $errno, $exitcode

Invoked when the process exits by an exception from C<code>, or by failing to
C<exec()> the given command. C<$errno> will be a dualvar, containing both
number and string values.

Note that this has a different name and a different argument order from
C<< Loop->open_child >>'s C<on_error>.

If this is not provided and the process exits with an exception, then
C<on_finish> is invoked instead, being passed just the exit code.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $process = IO::Async::Process->new( %args )

Constructs a new C<IO::Async::Process> object and returns it.

Once constructed, the C<Process> will need to be added to the C<Loop> before
the child process is started.

=cut

sub _init
{
   my $self = shift;
   $self->SUPER::_init( @_ );

   $self->{to_close}   = {};
   $self->{mergepoint} = IO::Async::MergePoint->new;
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_finish => CODE

=item on_exception => CODE

CODE reference for the event handlers.

=back

Once the C<on_finish> continuation has been invoked, the C<IO::Async::Process>
object is removed from the containing C<IO::Async::Loop> object.

The following parameters may be passed to C<new>, or to C<configure> before
the process has been started (i.e. before it has been added to the C<Loop>).
Once the process is running these cannot be changed.

=over 8

=item command => ARRAY or STRING

Either a reference to an array containing the command and its arguments, or a
plain string containing the command. This value is passed into perl's
C<exec()> function.

=item code => CODE

A block of code to execute in the child process. It will be called in scalar
context inside an C<eval> block.

=item setup => ARRAY

Optional reference to an array to pass to the underlying C<Loop>
C<spawn_child> method.

=item fdI<n> => HASH

A hash describing how to set up file descriptor I<n>. The hash may contain one
of the following sets of keys:

=over 4

=item on_read => CODE

The child will be given the writing end of a pipe. The reading end will be
wrapped by an C<IO::Async::Stream> using this C<on_read> callback function.

=item from => STRING

The child will be given the reading end of a pipe. The string given by the
C<from> parameter will be written to the child. When all of the data has been
written the pipe will be closed.

=back

=item stdin => ...

=item stdout => ...

=item stderr => ...

Shortcuts for C<fd0>, C<fd1> and C<fd2> respectively.

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( on_finish on_exception )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   # All these parameters can only be configured while the process isn't
   # running
   my %setup_params;
   foreach (qw( code command setup stdin stdout stderr ), grep { m/^fd\d+$/ } keys %params ) {
      $setup_params{$_} = delete $params{$_} if exists $params{$_};
   }

   if( $self->is_running ) {
      keys %setup_params and croak "Cannot configure a running Process with " . join ", ", keys %setup_params;
   }

   defined( exists $setup_params{code} ? $setup_params{code} : $self->{code} ) +
      defined( exists $setup_params{command} ? $setup_params{command} : $self->{command} ) <= 1 or
      croak "Cannot have both 'code' and 'command'";

   foreach (qw( code command setup )) {
      $self->{$_} = delete $setup_params{$_} if exists $setup_params{$_};
   }

   $self->configure_fd( 0, %{ delete $setup_params{stdin}  } ) if $setup_params{stdin};
   $self->configure_fd( 1, %{ delete $setup_params{stdout} } ) if $setup_params{stdout};
   $self->configure_fd( 2, %{ delete $setup_params{stderr} } ) if $setup_params{stderr};

   # All the rest are fd\d+
   foreach ( keys %setup_params ) {
      my ( $fd ) = m/^fd(\d+)$/ or croak "Expected 'fd\\d+'";
      $self->configure_fd( $fd, %{ $setup_params{$_} } );
   }

   $self->SUPER::configure( %params );
}

# These are from the perspective of the parent
use constant {
   FD_WANTS_READ  => 0x1,
   FD_WANTS_WRITE => 0x2,
};

sub configure_fd
{
   my $self = shift;
   my ( $fd, %args ) = @_;

   $self->is_running and croak "Cannot configure fd $fd in a running Process";

   require IO::Async::Stream;

   my $handle = $self->{fd_handle}{$fd} ||= IO::Async::Stream->new;
   my $wants  = $self->{fd_wants}{$fd}  || 0;

   if( my $on_read = delete $args{on_read} ) {
      $handle->configure( on_read => $on_read );

      $wants |= FD_WANTS_READ;
   }

   if( my $from = delete $args{from} ) {
      $handle->write( $from );
      $handle->configure( on_outgoing_empty => sub {
         my ( $handle ) = @_;
         $handle->close;
      } );

      $wants |= FD_WANTS_WRITE;
   }

   keys %args and croak "Unexpected extra keys for fd $fd - " . join ", ", keys %args;

   $self->{fd_wants}{$fd} = $wants;
}

sub _prepare_fds
{
   my $self = shift;
   my ( $loop ) = @_;

   my $fd_handle = $self->{fd_handle};
   my $fd_wants  = $self->{fd_wants};

   my $mergepoint = $self->{mergepoint};

   my @setup;

   foreach my $fd ( keys %$fd_wants ) {
      my $handle = $fd_handle->{$fd};
      my $wants  = $fd_wants->{$fd};

      my ( $myfd, $childfd );

      if( $wants == FD_WANTS_READ ) {
         ( $myfd, $childfd ) = $loop->pipepair() or croak "Unable to pipe() - $!";
         $handle->configure( read_handle => $myfd );
      }
      elsif( $wants == FD_WANTS_WRITE ) {
         ( $childfd, $myfd ) = $loop->pipepair() or croak "Unable to pipe() - $!";
         $handle->configure( write_handle => $myfd );
      }
      else {
         croak "Unsure what to do with fd_wants==$wants";
      }

      my $key = "fd$fd";

      push @setup, $key => [ dup => $childfd ];
      $self->{to_close}{$childfd->fileno} = $childfd;

      $mergepoint->needs( $key );

      $handle->configure(
         on_closed => sub {
            $mergepoint->done( $key );
         },
      );

      $self->add_child( $handle );
   }

   return @setup;
}

sub _add_to_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $self->{code} or $self->{command} or
      croak "Require either 'code' or 'command' in $self";

   my @setup;
   push @setup, @{ $self->{setup} } if $self->{setup};

   push @setup, $self->_prepare_fds( $loop );

   my $mergepoint = $self->{mergepoint};
   
   $mergepoint->needs( "exit" );

   my ( $exitcode, $dollarbang, $dollarat );

   $self->{pid} = $loop->spawn_child(
      code    => $self->{code},
      command => $self->{command},

      setup => \@setup,

      on_exit => sub {
         ( undef, $exitcode, $dollarbang, $dollarat ) = @_;
         $mergepoint->done( "exit" );
      },
   );
   $self->{running} = 1;

   $self->SUPER::_add_to_loop( @_ );

   $_->close for values %{ delete $self->{to_close} };

   my $is_code = defined $self->{code};

   $mergepoint->close(
      on_finished => $self->_capture_weakself( sub {
         my $self = shift;
         my %items = @_;

         $self->{exitcode} = $exitcode;
         $self->{dollarbang} = $dollarbang;
         $self->{dollarat}   = $dollarat;

         undef $self->{running};

         if( $is_code ? $dollarat eq "" : $dollarbang == 0 ) {
            $self->invoke_event( on_finish => $exitcode );
         }
         else {
            $self->maybe_invoke_event( on_exception => $dollarat, $dollarbang, $exitcode ) or
               # Don't have a way to report dollarbang/dollarat
               $self->invoke_event( on_finish => $exitcode );
         }

         if( my $parent = $self->parent ) {
            $parent->remove_child( $self );
         }
         else {
            $self->get_loop->remove( $self );
         }
      } ),
   );
}

=head1 METHODS

=cut

=head2 $pid = $process->pid

Returns the process ID of the process, if it has been started, or C<undef> if
not. Its value is preserved after the process exits, so it may be inspected
during the C<on_finish> or C<on_exception> events.

=cut

sub pid
{
   my $self = shift;
   return $self->{pid};
}

=head2 $running = $process->is_running

Returns true if the Process has been started, and has not yet finished.

=cut

sub is_running
{
   my $self = shift;
   return $self->{running};
}

=head2 $exited = $process->is_exited

Returns true if the Process has finished running, and finished due to normal
C<exit()>.

=cut

sub is_exited
{
   my $self = shift;
   return defined $self->{exitcode} ? WIFEXITED( $self->{exitcode} ) : undef;
}

=head2 $status = $process->exitstatus

If the process exited due to normal C<exit()>, returns the value that was
passed to C<exit()>. Otherwise, returns C<undef>.

=cut

sub exitstatus
{
   my $self = shift;
   return defined $self->{exitcode} ? WEXITSTATUS( $self->{exitcode} ) : undef;
}

=head2 $exception = $process->exception

If the process exited due to an exception, returns the exception that was
thrown. Otherwise, returns C<undef>.

=cut

sub exception
{
   my $self = shift;
   return $self->{dollarat};
}

=head2 $errno = $process->errno

If the process exited due to an exception, returns the numerical value of
C<$!> at the time the exception was thrown. Otherwise, returns C<undef>.

=cut

sub errno
{
   my $self = shift;
   return $self->{dollarbang}+0;
}

=head2 $errstr = $process->errstr

If the process exited due to an exception, returns the string value of
C<$!> at the time the exception was thrown. Otherwise, returns C<undef>.

=cut

sub errstr
{
   my $self = shift;
   return $self->{dollarbang}."";
}

=head2 $stream = $process->fd( $fd )

Returns the L<IO::Async::Stream> associated with the given FD number. This
must have been set up by a C<configure> argument prior to adding the
C<Process> object to the C<Loop>.

The returned C<Stream> object have its read or write handle set to the other
end of a pipe connected to that FD number in the child process. Typically,
this will be used to call the C<write> method on, to write more data into the
child, or to set an C<on_read> handler to read data out of the child.

The C<on_closed> event for these streams must not be changed, or it will break
the close detection used by the C<Process> object and the C<on_finish> event
will not be invoked.

=cut

sub fd
{
   my $self = shift;
   my ( $fd ) = @_;

   return $self->{fd_handle}{$fd} or
      croak "$self does not have an fd Stream for $fd";
}

=head2 $stream = $process->stdin

=head2 $stream = $process->stdout

=head2 $stream = $process->stderr

Shortcuts for calling C<fd> with 0, 1, or 2 respectively, to obtain the
L<IO::Async::Stream> representing the standard input, output, or error streams
of the child process.

=cut

sub stdin  { shift->fd( 0 ) }
sub stdout { shift->fd( 1 ) }
sub stderr { shift->fd( 2 ) }

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
