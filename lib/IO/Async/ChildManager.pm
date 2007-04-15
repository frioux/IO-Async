#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::ChildManager;

use strict;

our $VERSION = '0.04';

# Not a notifier

use IO::Async::Buffer;

use Carp;
use Fcntl qw( F_GETFL F_SETFL FD_CLOEXEC );
use POSIX qw( WNOHANG _exit );

use constant LENGTH_OF_I => length( pack( "I", 0 ) );

=head1 NAME

C<IO::Async::ChildManager> - a class which facilitates the execution of child
processes

=head1 SYNOPSIS

Usually this object would be used indirectly, via an C<IO::Async::Set>:

 use IO::Async::Set::...;
 my $set = IO::Async::Set::...

 $set->enable_childmanager;

 ...

 $set->watch_child( 1234 => sub { print "Child 1234 exited\n" } );

It can also be used directly:

 use IO::Async::ChildManager;

 my $manager = IO::Async::ChildManager->new();

 my $set = IO::Async::Set::...
 $set->attach_signal( CHLD => sub { $manager->SIGCHLD } );

 ...

 $manager->watch( 1234 => sub { print "Child 1234 exited\n" } );

=head1 DESCRIPTION

This module provides a class that manages the execution of child processes. It
acts as a central point to store PID values of currently-running children, and
to call the appropriate callback handler code when the process terminates.

=head2 Callbacks

When the C<waitpid()> call returns a PID that the manager is observing, the
registered callback function is invoked with its PID and the current value of
the C<$?> variable.

 $code->( $pid, $? )

After invocation, the handler is automatically removed from the manager.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $manager = IO::Async::ChildManager->new( %params )

This function returns a new instance of a C<IO::Async::ChildManager> object.
The C<%params> hash takes the following keys:

=over 8

=item set => IO::Async::Set

A reference to an C<IO::Async::Set> object. This is required to be able to use
the C<spawn()> method.

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $self = bless {
      childdeathhandlers => {},
      containing_set     => $params{set},
   }, $class;

   return $self;
}

=head2 $manager->associate_set( $set )

This method associates an C<IO::Async::Set> with the manager. This is required
for the IO handle code in the C<spawn()> method to work.

=cut

sub associate_set
{
   my $self = shift;
   my ( $set ) = @_;

   $self->{containing_set} = $set;
}

=head1 METHODS

=cut

=head2 $count = $manager->SIGCHLD

This method notifies the manager that one or more child processes may have
terminated, and that it should check using C<waitpid()>. It returns the number
of child process terminations that were handled.

=cut

sub SIGCHLD
{
   my $self = shift;

   my $handlermap = $self->{childdeathhandlers};

   my $count = 0;

   while( 1 ) {
      my $zid = waitpid( -1, WNOHANG );

      last if !defined $zid or $zid < 1;
 
      if( defined $handlermap->{$zid} ) {
         $handlermap->{$zid}->( $zid, $? );
         undef $handlermap->{$zid};
      }
      else {
         carp "No child death handler for '$zid'";
      }

      $count++;
   }

   return $count;
}

=head2 $manager->watch( $kid, $code )

This method adds a new handler for the termination of the given child PID.

=over 8

=item $kid

The PID to watch.

=item $code

A CODE reference to the handling function.

=back

=cut

sub watch
{
   my $self = shift;
   my ( $kid, $code ) = @_;

   my $handlermap = $self->{childdeathhandlers};

   croak "Already have a handler for $kid" if exists $handlermap->{$kid};
   $handlermap->{$kid} = $code;

   return;
}

=head2 $pid = $manager->spawn( %params )

This method creates a new child process to run a given code block or command.
The C<%params> hash takes the following keys:

=over 8

=item command => ARRAY or STRING

Either a reference to an array containing the command and its arguments, or a
plain string containing the command. This value is passed into perl's
C<exec()> function.

=item code => CODE

A block of code to execute in the child process. It will be called in scalar
context inside an C<eval> block.

=item on_exit => CODE

A callback function to be called when the child processes exits. It will be
invoked in the following way:

 $on_exit->( $pid, $exitcode, $dollarbang, $dollarat )

=back

Exactly one of the C<command> or C<code> keys must be specified.

If the C<command> key is used, the given array or string is executed using the
C<exec()> function. 

If the C<code> key is used, the return value will be used as the C<exit()>
code from the child if it returns (or 255 if it returned C<undef> or thows an
exception).

 Case            | WEXITSTATUS($exitcode) | $dollarbang | $dollarat
 ----------------+------------------------+-------------+----------
 exec() succeeds | exit code from program |     0       |    ""
 exec() fails    |         255            |     $!      |    ""
 $code returns   |     return value       |     $!      |    ""
 $code dies      |         255            |     $!      |    $@

=cut

sub spawn
{
   my $self = shift;
   my %params = @_;

   # We can only spawn if we've got a containing set
   defined $self->{containing_set} or
      croak "Cannot spawn in a ChildManager with no containing set";

   my $command = delete $params{command};
   my $code    = delete $params{code};
   my $on_exit = delete $params{on_exit};

   if( %params ) {
      croak "Unrecognised options to spawn: " . join( ",", keys %params );
   }

   defined $command and defined $code and 
      croak "Cannot pass both 'command' and 'code' to spawn";

   defined $command or defined $code or
      croak "Must pass one of 'command' or 'code' to spawn";

   pipe( my $readpipe, my $writepipe ) or croak "Cannot pipe() - $!";

   my $flags = fcntl( $writepipe, F_GETFL, 0 ) or 
      croak "Cannot fcntl(F_GETFL) - $!";
   fcntl( $writepipe, F_SETFL, $flags | FD_CLOEXEC ) or
      croak "Cannot fcntl(F_SETFL) - $!";

   if( defined $command ) {
      my @command = ref( $command ) ? @$command : ( $command );

      $code = sub {
         no warnings;
         exec( @command );
         return;
      };
   }

   my $kid = fork();
   defined $kid or croak "Cannot fork() - $!";

   if( $kid != 0 ) {
      # Parent
      close( $writepipe );
      $self->_spawn_in_parent( $readpipe, $kid, $on_exit );
   }
   else {
      # Child
      close( $readpipe );
      $self->_spawn_in_child( $writepipe, $code );
   }
}

sub _spawn_in_parent
{
   my $self = shift;
   my ( $readpipe, $kid, $on_exit ) = @_;

   my $set = $self->{containing_set};

   # We need to wait for both the errno pipe to close, and for waitpid()
   # to give us an exit code. We'll form two closures over these two
   # variables so we can cope with those happening in either order

   my $dollarbang;
   my ( $dollarat, $length_dollarat );
   my $exitcode;

   $set->add( IO::Async::Buffer->new(
      read_handle => $readpipe,

      on_incoming_data => sub {
         my ( $self, $buffref, $closed ) = @_;

         if( !defined $dollarbang ) {
            if( length( $$buffref ) >= 2 * LENGTH_OF_I ) {
               ( $dollarbang, $length_dollarat ) = unpack( "II", $$buffref );
               substr( $$buffref, 0, 2 * LENGTH_OF_I, "" );
               return 1;
            }
         }
         elsif( !defined $dollarat ) {
            if( length( $$buffref ) >= $length_dollarat ) {
               $dollarat = substr( $$buffref, 0, $length_dollarat, "" );
               return 1;
            }
         }

         if( $closed ) {
            $dollarbang = 0  if !defined $dollarbang;
            if( !defined $length_dollarat ) {
               $length_dollarat = 0;
               $dollarat = "";
            }

            if( defined $exitcode ) {
               local $! = $dollarbang;
               $on_exit->( $kid, $exitcode, $!, $dollarat );
            }

            $set->remove( $self );
         }

         return 0;
      }
   ) );

   $self->watch( $kid => sub { 
      ( my $kid, $exitcode ) = @_;

      if( defined $dollarat ) {
         local $! = $dollarbang;
         $on_exit->( $kid, $exitcode, $!, $dollarat );
      }
   } );

   return $kid;
}

sub _spawn_in_child
{
   my $self = shift;
   my ( $writepipe, $code ) = @_;

   my $exitvalue = eval { $code->() };

   defined $exitvalue or $exitvalue = -1;

   my $writebuffer = "";
   $writebuffer .= pack( "I", $!+0 );
   $writebuffer .= pack( "I", length( $@ ) ) . $@;

   syswrite( $writepipe, $writebuffer );
   _exit( $exitvalue );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
