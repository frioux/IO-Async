#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::SignalProxy;

use strict;

our $VERSION = '0.03';

use base qw( IO::Async::Notifier );

use Carp;

use POSIX qw( EAGAIN SIG_BLOCK SIG_SETMASK sigprocmask );
use IO::Handle;

=head1 NAME

C<IO::Async::SignalProxy> - a class to allow handling of POSIX signals with
C<IO::Async>-based IO

=head1 SYNOPSIS

 use IO::Async::SignalProxy;

 my $sigproxy = IO::Async::SignalProxy->new(
    signal_HUP => sub { reread_config() },
 );

 my $set = IO::Async::Set::...
 $set->add( $sigproxy );

=head1 DESCRIPTION

This module provides a class that allows POSIX signals to be handled safely
alongside other IO operations on filehandles in an C<IO::Async::Set>. Because
signals could arrive at any time, care must be taken that they do not
interrupt the normal flow of the program, and are handled at the same time as
other events in the C<IO::Async::Set>'s results.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $proxy = IO::Async::SignalProxy->new( %params )

This function returns a new instance of a C<IO::Async::SignalProxy> object.
The C<%params> hash takes keys that specify callback functions to run when
signals arrive. They are all of the form

 signal_$NAME => sub { ... }

where C<$NAME> is the basic POSIX name for the signal, such as C<TERM> or
C<CHLD>.

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   pipe( my ( $reader, $writer ) ) or croak "Cannot pipe() - $!";

   $reader->blocking( 0 );
   $writer->blocking( 0 );

   my $self = $class->SUPER::new(
      %params,
      read_handle => $reader,
   );

   $self->{restore_SIG}  = {}; # {$signame} = value
   $self->{callbacks} = {}; # {$signame} = CODE

   # This variable is race-sensitive - read the notes in __END__ section
   # before attempting to modify this code.
   my $signal_queue = $self->{signal_queue} = [];

   my $sigset_block = POSIX::SigSet->new();

   # Find all the signal handler callbacks
   foreach my $signame ( map { m/^signal_(.*)$/ ? $1 : () } keys %params ) {
      $self->{callbacks}->{$signame} = $params{"signal_$signame"};

      exists $SIG{$signame} or croak "Unrecognised signal name $signame";

      # Don't allow anyone to trash an existing signal handler
      !defined $SIG{$signame} or !ref $SIG{$signame} or croak "Cannot override signal handler for $signame";

      $self->{restore_SIG}->{$signame} = $SIG{$signame};

      $SIG{$signame} = sub {
         # This signal handler is race-sensitive - read the notes in the
         # __END__ section before attempting to modify this code.
         if( !@$signal_queue ) {
            syswrite( $writer, "\0" );
         }
         push @$signal_queue, $signame;
      };

      my $signum;
      {
         no strict 'refs';
         local @_;
         $signum = &{"POSIX::SIG$signame"};
      }

      $sigset_block->addset( $signum );
   }

   $self->{sigset_block} = $sigset_block;

   return $self;
}

sub DESTROY
{
   my $self = shift;

   my $restore_SIG = $self->{restore_SIG};

   # When we saved the original value, we might have got an undef. But %SIG
   # doesn't like having undef assigned back in, so we need to translate

   $SIG{$_} = $restore_SIG->{$_} || 'DEFAULT' foreach keys %$restore_SIG;
}

# protected
sub on_read_ready
{
   my $self = shift;

   my $signal_queue = $self->{signal_queue};

   my @caught_signals;

   my $sigset_old = POSIX::SigSet->new();
   sigprocmask( SIG_BLOCK, $self->{sigset_block}, $sigset_old ) or croak "Cannot sigprocmask() - $!";

   my $success = eval {
      # This notifier handler is race-sensitive - read the notes in the
      # __END__ section before attempting to modify this code.

      my $handle = $self->read_handle;
      my $buffer;
      my $ret = $handle->sysread( $buffer, 8192 );

      if( !defined $ret and $! == EAGAIN ) {
         # Pipe wasn't ready after all - ignore it
      }
      elsif( !defined $ret ) {
         croak "Cannot sysread() signal pipe - $!";
      }
      elsif( $ret > 0 ) {
         # We get signal
         @caught_signals = @$signal_queue;
         @$signal_queue = ();
      }
      else {
         croak "Signal pipe was closed";
      }

      1;
   };
   
   {
      local $@;
      sigprocmask( SIG_SETMASK, $sigset_old ) or croak "Cannot sigprocmask() - $!";
   }

   # Race-sensitive region is now over - continue in the normal way

   die $@ if !$success;

   foreach( @caught_signals ) {
      my $callback = $self->{callbacks}->{$_};
      $callback->();
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

Some notes on implementation
============================

The purpose of this object class is to safely call the required signal-
handling callback code as part of the usual IO::Async::Set loop. This is done 
by keeping a queue of incoming signal names in the array referenced by 
$self->{signal_queue}. The object installs its own signal handler which pushes
the signal name to this array, and the on_read_ready method then replays them
out again.

In order to safely interact with any sort of file-based asynchronous IO (such
as a select() or poll() system call), the object keeps both ends of a pipe.
When a signal arrives that causes the signal queue array to become nonempty, a
zero byte is pushed onto that pipe. This makes the reading end read-ready, and
so will correctly behave in such a select() or poll() syscall. Thus, the
emptyness of the signal queue array is maintained identically to the emptyness
of the pipe. The value of the bytes in the pipe does not matter; only their
presence is important.

The on_read_ready method uses POSIX::sigprocmask() to mask off all the signals
that the object is handling, so that it can atomically read the pipe and empty
the signal queue array, without a danger of a race condition if another signal
arrives while it is doing this. The only race condition that remains is the
case where a signal arrives while the handler for another signal has reached
the critical stage:

      if( !@$signal_queue ) {
         # OTHER SIGNAL ARRIVES HERE
         syswrite( $writer, "\0" );
      }

In this case, no bad effects will happen. There will simply be two bytes
written into the pipe, rather than the usual one. The on_read_ready handler
will attempt a sysread() of up to 8192 bytes, and there are usually no more
than a handful of different signal handlers registered, so this will usually
not be a problem. In the exceedingly-unlikely event that more than 8192
different user-defined signal handlers have in fact been registered, and every
one of them is fired at the same time, and every one races with all the others
in the way indicated above, then all that will happen is that the pipe will
remain non-empty while the signal queue array is empty. In this case, the
on_read_ready handler will be fired again, read up-to 8192 more bytes, then
find the queue to be empty, and return again.

=head1 SEE ALSO

=over 4

=item *

L<POSIX> for the C<SIGI<name>> constants

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
