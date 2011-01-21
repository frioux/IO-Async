#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007-2011 -- leonerd@leonerd.org.uk

package IO::Async::Loop::Poll;

use strict;
use warnings;

our $VERSION = '0.37';
use constant API_VERSION => '0.33';

use base qw( IO::Async::Loop );

use Carp;

use IO::Poll qw( POLLIN POLLOUT POLLHUP POLLERR );

use POSIX qw( EINTR );

# IO::Poll version 0.05 contain a bug whereby the ->remove() method doesn't
# properly clean up all the references to the handles. If the version we're
# using is in this range, we have to clean it up ourselves.
use constant IO_POLL_REMOVE_BUG => ( $IO::Poll::VERSION == '0.05' );

=head1 NAME

C<IO::Async::Loop::Poll> - use C<IO::Async> with C<poll(2)>

=head1 SYNOPSIS

Normally an instance of this class would not be directly constructed by a
program. It may however, be useful for runinng L<IO::Async> with an existing
program already using an C<IO::Poll> object.

 use IO::Poll;
 use IO::Async::Loop::Poll;

 my $poll = IO::Poll->new();
 my $loop = IO::Async::Loop::Poll->new( poll => $poll );

 $loop->add( ... );

 while(1) {
    my $timeout = ...
    my $ret = $poll->poll( $timeout );
    $loop->post_poll();
 }

=head1 DESCRIPTION

This subclass of C<IO::Async::Loop> uses an C<IO::Poll> object to perform
read-ready and write-ready tests.

To integrate with existing code that uses an C<IO::Poll>, a C<post_poll()> can
be called immediately after the C<poll()> method on the contained C<IO::Poll>
object. The appropriate mask bits are maintained on the C<IO::Poll> object
when notifiers are added or removed from the set, or when they change their
C<want_writeready> status. The C<post_poll()> method inspects the result bits
and invokes the C<on_read_ready()> or C<on_write_ready()> methods on the
notifiers.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $loop = IO::Async::Loop::Poll->new( %args )

This function returns a new instance of a C<IO::Async::Loop::Poll> object. It
takes the following named arguments:

=over 8

=item C<poll>

The C<IO::Poll> object to use for notification. Optional; if a value is not
given, a new C<IO::Poll> object will be constructed.

=back

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   my $poll = delete $args{poll};

   $poll ||= IO::Poll->new();

   my $self = $class->__new( %args );

   $self->{poll} = $poll;

   return $self;
}

=head1 METHODS

=cut

=head2 $count = $loop->post_poll( $poll )

This method checks the returned event list from a C<IO::Poll::poll()> call,
and calls any of the notification methods or callbacks that are appropriate.
It returns the total number of callbacks that were invoked; that is, the
total number of C<on_read_ready> and C<on_write_ready> callbacks for 
C<watch_io>, and C<enqueue_timer> event callbacks.

=over 8

=item $poll

Reference to the C<IO::Poll> object

=back

=cut

sub post_poll
{
   my $self = shift;

   my $iowatches = $self->{iowatches};
   my $poll      = $self->{poll};

   my $count = 0;

   foreach my $fd ( keys %$iowatches ) {
      my $watch = $iowatches->{$fd} or next;

      my $events = $poll->events( $watch->[0] );

      # We have to test separately because kernel doesn't report POLLIN when
      # a pipe gets closed.
      if( $events & (POLLIN|POLLHUP|POLLERR) ) {
         $count++, $watch->[1]->() if defined $watch->[1];
      }

      if( $events & (POLLOUT|POLLHUP|POLLERR) ) {
         $count++, $watch->[2]->() if defined $watch->[2];
      }
   }

   # Since we have no way to know if the timeout occured, we'll have to
   # attempt to fire any waiting timeout events anyway
   $count += $self->_manage_queues;

   return $count;
}

=head2 $count = $loop->loop_once( $timeout )

This method calls the C<poll()> method on the stored C<IO::Poll> object,
passing in the value of C<$timeout>, and then runs the C<post_poll()> method
on itself. It returns the total number of callbacks invoked by the 
C<post_poll()> method, or C<undef> if the underlying C<poll()> method returned
an error.

=cut

# override
sub loop_once
{
   my $self = shift;
   my ( $timeout ) = @_;

   $self->_adjust_timeout( \$timeout );

   my $poll = $self->{poll};

   my $pollret;

   # There is a bug in IO::Poll at least version 0.07, where poll() with no
   # registered masks returns immediately, rather than waiting for a timeout
   # This has been reported: 
   #   http://rt.cpan.org/Ticket/Display.html?id=25049
   if( $poll->handles ) {
      $pollret = $poll->poll( $timeout );

      if( ( $pollret == -1 and $! == EINTR ) or $pollret == 0 
              and defined $self->{sigproxy} ) {
         # A signal occured and we have a sigproxy. Allow one more poll call
         # with zero timeout. If it finds something, keep that result. If it
         # finds nothing, keep -1

         # Preserve $! whatever happens
         local $!;

         my $secondattempt = $poll->poll( 0 );
         $pollret = $secondattempt if $secondattempt > 0;
      }
   }
   else {
      # Workaround - we'll use select() to fake a millisecond-accurate sleep
      $pollret = select( undef, undef, undef, $timeout );
   }

   return undef unless defined $pollret;

   return $self->post_poll();
}

sub watch_io
{
   my $self = shift;
   my %params = @_;

   $self->__watch_io( %params );

   my $poll = $self->{poll};

   my $handle = $params{handle};

   my $curmask = $poll->mask( $handle ) || 0;

   my $mask = $curmask;
   $params{on_read_ready}  and $mask |= POLLIN;
   $params{on_write_ready} and $mask |= POLLOUT;

   $poll->mask( $handle, $mask ) if $mask != $curmask;
}

sub unwatch_io
{
   my $self = shift;
   my %params = @_;

   $self->__unwatch_io( %params );

   # Guard for global destruction
   my $poll = $self->{poll} or return;

   my $handle = $params{handle};

   my $curmask = $poll->mask( $handle ) || 0;

   my $mask = $curmask;
   $params{on_read_ready}  and $mask &= ~POLLIN;
   $params{on_write_ready} and $mask &= ~POLLOUT;

   $poll->mask( $handle, $mask ) if $mask != $curmask;
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
