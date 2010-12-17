#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2010 -- leonerd@leonerd.org.uk

package IO::Async::Stream;

use strict;
use warnings;

our $VERSION = '0.32';

use base qw( IO::Async::Handle );

use POSIX qw( EAGAIN EWOULDBLOCK EINTR );

use Carp;

# Tuneable from outside
# Not yet documented
our $READLEN  = 8192;
our $WRITELEN = 8192;

=head1 NAME

C<IO::Async::Stream> - event callbacks and write bufering for a stream
filehandle

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

This subclass of L<IO::Async::Handle> contains a filehandle that represents
a byte-stream. It provides buffering for both incoming and outgoing data. It
invokes the C<on_read> handler when new data is read from the filehandle. Data
may be written to the filehandle by calling the C<write()> method.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters:

=head2 $ret = on_read \$buffer, $handleclosed

Invoked when more data is available in the internal receiving buffer.

The first argument is a reference to a plain perl string. The code should
inspect and remove any data it likes, but is not required to remove all, or
indeed any of the data. Any data remaining in the buffer will be preserved for
the next call, the next time more data is received from the handle.

In this way, it is easy to implement code that reads records of some form when
completed, but ignores partially-received records, until all the data is
present. If the handler is confident no more useful data remains, it should
return C<0>. If not, it should return C<1>, and the handler will be called
again. This makes it easy to implement code that handles multiple incoming
records at the same time. See the examples at the end of this documentation
for more detail.

The second argument is a scalar indicating whether the handle has been closed.
Normally it is false, but will become true once the handle closes. A reference
to the buffer is passed to the handler in the usual way, so it may inspect data
contained in it. Once the handler returns a false value, it will not be called
again, as the handle is now closed and no more data can arrive.

The C<on_read()> code may also dynamically replace itself with a new callback
by returning a CODE reference instead of C<0> or C<1>. The original callback
or method that the object first started with may be restored by returning
C<undef>. Whenever the callback is changed in this way, the new code is called
again; even if the read buffer is currently empty. See the examples at the end
of this documentation for more detail.

=head2 on_read_error $errno

Optional. Invoked when the C<sysread()> method on the read handle fails.

=head2 on_write_error $errno

Optional. Invoked when the C<syswrite()> method on the write handle fails.

The C<on_read_error> and C<on_write_error> handlers are passed the value of
C<$!> at the time the error occured. (The C<$!> variable itself, by its
nature, may have changed from the original error by the time this handler
runs so it should always use the value passed in).

If an error occurs when the corresponding error callback is not supplied, and
there is not a handler for it, then the C<close()> method is called instead.

=head2 on_outgoing_empty

Optional. Invoked when the writing data buffer becomes empty.

=cut

sub _init
{
   my $self = shift;

   $self->{writebuff} = "";
   $self->{readbuff} = "";

   $self->{read_len}  = $READLEN;
   $self->{write_len} = $WRITELEN;
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

=item on_read_error => CODE

=item on_outgoing_empty => CODE

=item on_write_error => CODE

CODE references for event handlers.

=item autoflush => BOOL

Optional. If true, the C<write> method will attempt to write data to the
operating system immediately, without waiting for the loop to indicate the
filehandle is write-ready. This is useful, for example, on streams that should
contain up-to-date logging or console information.

It currently defaults to false for any file handle, but future versions of
C<IO::Async> may enable this by default on STDOUT and STDERR.

=item read_len => INT

Optional. Sets the buffer size for C<read()> calls. Defaults to 8 KiBytes.

=item read_all => BOOL

Optional. If true, attempt to read as much data from the kernel as possible
when the handle becomes readable. By default this is turned off, meaning at
most one fixed-size buffer is read. If there is still more data in the
kernel's buffer, the handle will still be readable, and will be read from
again.

This behaviour allows multiple streams and sockets to be multiplexed
simultaneously, meaning that a large bulk transfer on one cannot starve other
filehandles of processing time. Turning this option on may improve bulk data
transfer rate, at the risk of delaying or stalling processing on other
filehandles.

=item write_len => INT

Optional. Sets the buffer size for C<write()> calls. Defaults to 8 KiBytes.

=item write_all => BOOL

Optional. Analogous to the C<read_all> option, but for writing. When
C<autoflush> is enabled, this option only affects deferred writing if the
initial attempt failed due to buffer space.

=back

If a read handle is given, it is required that either an C<on_read> callback
reference is configured, or that the object provides an C<on_read> method. It
is optional whether either is true for C<on_outgoing_empty>; if neither is
supplied then no action will be taken when the writing buffer becomes empty.

An C<on_read> handler may be supplied even if no read handle is yet given, to
be used when a read handle is eventually provided by the C<set_handles>
method.

This condition is checked at the time the object is added to a Loop; it is
allowed to create a C<IO::Async::Stream> object with a read handle but without
a C<on_read> handler, provided that one is later given using C<configure>
before the stream is added to its containing Loop, either directly or by being
a child of another Notifier already in a Loop, or added to one.

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   for (qw( on_read on_outgoing_empty on_read_error on_write_error
            autoflush read_len read_all write_len write_all )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->SUPER::configure( %params );

   if( $self->get_loop and $self->read_handle ) {
      $self->{on_read} or $self->can( "on_read" ) or
         croak 'Expected either an on_read callback or to be able to ->on_read';
   }
}

sub _add_to_loop
{
   my $self = shift;

   if( defined $self->read_handle ) {
      $self->{on_read} or $self->can( "on_read" ) or
         croak 'Expected either an on_read callback or to be able to ->on_read';
   }

   $self->SUPER::_add_to_loop( @_ );
}

=head1 METHODS

=cut

# FUNCTION not method
sub _nonfatal_error
{
   my ( $errno ) = @_;

   return $errno == EAGAIN ||
          $errno == EWOULDBLOCK ||
          $errno == EINTR;
}

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

This method adds data to the outgoing data queue, or writes it immediately,
according to the C<autoflush> parameter.

If the C<autoflush> option is set, this method will try immediately to write
the data to the underlying filehandle. If this completes successfully then it
will have been written by the time this method returns. If it fails to write
completely, then the data is queued as if C<autoflush> were not set, and will
be flushed as normal.

=cut

sub write
{
   my $self = shift;
   my ( $data ) = @_;

   carp "Cannot write data to a Stream that is closing" and return if $self->{stream_closing};
   croak "Cannot write data to a Stream with no write_handle" unless my $handle = $self->write_handle;

   if( $self->{autoflush} ) {
      $data = $self->{writebuff} . $data if length $self->{writebuff};

      while( length $data ) {
         my $len = $handle->syswrite( $data, $self->{write_len} );

         last if !$len; # stop on any errors and defer back to the non-autoflush path

         substr( $data, 0, $len ) = "";
      }

      if( !length $data ) {
         $self->want_writeready( 0 );
         return;
      }
   }

   $self->{writebuff} .= $data;

   $self->want_writeready( 1 );
}

sub on_read_ready
{
   my $self = shift;

   my $handle = $self->read_handle;

   while(1) {
      my $data;
      my $len = $handle->sysread( $data, $self->{read_len} );

      if( !defined $len ) {
         my $errno = $!;

         return if _nonfatal_error( $errno );

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

      $self->close_now, return if $handleclosed;

      last unless $self->{read_all};
   }
}

sub on_write_ready
{
   my $self = shift;

   my $handle = $self->write_handle;

   while( length $self->{writebuff} ) {
      my $len = $handle->syswrite( $self->{writebuff}, $self->{write_len} );

      if( !defined $len ) {
         my $errno = $!;

         return if _nonfatal_error( $errno );

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

      last unless $self->{write_all};
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

=head1 UTILITY CONSTRUCTORS

=cut

=head2 $stream = IO::Async::Stream->new_for_stdin

=head2 $stream = IO::Async::Stream->new_for_stdout

=head2 $stream = IO::Async::Stream->new_for_stdio

Return a C<IO::Async::Stream> object preconfigured with the correct
C<read_handle>, C<write_handle> or both.

=cut

sub new_for_stdin  { shift->new( read_handle  => \*STDIN, @_ ) }
sub new_for_stdout { shift->new( write_handle => \*STDOUT, @_ ) }

sub new_for_stdio { shift->new( read_handle => \*STDIN, write_handle => \*STDOUT, @_ ) }

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
