#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011-2012 -- leonerd@leonerd.org.uk

package IO::Async::Channel;

use strict;
use warnings;
use base qw( IO::Async::Notifier ); # just to get _capture_weakself

our $VERSION = '0.54';

use Carp;
use Storable qw( freeze thaw );

use IO::Async::Stream;

=head1 NAME

C<IO::Async::Channel> - pass values into or out from an L<IO::Async::Routine>

=head1 DESCRIPTION

A C<IO::Async::Channel> object allows Perl values to be passed into or out of
an L<IO::Async::Routine>. It is intended to be used primarily with a Routine
object rather than independently. For more detail and examples on how to use
this object see also the documentation for L<IO::Async::Routine>.

A Channel object is shared between the main process of the program and the
process running within the Routine. In the main process it will be used in
asynchronous mode, and in the Routine process it will be used in synchronous
mode. In asynchronous mode all methods return immediately and use
C<IO::Async>-style callback functions. In synchronous within the Routine
process the methods block until they are ready and may be used for
flow-control within the routine. Alternatively, a Channel may be shared
between two different Routine objects, and not used directly by the
controlling program.

The channel itself represents a FIFO of Perl reference values. New values may
be put into the channel by the C<send> method in either mode. Values may be
retrieved from it by the C<recv> method. Values inserted into the Channel are
snapshot by the C<send> method. Any changes to referred variables will not be
observed by the other end of the Channel after the C<send> method returns.

Since the channel uses L<Storable> to serialise values to write over the
communication filehandle only reference values may be passed. To pass a single
scalar value, C<send> a SCALAR reference to it, and dereference the result of
C<recv>.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $channel = IO::Async::Channel->new

Returns a new C<IO::Async::Channel> object. This object reference itself
should be shared by both sides of a C<fork()>ed process. After C<fork()> the
two C<setup_*> methods may be used to configure the object for operation on
either end.

While this object does in fact inherit from L<IO::Async::Notifier> for
implementation reasons it is not intended that this object be used as a
Notifier. It should not be added to a Loop object directly; event management
will be handled by its containing C<IO::Async::Routine> object.

=cut

sub new
{
   my $class = shift;
   return bless {
      mode => "",
   }, $class;
}

=head1 METHODS

=cut

=head2 $channel->configure( %params )

Similar to the standard C<configure> method on C<IO::Async::Notifier>, this is
used to change details of the Channel's operation.

=over 4

=item on_recv => CODE

May only be set on an async mode channel. If present, will be invoked whenever
a new value is received, rather than using the C<recv> method.

 $on_recv->( $channel, $data )

=item on_eof => CODE

May only be set on an async mode channel. If present, will be invoked when the
channel gets closed by the peer.

 $on_eof->( $channel )

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( on_recv on_eof )) {
      next unless exists $params{$_};
      $self->{mode} and $self->{mode} eq "async" or
         croak "Can only configure $_ in async mode";

      $self->{$_} = delete $params{$_};
      $self->_build_stream;
   }

   $self->SUPER::configure( %params );
}

=head2 $channel->send( $data )

Pushes the data stored in the given Perl reference into the FIFO of the
Channel, where it can be received by the other end. When called on a
synchronous mode Channel this method may block if a C<write()> call on the
underlying filehandle blocks. When called on an asynchronous mode channel this
method will not block.

=cut

sub send
{
   my $self = shift;
   my ( $data ) = @_;

   my $record = freeze $data;
   $self->send_frozen( $record );
}

=head2 $channel->send_frozen( $record )

A variant of the C<send> method; this method pushes the byte record given.
This should be the result of a call to C<Storable::freeze()>.

=cut

sub send_frozen
{
   my $self = shift;
   my ( $record ) = @_;

   my $bytes = pack( "I", length $record ) . $record;

   defined $self->{mode} or die "Cannot ->send without being set up";

   return $self->_send_sync( $bytes )  if $self->{mode} eq "sync";
   return $self->_send_async( $bytes ) if $self->{mode} eq "async";
}

=head2 $data = $channel->recv

When called on a synchronous mode Channel this method will block until a Perl
reference value is available from the other end and then return it. If the
Channel is closed this method will return C<undef>. Since only references may
be passed and all Perl references are true the truth of the result of this
method can be used to detect that the channel is still open and has not yet
been closed.

=head2 $channel->recv( %args )

When called on an asynchronous mode Channel this method appends a callback
function to the receiver queue to handle the next Perl reference value that
becomes available from the other end. Takes the following named arguments:

=over 8

=item on_recv => CODE

Called when a new Perl reference value is available. Will be passed the
Channel object and the reference data.

 $on_recv->( $channel, $data )

=item on_eof => CODE

Called if the Channel was closed before a new value was ready. Will be passed
the Channel object.

 $on_eof->( $channel )

=back

=cut

sub recv
{
   my $self = shift;

   defined $self->{mode} or die "Cannot ->recv without being set up";

   return $self->_recv_sync( @_ )  if $self->{mode} eq "sync";
   return $self->_recv_async( @_ ) if $self->{mode} eq "async";
}

=head2 $channel->close

Closes the channel. Causes a pending C<recv> on the other end to return undef
or the queued C<on_eof> callbacks to be invoked.

=cut

sub close
{
   my $self = shift;

   return $self->_close_sync  if $self->{mode} eq "sync";
   return $self->_close_async if $self->{mode} eq "async";
}

# Leave this undocumented for now
sub setup_sync_mode
{
   my $self = shift;
   ( $self->{fh} ) = @_;

   $self->{mode} = "sync";

   # Since we're communicating binary structures and not Unicode text we need to
   # enable binmode
   binmode $self->{fh};

   $self->{fh}->autoflush(1);
}

sub _read_exactly
{
   $_[1] = "";

   while( length $_[1] < $_[2] ) {
      my $n = read( $_[0], $_[1], $_[2]-length $_[1], length $_[1] );
      defined $n or return undef;
      $n or return "";
   }

   return $_[2];
}

sub _recv_sync
{
   my $self = shift;

   my $n = _read_exactly( $self->{fh}, my $lenbuffer, 4 );
   defined $n or die "Cannot read - $!";
   length $n or return undef;

   my $len = unpack( "I", $lenbuffer );

   $n = _read_exactly( $self->{fh}, my $record, $len );
   defined $n or die "Cannot read - $!";
   length $n or return undef;

   return thaw $record;
}

sub _send_sync
{
   my $self = shift;
   my ( $bytes ) = @_;
   $self->{fh}->print( $bytes );
}

sub _close_sync
{
   my $self = shift;
   $self->{fh}->close;
}

# Leave this undocumented for now
sub setup_async_mode
{
   my $self = shift;
   my %args = @_;

   exists $args{$_} and $self->{$_} = delete $args{$_} for qw( read_handle write_handle );

   keys %args and croak "Unrecognised keys for setup_async_mode: " . join( ", ", keys %args );

   $self->{mode} = "async";
}

sub _build_stream
{
   my $self = shift;
   return $self->{stream} ||= do {
      $self->{on_result_queue} = [];

      my $stream = IO::Async::Stream->new(
         read_handle  => $self->{read_handle},
         write_handle => $self->{write_handle},
         autoflush    => 1,
         on_read      => $self->_capture_weakself( '_on_stream_read' )
      );

      $self->add_child( $stream );

      $stream;
   };
}

sub _send_async
{
   my $self = shift;
   my ( $bytes ) = @_;
   $self->_build_stream->write( $bytes );
}

sub _recv_async
{
   my $self = shift;
   my %args = @_;
   my $on_recv = $args{on_recv};
   my $on_eof  = $args{on_eof};

   $self->_build_stream;

   push @{ $self->{on_result_queue} }, sub {
      my ( $self, $type, $result ) = @_;
      if( $type eq "recv" ) {
         $on_recv->( $self, $result );
      }
      else {
         $on_eof->( $self );
      }
   }
}

sub _close_async
{
   my $self = shift;
   $self->{stream}->close_when_empty if $self->{stream};
}

sub _on_stream_read
{
   my $self = shift;
   my ( $stream, $buffref, $eof ) = @_;

   if( $eof ) {
      while( my $on_result = shift @{ $self->{on_result_queue} } ) {
         $on_result->( $self, eof => );
      }
      $self->{on_eof}->( $self ) if $self->{on_eof};
      return;
   }

   return 0 unless length( $$buffref ) >= 4;
   my $len = unpack( "I", $$buffref );
   return 0 unless length( $$buffref ) >= 4 + $len;

   my $record = thaw( substr( $$buffref, 4, $len ) );
   substr( $$buffref, 0, 4 + $len ) = "";

   if( my $on_result = shift @{ $self->{on_result_queue} } ) {
      $on_result->( $self, recv => $record );
   }
   else {
      $self->{on_recv}->( $self, $record );
   }

   return 1;
}

sub _extract_read_handle
{
   my $self = shift;

   return undef if !$self->{mode};

   croak "Cannot extract filehandle" if $self->{mode} ne "async";
   $self->{mode} = "dead";

   return $self->{read_handle};
}

sub _extract_write_handle
{
   my $self = shift;

   return undef if !$self->{mode};

   croak "Cannot extract filehandle" if $self->{mode} ne "async";
   $self->{mode} = "dead";

   return $self->{write_handle};
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
