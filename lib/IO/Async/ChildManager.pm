#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::ChildManager;

use strict;

our $VERSION = '0.04';

# Not a notifier

use Carp;
use POSIX qw( WNOHANG );

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

=head2 $manager = IO::Async::ChildManager->new()

This function returns a new instance of a C<IO::Async::ChildManager> object.

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $self = bless {
      childdeathhandlers => {},
   }, $class;

   return $self;
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

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
