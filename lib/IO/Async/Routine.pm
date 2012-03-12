#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2012 -- leonerd@leonerd.org.uk

package IO::Async::Routine;

use strict;
use warnings;

our $VERSION = '0.46_001';

use base qw( IO::Async::Process );

=head1 NAME

C<IO::Async::Routine> - execute code in an independent sub-process

=head1 SYNOPSIS

 use IO::Async::Routine;
 use IO::Async::Channel;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 my $nums_ch = IO::Async::Channel->new;
 my $ret_ch  = IO::Async::Channel->new;

 my $routine = IO::Async::Routine->new(
    channels_in  => [ $nums_ch ],
    channels_out => [ $ret_ch ],

    code => sub {
       my @nums = @{ $nums_ch->recv };
       my $ret = 0; $ret += $_ for @nums;

       # Can only send references
       $ret_ch->send( \$ret );
    },
 );

 $loop->add( $routine );

 $nums_ch->send( [ 10, 20, 30 ] );
 $ret_ch->recv(
    on_recv => sub {
       my ( $totalref ) = @_;
       say "The total of 10, 20, 30 is: $$totalref";
       $loop->loop_stop;
    }
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This subclass of L<IO::Async::Process> contains a body of code and executes it
in a sub-process, allowing it to act independently of the main program. Once
set up, all communication with the code happens by values passed into or out
of the Routine via L<IO::Async::Channel> objects.

Because the code running inside the Routine runs within its own process, it
is isolated from the rest of the program, in terms of memory, CPU time, and
other resources, and perhaps most importantly in terms of control flow. The
code contained within the Routine is free to make blocking calls without
stalling the rest of the program. This makes it useful for using existing code
which has no option not to block within an C<IO::Async>-based program.

To create asynchronous wrappers of functions that return a value based only on
their arguments, and do not generally maintain state within the process it may
be more convenient to use an L<IO::Async::Function> instead, which uses an
C<IO::Async::Routine> to contain the body of the function and manages the
Channels itself.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item channels_in => ARRAY of IO::Async::Channel

ARRAY reference of C<IO::Async::Channel> objects to set up for passing values
in to the Routine.

=item channels_out => ARRAY of IO::Async::Channel

ARRAY reference of C<IO::Async::Channel> objects to set up for passing values
out of the Routine.

=item code => CODE

CODE reference to the body of the Routine, to execute once the channels are
set up.

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   # TODO: Can only reconfigure when not running
   foreach (qw( channels_in channels_out )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->SUPER::configure( %params );
}

sub _add_to_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   # Assign fd numbers to channels
   my %fds;
   my @channels_in;
   my @channels_out;
   {
      # Start at fd3 so as not to upset STDIN/OUT/ERR
      my $fd = 3;

      foreach my $ch ( @{ $self->{channels_in} || [] } ) {
         $fds{"fd" . $fd} = { via => "pipe_write" };
         push @channels_in, [ $ch, $fd++ ];
      }

      foreach my $ch ( @{ $self->{channels_out} || [] } ) {
         $fds{"fd" . $fd} = { via => "pipe_read" };
         push @channels_out, [ $ch, $fd++ ];
      }
   }

   # TODO: This breaks encap.
   my $code = delete $self->{code};

   $self->configure(
      %fds,
      code => sub {
         foreach ( @channels_in ) {
            my ( $ch, $fd ) = @$_;
            $ch->setup_sync_mode( IO::Handle->new_from_fd( $fd, "<" ) );
         }
         foreach ( @channels_out ) {
            my ( $ch, $fd ) = @$_;
            $ch->setup_sync_mode( IO::Handle->new_from_fd( $fd, ">" ) );
         }

         my $ret = $code->();

         foreach ( @channels_in, @channels_out ) {
            my ( $ch ) = @$_;
            $ch->close;
         }

         return $ret;
      },
   );

   foreach ( @channels_in, @channels_out ) {
      my ( $ch, $fd ) = @$_;
      $ch->setup_async_mode( stream => $self->fd( $fd ) );
   }

   $self->SUPER::_add_to_loop( $loop );
}

=head1 METHODS

This class provides no additional methods, other than those provided by
L<IO::Async::Process>.

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
