#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011 -- leonerd@leonerd.org.uk

package IO::Async::Process;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.35';

use Carp;

use POSIX qw(
   WIFEXITED WEXITSTATUS
);

use IO::Async::MergePoint;

=head1 NAME

C<IO::Async::Process> - start and manage a child process

=head1 SYNOPSIS

 TODO

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
   foreach (qw( code command stdin stdout stderr ), grep { m/^fd\d+$/ } keys %params ) {
      $setup_params{$_} = delete $params{$_} if exists $params{$_};
   }

   if( $self->is_running ) {
      keys %setup_params and croak "Cannot configure a running Process with " . join ", ", keys %setup_params;
   }

   defined( exists $setup_params{code} ? $setup_params{code} : $self->{code} ) +
      defined( exists $setup_params{command} ? $setup_params{command} : $self->{command} ) <= 1 or
      croak "Cannot have both 'code' and 'command'";

   foreach (qw( code command )) {
      $self->{$_} = delete $setup_params{$_} if exists $setup_params{$_};
   }

   foreach ( keys %setup_params ) {
      $self->{fd_args}{$_} = $setup_params{$_};
   }

   $self->SUPER::configure( %params );
}

sub _prepare
{
   my $self = shift;
   my ( $loop ) = @_;

   my $fd_args = $self->{fd_args};

   $self->{more_setup}  = \my @setup;
   $self->{to_close} = \my @to_close;
   $self->{mergepoint} = my $mergepoint = IO::Async::MergePoint->new;

   foreach my $key ( keys %$fd_args ) {
      my $fdopts = $fd_args->{$key};

      my $orig_key = $key;

      # Rewrite stdin/stdout/stderr
      $key eq "stdin"  and $key = "fd0";
      $key eq "stdout" and $key = "fd1";
      $key eq "stderr" and $key = "fd2";

      ref $fdopts eq "HASH" or croak "Expected '$orig_key' to be a HASH ref";

      my $op;

      if( exists $fdopts->{on_read} ) {
         ref $fdopts->{on_read} or croak "Expected 'on_read' for '$orig_key' to be a reference";
         scalar keys %$fdopts == 1 or croak "Found other keys than 'on_read' for '$orig_key'";

         $op = "pipe_read";
      }
      elsif( exists $fdopts->{from} ) {
         ref $fdopts->{from} eq "" or croak "Expected 'from' for '$orig_key' not to be a reference";
         scalar keys %$fdopts == 1 or croak "Found other keys than 'from' for '$orig_key'";

         $op = "pipe_write";
      }
      else {
         croak "Cannot recognise what to do with '$orig_key'";
      }

      my ( $myfd, $childfd );

      if( $op eq "pipe_read" ) {
         ( $myfd, $childfd ) = $loop->pipepair() or croak "Unable to pipe() - $!";
      }
      elsif( $op eq "pipe_write" ) {
         ( $childfd, $myfd ) = $loop->pipepair() or croak "Unable to pipe() - $!";
      }

      push @setup, $key => [ dup => $childfd ];
      push @to_close, $childfd;

      $mergepoint->needs( $key );

      my $notifier;

      if( exists $fdopts->{on_read} ) {
         my $on_read = $fdopts->{on_read};

         $notifier = IO::Async::Stream->new(
            read_handle => $myfd,

            on_read => $on_read,

            on_closed => sub {
               $mergepoint->done( $key );
            },
         );
      }
      elsif( exists $fdopts->{from} ) {
         $notifier = IO::Async::Stream->new(
            write_handle => $myfd,

            on_outgoing_empty => sub {
               my ( $stream ) = @_;
               $stream->close;
            },

            on_closed => sub {
               $mergepoint->done( $key );
            },
         );

         $notifier->write( $fdopts->{from} );
      }

      $self->add_child( $notifier );
   }
}

sub _add_to_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $self->{code} or $self->{command} or
      croak "Require either 'code' or 'command' in $self";

   $self->_prepare( $loop );

   my $mergepoint = $self->{mergepoint};
   
   $mergepoint->needs( "exit" );

   my ( $exitcode, $dollarbang, $dollarat );

   $self->{pid} = $loop->spawn_child(
      code    => $self->{code},
      command => $self->{command},

      setup => $self->{more_setup},

      on_exit => sub {
         ( undef, $exitcode, $dollarbang, $dollarat ) = @_;
         $mergepoint->done( "exit" );
      },
   );

   $self->SUPER::_add_to_loop( @_ );

   $_->close for @{ delete $self->{to_close} };

   my $is_code = defined $self->{code};

   $mergepoint->close(
      on_finished => $self->_capture_weakself( sub {
         my $self = shift;
         my %items = @_;

         $self->{exitcode} = $exitcode;
         $self->{dollarbang} = $dollarbang;
         $self->{dollarat}   = $dollarat;

         undef $self->{pid};

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

=head2 $running = $process->is_running

Returns true if the Process has been started, and has not yet finished.

=cut

sub is_running
{
   my $self = shift;
   return defined $self->{pid};
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

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
