#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007-2009 -- leonerd@leonerd.org.uk

package # hide from CPAN
  IO::Async::Internals::SignalProxy;

use strict;

use base qw( IO::Async::Handle );

use Carp;

use POSIX qw( EAGAIN SIG_BLOCK SIG_SETMASK sigprocmask );
use IO::Handle;

use warnings qw();

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $loop = delete $params{loop} or croak "Expected a 'loop'";

   my ( $reader, $writer ) = $loop->pipepair() or croak "Cannot pipe() - $!";

   $reader->blocking( 0 );
   $writer->blocking( 0 );

   my $self = $class->SUPER::new(
      %params,
      read_handle => $reader,
   );

   $self->{pipe_writing_end} = $writer;

   $self->{restore_SIG}  = {}; # {$signame} = value
   $self->{callbacks} = {}; # {$signame} = CODE

   # This variable is race-sensitive - read the notes in __END__ section
   # before attempting to modify this code.
   $self->{signal_queue} = [];

   $self->{sigset_block} = POSIX::SigSet->new();

   $loop->add( $self );

   return $self;
}

sub DESTROY
{
   my $self = shift;

   my $restore_SIG = $self->{restore_SIG};

   $self->unwatch( $_ ) foreach keys %$restore_SIG;
}

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
      # This shouldn't fail, but I've seen what looked like a race condition
      # failure on a Solaris 8 + perl 5.6.1 machine here. This message should
      # at least help find the problem
      defined $callback or croak "Undefined callback for signal $_";
      ref $callback eq "CODE" or croak "Callback for signal $_ is not a CODE ref";

      $callback->();
   }
}

sub watch
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   exists $SIG{$signal} or croak "Unrecognised signal name $signal";

   ref $code eq "CODE" or croak 'Expected $code as a CODE reference';

   $self->{callbacks}->{$signal} = $code;

   $self->{restore_SIG}->{$signal} = $SIG{$signal};

   my $writer = $self->{pipe_writing_end};
   my $signal_queue = $self->{signal_queue};

   # This closure cannot refer to $self because that would keep the reference
   # count on the object and prevent it from being DESTROYed when it goes out
   # of scope from the caller
   $SIG{$signal} = sub {
      # This signal handler is race-sensitive - read the notes in the
      # __END__ section before attempting to modify this code.

      # Protect the interrupted code against unexpected modifications of $!,
      # such as the line just after the poll() call in IO::Async::Loop::IO_Poll
      local $!;

      if( !@$signal_queue ) {
         syswrite( $writer, "\0" );
      }
      push @$signal_queue, $signal;
   };

   my $signum = $self->get_loop->signame2num( $signal );

   my $sigset_block = $self->{sigset_block};
   $sigset_block->addset( $signum );
}

sub unwatch
{
   my $self = shift;
   my ( $signal ) = @_;

   my $restore_SIG = $self->{restore_SIG};

   exists $restore_SIG->{$signal} or croak "Signal name $signal is not currently attached";

   # When we saved the original value, we might have got an undef. But %SIG
   # doesn't like having undef assigned back in, so we need to translate
   $SIG{$signal} = $restore_SIG->{$signal} || 'DEFAULT';

   delete $restore_SIG->{$signal};
   delete $self->{callbacks}->{$signal};
}

sub signals
{
   my $self = shift;
   return keys %{ $self->{callbacks} };
}

# Keep perl happy; keep Britain tidy
1;

__END__

Some notes on implementation
============================

The purpose of this object class is to safely call the required signal-
handling callback code as part of the usual IO::Async::Loop loop. This is done 
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
