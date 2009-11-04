#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2009 -- leonerd@leonerd.org.uk

package IO::Async::Stream;

use strict;
use warnings;

our $VERSION = '0.25';

use base qw( IO::Async::Handle );

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

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

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

This module provides a subclass of C<IO::Async::Handle> which implements
asynchronous communications buffers around stream handles. It provides
buffering for both incoming and outgoing data, which are transferred to or
from the actual OS-level filehandle as controlled by the containing Loop.

Data can be added to the outgoing buffer at any time using the C<write()>
method, and will be flushed whenever the underlying handle is notified as
being write-ready. Whenever the handle is notified as being read-ready, the
data is read in from the handle, and the C<on_read> code is called to indicate
the data is available. The code can then inspect the buffer and possibly
consume any input it considers ready.

This object may be used in one of two ways; with a callback function, or as a
base class.

=over 4

=item Callbacks

If certain keys are supplied to the constructor, they should contain CODE
references to callback functions that will be called in the following manner:

 $ret = $on_read->( $self, \$buffer, $handleclosed )

 $on_read_error->( $self, $errno )

 $on_outgoing_empty->( $self )

 $on_write_error->( $self, $errno )

A reference to the calling C<IO::Async::Stream> object is passed as the first
argument, so that the callback can access it.

=item Base Class

If a subclass is built, then it can override the C<on_read> or
C<on_outgoing_empty> methods, which will be called in the following manner:

 $ret = $self->on_read( \$buffer, $handleclosed )

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
return C<0>. If not, it should return C<1>, and the method will be called
again. This makes it easy to implement code that handles multiple incoming
records at the same time. See the examples at the end of this documentation
for more detail.

The second argument to the C<on_read()> method is a scalar indicating whether
the handle has been closed. Normally it is false, but will become true once
the handle closes. A reference to the buffer is passed to the method in the
usual way, so it may inspect data contained in it. Once the method returns a
false value, it will not be called again, as the handle is now closed and no
more data can arrive.

The C<on_read()> code may also dynamically replace itself with a new callback
by returning a CODE reference instead of C<0> or C<1>. The original callback
or method that the object first started with may be restored by returning
C<undef>. Whenever the callback is changed in this way, the new code is called
again; even if the read buffer is currently empty. See the examples at the end
of this documentation for more detail.

The C<on_read_error> and C<on_write_error> callbacks are passed the value of
C<$!> at the time the error occured. (The C<$!> variable itself, by its
nature, may have changed from the original error by the time this callback
runs so it should always use the value passed in).

If an error occurs when the corresponding error callback is not supplied, and
there is not a subclass method for it, then the C<close()> method is
called instead.

The C<on_outgoing_empty> callback is not passed any arguments.

=cut

sub _init
{
   my $self = shift;

   $self->{writebuff} = "";
   $self->{readbuff} = "";
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item read_handle => IO

The IO handle to read from. Must implement C<fileno> and C<sysread> methods.

=item write_handle => IO

The IO handle to write to. Must implement C<fileno> and C<syswrite> methods.

=item handle => IO

Shortcut to specifying the same IO handle for both of the above.

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

If a read handle is given, it is required that either an C<on_read> callback
reference is passed, or that the object provides an C<on_read> method. It is
optional whether either is true for C<on_outgoing_empty>; if neither is
supplied then no action will be taken when the writing buffer becomes empty.

An C<on_read> callback may be supplied even if no read handle is yet given, to
be used when a read handle is eventually provided by the C<set_handles>
method.

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   for (qw( on_read on_outgoing_empty on_read_error on_write_error )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->SUPER::configure( %params );

   if( defined $self->read_handle ) {
      $self->{on_read} or $self->can( "on_read" ) or
         croak 'Expected either an on_read callback or to be able to ->on_read';
   }
}

=head1 METHODS

=cut

=head2 $stream->close

A synonym for C<close_when_empty>. This should not be used when the deferred
wait behaviour is required, as the behaviour of C<close> may change in a
future version of C<IO::Async>. Instead, call C<close_when_empty> directly.

=cut

sub close
{
   my $self = shift;
   $self->close_when_empty;
}

=head2 $stream->close_when_empty

If the write buffer is empty, this method calls C<close> on the underlying IO
handles, and removes the stream from its containing loop. If the write buffer
still contains data, then this is deferred until the buffer is empty. This is
intended for "write-then-close" one-shot streams.

 $stream->write( "Here is my final data\n" );
 $stream->close_when_empty;

Because of this deferred nature, it may not be suitable for error handling.
See instead the C<close_now> method.

=cut

sub close_when_empty
{
   my $self = shift;

   return $self->SUPER::close if length( $self->{writebuff} ) == 0;

   $self->{stream_closing} = 1;
}

=head2 $stream->close_now

This method immediately closes the underlying IO handles and removes the
stream from the containing loop. It will not wait to flush the remaining data
in the write buffer.

=cut

sub close_now
{
   my $self = shift;

   $self->{writebuff} = "";
   undef $self->{stream_closing};

   $self->SUPER::close;
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

   carp "Cannot write data to a Stream that is closing" and return if $self->{stream_closing};
   croak "Cannot write data to a Stream with no write_handle" unless $self->write_handle;

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
         $self->close_now;
      }

      return;
   }

   my $handleclosed = ( $len == 0 );

   $self->{readbuff} .= $data if( !$handleclosed );

   while(1) {
      my $on_read = $self->{current_on_read}
                     || $self->{on_read}
                     || $self->can( "on_read" );

      my $ret = $on_read->( $self, \$self->{readbuff}, $handleclosed );

      my $again;

      if( ref $ret eq "CODE" ) {
         $self->{current_on_read} = $ret;
         $again = 1;
      }
      elsif( $self->{current_on_read} and !defined $ret ) {
         undef $self->{current_on_read};
         $again = 1;
      }
      else {
         $again = $ret && ( length( $self->{readbuff} ) > 0 || $handleclosed );
      }

      last if !$again;
   }

   $self->close_now if $handleclosed;
}

# protected
sub on_write_ready
{
   my $self = shift;

   my $handle = $self->write_handle;

   while( length $self->{writebuff} ) {
      my $len = $handle->syswrite( $self->{writebuff}, $WRITELEN );

      if( !defined $len ) {
         my $errno = $!;

         return if $errno == EAGAIN or $errno == EWOULDBLOCK;

         if( defined $self->{on_write_error} ) {
            $self->{on_write_error}->( $self, $errno );
         }
         elsif( $self->can( "on_write_error" ) ) {
            $self->on_write_error( $errno );
         }
         else {
            $self->close_now;
         }

         return;
      }

      if( $len == 0 ) {
         $self->close_now;
         return;
      }

      substr( $self->{writebuff}, 0, $len ) = "";
   }

   # All data successfully flushed
   if( length( $self->{writebuff} ) == 0 ) {
      $self->want_writeready( 0 );

      my $on_outgoing_empty = $self->{on_outgoing_empty}
                               || $self->can( "on_outgoing_empty" );

      $on_outgoing_empty->( $self ) if $on_outgoing_empty;

      $self->close_now if $self->{stream_closing};
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 EXAMPLES

=head2 A line-based C<on_read()> method

The following C<on_read()> method accepts incoming C<\n>-terminated lines and
prints them to the program's C<STDOUT> stream.

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

=head2 Dynamic replacement of C<on_read()>

Consider the following protocol (inspired by IMAP), which consists of
C<\n>-terminated lines that may have an optional data block attached. The
presence of such a data block, as well as its size, is indicated by the line
prefix.

 sub on_read
 {
    my $self = shift;
    my ( $buffref, $handleclosed ) = @_;

    if( $$buffref =~ s/^DATA (\d+):(.*)\n// ) {
       my $length = $1;
       my $line   = $2;

       return sub {
          my $self = shift;
          my ( $buffref, $handleclosed ) = @_;

          return 0 unless length $$buffref >= $length;

          # Take and remove the data from the buffer
          my $data = substr( $$buffref, 0, $length, "" );

          print "Received a line $line with some data ($data)\n";

          return undef; # Restore the original method
       }
    }
    elsif( $$buffref =~ s/^LINE:(.*)\n// ) {
       my $line = $1;

       print "Received a line $line with no data\n";

       return 1;
    }
    else {
       print STDERR "Unrecognised input\n";
       # Handle it somehow
    }
 }

In the case where trailing data is supplied, a new temporary C<on_read()>
callback is provided in a closure. This closure captures the C<$length>
variable so it knows how much data to expect. It also captures the C<$line>
variable so it can use it in the event report. When this method has finished
reading the data, it reports the event, then restores the original method by
returning C<undef>.

=head1 SEE ALSO

=over 4

=item *

L<IO::Handle> - Supply object methods for I/O handles

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
