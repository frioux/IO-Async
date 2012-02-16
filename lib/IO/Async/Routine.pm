#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2012 -- leonerd@leonerd.org.uk

package IO::Async::Routine;

use strict;
use warnings;

our $VERSION = '0.45';

use base qw( IO::Async::Process );

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

0x55AA;
