#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011 -- leonerd@leonerd.org.uk

package IO::Async::FileStream;

use strict;
use warnings;

our $VERSION = '0.39';

use base qw( IO::Async::Stream );

use IO::Async::Timer::Periodic;

use Carp;
use Fcntl qw( SEEK_SET SEEK_CUR );

=head1 NAME

C<IO::Async::FileStream> - read the tail of a file

=head1 SYNOPSIS

 use IO::Async::FileStream;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 open my $logh, "<", "var/logs/daemon.log" or die "Cannot open logfile - $!";

 my $filestream = IO::Async::FileStream->new(
    read_handle => $logh,

    on_read => sub {
       my ( $self, $buffref ) = @_;

       if( $$buffref =~ s/^(.*\n)// ) {
          print "Received a line $1";

          return 1;
       }
    },
 );

 $loop->add( $filestream );

 $loop->loop_forever;

=head1 DESCRIPTION

This subclass of L<IO::Async::Stream> allows reading the end of a regular file
which is being appended to by some other process. It invokes the C<on_read>
event when more data has been added to the file. 

This class provides an API identical to C<IO::Async::Stream> when given a
C<read_handle>; it should be treated similarly. In particular, it can be given
an C<on_read> handler, or subclassed to provide an C<on_read> method, or even
used as the C<transport> for an C<IO::Async::Protocol::Stream> object.

It will not support writing.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters.

Because this is a subclass of L<IO::Async::Stream> in read-only mode, all the
events supported by C<Stream> relating to the read handle are supported here.
This is not a full list; see also the documentation relating to
C<IO::Async::Stream>.

=head2 $ret = on_read \$buffer, $eof

Invoked when more data is available in the internal receiving buffer.

Note that C<$eof> only indicates that all the data currently available in the
file has now been read; in contrast to a regular C<IO::Async::Stream>, this
object will not stop watching after this condition. Instead, it will continue
watching the file for updates.

=head2 on_truncated

Invoked when the file size shrinks. If this happens, it is presumed that the
file content has been replaced. Reading will then commence from the start of
the file.

=head2 on_initial $size

Invoked the first time the file is looked at. It is passed the initial size of
the file.

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;

   $self->SUPER::_init( $params );

   $self->add_child( $self->{timer} = IO::Async::Timer::Periodic->new(
      interval => 2,
      on_tick => $self->_capture_weakself( 'on_tick' ),
   ) );

   $params->{close_on_read_eof} = 0;

   $self->{last_pos} = 0;
   $self->{last_size} = undef;
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>, in
addition to the parameters relating to reading supported by
C<IO::Async::Stream>.

=over 8

=item interval => NUM

Optional. The interval in seconds to poll the filehandle using C<stat(2)>
looking for size changes. A default of 2 seconds will be applied if not
defined.

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( on_truncated on_initial )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   foreach (qw( interval )) {
      $self->{timer}->configure( $_ => delete $params{$_} ) if exists $params{$_};
   }

   croak "Cannot have a write_handle in a ".ref($self) if defined $params{write_handle};

   $self->SUPER::configure( %params );

   if( $self->read_handle and !defined $self->{last_size} ) {
      $self->_do_initial;
   }
}

=head1 METHODS

=cut

# Replace IO::Async::Handle's implementation
sub _watch_read
{
   my $self = shift;
   my ( $want ) = @_;

   if( $want ) {
      $self->{timer}->start if !$self->{timer}->is_running;
   }
   else {
      $self->{timer}->stop;
   }
}

sub _watch_write
{
   my $self = shift;
   my ( $want ) = @_;

   croak "Cannot _watch_write in " . ref($self) if $want;
}

sub _do_initial
{
   my $self = shift;

   my $size = (stat $self->read_handle)[7];

   $self->maybe_invoke_event( on_initial => $size );

   $self->{last_size} = $size;
}

sub on_tick
{
   my $self = shift;

   my $size = (stat $self->read_handle)[7];

   if( $size < $self->{last_size} ) {
      $self->maybe_invoke_event( on_truncated => );
      $self->{last_pos} = 0;
   }
   elsif( $size == $self->{last_size} ) {
      return;
   }

   $self->{last_size} = $size;

   $self->read_more;
}

sub read_more
{
   my $self = shift;

   sysseek( $self->read_handle, $self->{last_pos}, SEEK_SET );

   $self->on_read_ready;

   $self->{last_pos} = sysseek( $self->read_handle, 0, SEEK_CUR ); # == systell

   if( $self->{last_pos} < $self->{last_size} ) {
      $self->get_loop->later( sub { $self->read_more } );
   }
}

sub write
{
   carp "Cannot ->write from a ".ref($_[0]);
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
