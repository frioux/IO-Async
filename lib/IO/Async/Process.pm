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

=head2 on_exception $exception, $errno, $exitcode, $errno

Invoked when the process exits by an exception from C<code>, or by failing to
C<exec()> the given command. C<$errno> will be a dualvar, containing both
number and string values.

Note that this has a different name and a different argument order from
C<< Loop->open_child >>'s C<on_error>.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $process = IO::Async::Process->new( %args )

Constructs a new C<IO::Async::Process> object and returns it. One of the
following arguments must be passed, to give the program to be executed by the
child process.

=over 8

=item command => ARRAY or STRING

Either a reference to an array containing the command and its arguments, or a
plain string containing the command. This value is passed into perl's
C<exec()> function.

=item code => CODE

A block of code to execute in the child process. It will be called in scalar
context inside an C<eval> block.

=back

Once constructed, the C<Process> will need to be added to the C<Loop> before
the child process is started.

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;

   $self->SUPER::_init( $params );

   foreach (qw( code command )) {
      $self->{$_} = delete $params->{$_} if exists $params->{$_};
   }

   $self->{code} and $self->{command} and
      croak "Cannot pass both 'code' and 'command' to ".__PACKAGE__;

   $self->{code} or $self->{command} or
      croak "Require either 'code' or 'command' for ".__PACKAGE__;
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

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( on_finish on_exception )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->SUPER::configure( %params );
}

sub _add_to_loop
{
   my $self = shift;
   $self->SUPER::_add_to_loop( @_ );

   my $loop = $self->get_loop;

   $self->{pid} = $loop->open_child(
      code    => $self->{code},
      command => $self->{command},

      on_finish => $self->_capture_weakself( sub {
         my ( $self, undef, $exitcode ) = @_;
         $self->{exitcode} = $exitcode;
         undef $self->{pid};

         $self->invoke_event( on_finish => $exitcode );

         if( my $parent = $self->parent ) {
            $parent->remove_child( $self );
         }
         else {
            $self->get_loop->remove( $self );
         }
      } ),

      on_error => $self->_capture_weakself( sub {
         my ( $self, undef, $exitcode, $dollarbang, $dollarat ) = @_;
         $self->{exitcode}   = $exitcode;
         $self->{dollarbang} = $dollarbang;
         $self->{dollarat}   = $dollarat;
         undef $self->{pid};

         $self->invoke_event( on_exception => $dollarat, $dollarbang, $exitcode );

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
