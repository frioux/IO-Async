#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2008 -- leonerd@leonerd.org.uk

package IO::Async::Stream;

use strict;

our $VERSION = '0.14_1';

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

 use IO::Async::Loop::IO_Poll;
 my $loop = IO::Async::Loop::IO_Poll->new();

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

This module provides a subclass of C<IO::Async::Notifier> which implements
asynchronous communications buffers around stream handles. It provides
buffering for both incoming and outgoing data, which are transferred to or
from the actual handle when it is read- or write-ready.

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

=head1 CONSTRUCTOR

=cut

=head2 $stream = IO::Async::Stream->new( %params )

This function returns a new instance of a C<IO::Async::Stream> object.
The C<%params> hash takes the following keys:

=over 8

=item read_handle => $handle

The IO handle to read from. Must implement C<fileno> and C<sysread> methods.

=item write_handle => $handle

The IO handle to write to. Must implement C<fileno> and C<syswrite> methods.

=item handle => $handle

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

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $self = $class->SUPER::new( %params );

   if( $params{handle} or $params{read_handle} ) {
      if( $params{on_read} ) {
         $self->{on_read} = $params{on_read};
      }
      elsif( $self->can( 'on_read' ) ) {
         # That's fine
      }
      else {
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

   while(1) {
      my $callback = $self->{current_on_read} || $self->{on_read};

      my $ret;

      if( defined $callback ) {
         $ret = $callback->( $self, \$self->{readbuff}, $handleclosed );
      }
      else {
         $ret = $self->on_read( \$self->{readbuff}, $handleclosed );
      }

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

   $self->close() if $handleclosed;
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
            $self->close();
         }

         return;
      }

      if( $len == 0 ) {
         $self->close();
         return;
      }

      substr( $self->{writebuff}, 0, $len ) = "";
   }

   # All data successfully flushed
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

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
