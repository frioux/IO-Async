#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006,2007 -- leonerd@leonerd.org.uk

package IO::Async::Stream;

use strict;

our $VERSION = '0.11';

use base qw( IO::Async::Notifier );

use POSIX qw( EAGAIN EWOULDBLOCK );

use Carp;

# Tuneable from outside
# Not yet documented
our $READLEN  = 8192;
our $WRITELEN = 8192;

=head1 NAME

C<IO::Async::Stream> - read and write buffers around an IO handle

=head1 SYNOPSIS

 use IO::Socket::INET;
 use IO::Async::Stream;

 my $socket = IO::Socket::INET->new(
    PeerHost => "some.other.host",
    PeerPort => 12345,
    Blocking => 0,                   # This line is very important
 );

 my $stream = IO::Async::Stream->new(
    handle => $socket,

    on_read => sub {
       my ( $self, $buffref, $closed ) = @_;

       if( $$buffref =~ s/^(.*\n)// ) {
          print "Received a line $1";

          return 1;
       }

       if( $closed ) {
          print "Closed; last partial line is $$buffref\n";
       }

       return 0;
    }
 );

 $stream->write( "An initial line here\n" );

 my $loop = IO::Async::Loop::...
 $loop->add( $stream );

Or

 my $record_stream = IO::Async::Stream->new(
    handle => ...,

    on_read => sub {
       my ( $self, $buffref, $closed ) = @_;

       if( length $$buffref >= 16 ) {
          my $record = substr( $$buffref, 0, 16, "" );
          print "Received a 16-byte record: $record\n";

          return 1;
       }

       if( $closed and length $$buffref ) {
          print "Closed: a partial record still exists\n";
       }

       return 0;
    }
 );

Or

 use IO::Handle;

 my $stream = IO::Async::Stream->new(
    read_handle  => \*STDIN,
    write_handle => \*STDOUT,
    ...
 );

=head1 DESCRIPTION

This module provides a class for implementing asynchronous communications
buffers behind stream handles. It provides buffering for both incoming and
outgoing data, which are transferred to or from the actual handle as
appropriate.

Data can be added to the outgoing buffer at any time using the C<write()>
method, and will be flushed whenever the underlying handle is notified as
being write-ready. Whenever the handle is notified as being read-ready, the
data is read in from the handle, and the C<on_read> code is called to indicate
the data is available.

This object may be used in one of two ways; with a callback function, or as a
base class.

=over 4

=item Callbacks

If certain keys are supplied to the constructor, they should contain CODE
references to callback functions that will be called in the following manner:

 $again = $on_read->( $self, \$buffer, $handleclosed )

 $on_read_error->( $self, $errno )

 $on_outgoing_empty->( $self )

 $on_write_error->( $self, $errno )

A reference to the calling C<IO::Async::Stream> object is passed as the first
argument, so that the callback can access it.

=item Base Class

If a subclass is built, then it can override the C<on_read> or
C<on_outgoing_empty> methods, which will be called in the following manner:

 $again = $self->on_read( \$buffer, $handleclosed )

 $self->on_read_error( $errno )

 $self->on_outgoing_empty()

 $self->on_write_error( $errno )

=back

The first argument to the C<on_read()> callback is a reference to a plain perl
string. The code should inspect and remove any data it likes, but is not
required to remove all, or indeed any of the data. Any data remaining in the
buffer will be preserved for the next call, the next time more data is
received from the handle.

In this way, it is easy to implement code that reads records of some form when
completed, but ignores partially-received records, until all the data is
present. If the method is confident no more useful data remains, it should
return a false value. If not, it should return a true value, and the method
will be called again. This makes it easy to implement code that handles
multiple incoming records at the same time. See the examples at the end of
this documentation for more detail.

The second argument to the C<on_read()> method is a scalar indicating whether
the handle has been closed. Normally it is false, but will become true once
the handle closes. A reference to the buffer is passed to the method in the
usual way, so it may inspect data contained in it. Once the method returns a
false value, it will not be called again, as the handle is now closed and no
more data can arrive.

The C<on_read_error> and C<on_write_error> callbacks are passed the value of
C<$!> at the time the error occured. (The C<$!> variable itself, by its
nature, may have changed from the original error by the time this callback
runs so it should always use the value passed in).

If an error occurs when the corresponding error callback is not supplied, and
there is not a subclass method for it, then the C<close()> method is
called instead.

The C<on_outgoing_empty> callback is not passed any arguments.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $stream = IO::Async::Stream->new( %params )

This function returns a new instance of a C<IO::Async::Stream> object.
The C<%params> hash takes the following keys:

=over 8

=item handle => $handle

The handle object to wrap. Must implement C<fileno>, C<sysread> and
C<syswrite> methods in the way that C<IO::Handle> does.

=item on_read => CODE

A CODE reference for when more data is available in the internal receiving 
buffer.

=item on_read_error => CODE

A CODE reference for when the C<sysread()> method on the read handle fails.

=item on_outgoing_empty => CODE

A CODE reference for when the writing data buffer becomes empty.

=item on_write_error => CODE

A CODE reference for when the C<syswrite()> method on the write handle fails.

=back

It is required that either an C<on_read> callback reference is passed, or that
the object provides an C<on_read> method. It is optional whether either is
true for C<on_outgoing_empty>; if neither is supplied then no action will be
taken when the writing buffer becomes empty.

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $self = $class->SUPER::new( %params );

   if( $params{on_read} ) {
      $self->{on_read} = $params{on_read};
   }
   else {
      unless( $self->can( 'on_read' ) ) {
         croak 'Expected either an on_read callback or to be able to ->on_read';
      }
   }

   for (qw( on_outgoing_empty on_read_error on_write_error )) {
      $self->{$_} = $params{$_} if $params{$_};
   }

   $self->{writebuff} = "";
   $self->{readbuff} = "";

   return $self;
}

=head1 METHODS

=cut

sub close
{
   my $self = shift;

   return $self->SUPER::close if length( $self->{writebuff} ) == 0;

   $self->{closing} = 1;
}

=head2 $stream->write( $data )

This method adds data to the outgoing data queue. The data is not yet sent to
the handle; this will be done later in the C<on_write_ready()> method.

=over 8

=item $data

A scalar containing data to write

=back

=cut

sub write
{
   my $self = shift;
   my ( $data ) = @_;

   carp "Cannot write data to a Stream that is closing", return if $self->{closing};

   $self->{writebuff} .= $data;

   $self->want_writeready( 1 );
}

# protected
sub on_read_ready
{
   my $self = shift;

   my $handle = $self->read_handle;

   my $data;
   my $len = $handle->sysread( $data, $READLEN );

   if( !defined $len ) {
      my $errno = $!;

      return if $errno == EAGAIN or $errno == EWOULDBLOCK;

      if( defined $self->{on_read_error} ) {
         $self->{on_read_error}->( $self, $errno );
      }
      elsif( $self->can( "on_read_error" ) ) {
         $self->on_read_error( $errno );
      }
      else {
         $self->close();
      }

      return;
   }

   my $handleclosed = ( $len == 0 );

   $self->{readbuff} .= $data if( !$handleclosed );
   my $callback = $self->{on_read};
   while( length( $self->{readbuff} ) > 0 || $handleclosed ) {
      my $again;

      if( defined $callback ) {
         $again = $callback->( $self, \$self->{readbuff}, $handleclosed );
      }
      else {
         $again = $self->on_read( \$self->{readbuff}, $handleclosed );
      }

      last if !$again;
   }

   $self->close() if $handleclosed;
}

# protected
sub on_write_ready
{
   my $self = shift;

   my $handle = $self->write_handle;

   my $len = length( $self->{writebuff} );
   $len = $WRITELEN if( $len > $WRITELEN );

   my $data = substr( $self->{writebuff}, 0, $len );

   $len = $handle->syswrite( $data );

   if( !defined $len ) {
      my $errno = $!;

      return if $errno == EAGAIN or $errno == EWOULDBLOCK;

      if( defined $self->{on_read_error} ) {
         $self->{on_write_error}->( $self, $errno );
      }
      elsif( $self->can( "on_write_error" ) ) {
         $self->on_write_error( $errno );
      }
      else {
         $self->close();
      }

      return;
   }

   if( $len == 0 ) {
      $self->close();
   }
   else {
      substr( $self->{writebuff}, 0, $len ) = "";

      if( length( $self->{writebuff} ) == 0 ) {
         $self->want_writeready( 0 );

         if( defined( my $callback = $self->{on_outgoing_empty} ) ) {
            $callback->( $self );
         }
         elsif( $self->can( 'on_outgoing_empty' ) ) {
            $self->on_outgoing_empty();
         }

         $self->close if $self->{closing};
      }
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 EXAMPLES

=head2 A line-based C<on_read()> method

The following C<on_read()> method accepts incoming 'C<\n>'-terminated lines
and prints them to the program's C<STDOUT> stream.

 sub on_read
 {
    my $self = shift;
    my ( $buffref, $handleclosed ) = @_;

    if( $$buffref =~ s/^(.*\n)// ) {
       print "Received a line: $1";
       return 1;
    }

    return 0;
 }

Because a reference to the buffer itself is passed, it is simple to use a
C<s///> regular expression on the scalar it points at, to both check if data
is ready (i.e. a whole line), and to remove it from the buffer. If no data is
available then C<0> is returned, to indicate it should not be tried again. If
a line was successfully extracted, then C<1> is returned, to indicate it
should try again in case more lines exist in the buffer.

=head1 SEE ALSO

=over 4

=item *

L<IO::Handle> - Supply object methods for I/O handles

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
