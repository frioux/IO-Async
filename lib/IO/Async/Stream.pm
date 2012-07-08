#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2012 -- leonerd@leonerd.org.uk

package IO::Async::Stream;

use strict;
use warnings;

our $VERSION = '0.52';

use base qw( IO::Async::Handle );

use Errno qw( EAGAIN EWOULDBLOCK EINTR EPIPE );

use Carp;

use Encode 2.11 qw( find_encoding STOP_AT_PARTIAL );

# Tuneable from outside
# Not yet documented
our $READLEN  = 8192;
our $WRITELEN = 8192;

# Indicies in writequeue elements
use constant WQ_DATA     => 0;
use constant WQ_ON_FLUSH => 1;
use constant WQ_GENSUB   => 2;

=head1 NAME

C<IO::Async::Stream> - event callbacks and write bufering for a stream
filehandle

=head1 SYNOPSIS

 use IO::Async::Stream;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 my $stream = IO::Async::Stream->new(
    read_handle  => \*STDIN,
    write_handle => \*STDOUT,

    on_read => sub {
       my ( $self, $buffref, $eof ) = @_;

       while( $$buffref =~ s/^(.*\n)// ) {
          print "Received a line $1";
       }

       if( $eof ) {
          print "EOF; last partial line is $$buffref\n";
       }

       return 0;
    }
 );

 $loop->add( $stream );

 $stream->write( "An initial line here\n" );

=head1 DESCRIPTION

This subclass of L<IO::Async::Handle> contains a filehandle that represents
a byte-stream. It provides buffering for both incoming and outgoing data. It
invokes the C<on_read> handler when new data is read from the filehandle. Data
may be written to the filehandle by calling the C<write> method.

For implementing real network protocols that are based on messages sent over a
byte-stream (such as a TCP socket), it may be more appropriate to use a
subclass of L<IO::Async::Protocol::Stream>.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters:

=head2 $ret = on_read \$buffer, $eof

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

The second argument is a scalar indicating whether the stream has reported an
end-of-file (EOF) condition. A reference to the buffer is passed to the
handler in the usual way, so it may inspect data contained in it. Once the
handler returns a false value, it will not be called again, as the handle is
now at EOF and no more data can arrive.

The C<on_read> code may also dynamically replace itself with a new callback
by returning a CODE reference instead of C<0> or C<1>. The original callback
or method that the object first started with may be restored by returning
C<undef>. Whenever the callback is changed in this way, the new code is called
again; even if the read buffer is currently empty. See the examples at the end
of this documentation for more detail.

=head2 on_read_eof

Optional. Invoked when the read handle indicates an end-of-file (EOF)
condition. If there is any data in the buffer still to be processed, the
C<on_read> event will be invoked first, before this one.

=head2 on_write_eof

Optional. Invoked when the write handle indicates an end-of-file (EOF)
condition. Note that this condition can only be detected after a C<write>
syscall returns the C<EPIPE> error. If there is no data pending to be written
then it will not be detected yet.

=head2 on_read_error $errno

Optional. Invoked when the C<sysread> method on the read handle fails.

=head2 on_write_error $errno

Optional. Invoked when the C<syswrite> method on the write handle fails.

The C<on_read_error> and C<on_write_error> handlers are passed the value of
C<$!> at the time the error occured. (The C<$!> variable itself, by its
nature, may have changed from the original error by the time this handler
runs so it should always use the value passed in).

If an error occurs when the corresponding error callback is not supplied, and
there is not a handler for it, then the C<close> method is called instead.

=head2 on_outgoing_empty

Optional. Invoked when the writing data buffer becomes empty.

=cut

sub _init
{
   my $self = shift;

   $self->{writequeue} = []; # Queue of ARRAYs. Each will be [ $data, $on_flushed, $gensub ]
   $self->{readbuff} = "";

   $self->{read_len}  = $READLEN;
   $self->{write_len} = $WRITELEN;

   $self->{close_on_read_eof} = 1;
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

Optional. Sets the buffer size for C<read> calls. Defaults to 8 KiBytes.

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

Optional. Sets the buffer size for C<write> calls. Defaults to 8 KiBytes.

=item write_all => BOOL

Optional. Analogous to the C<read_all> option, but for writing. When
C<autoflush> is enabled, this option only affects deferred writing if the
initial attempt failed due to buffer space.

=item close_on_read_eof => BOOL

Optional. Usually true, but if set to a false value then the stream will not
be C<close>d when an EOF condition occurs on read. This is normally not useful
as at that point the underlying stream filehandle is no longer useable, but it
may be useful for reading regular files, or interacting with TTY devices.

=item encoding => STRING

If supplied, sets the name of encoding of the underlying stream. If an
encoding is set, then the C<print> method will expect to receive Unicode
strings and encodes them into bytes, and incoming bytes will be decoded into
Unicode strings for the C<on_read> event.

If an encoding is not supplied then C<print> and C<on_read> will work in byte
strings.

I<IMPORTANT NOTE:> in order to handle reads of UTF-8 content or other
multibyte encodings, the code implementing the C<on_read> event uses a feature
of L<Encode>; the C<STOP_AT_PARTIAL> flag. While this flag has existed for a
while and is used by the C<:encoding> PerlIO layer itself for similar
purposes, the flag is not officially documented by the C<Encode> module. In
principle this undocumented feature could be subject to change, in practice I
believe it to be reasonably stable.

This note applies only to the C<on_read> event; data written using the
C<write> method does not rely on any undocumented features of C<Encode>.

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

   for (qw( on_read on_outgoing_empty on_read_eof on_write_eof on_read_error
            on_write_error autoflush read_len read_all write_len write_all
            close_on_read_eof )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   if( exists $params{encoding} ) {
      my $encoding = delete $params{encoding};
      my $obj = find_encoding( $encoding );
      defined $obj or croak "Cannot handle an encoding of '$encoding'";
      $self->{encoding} = $obj;
   }

   $self->SUPER::configure( %params );

   if( $self->loop and $self->read_handle ) {
      $self->can_event( "on_read" ) or
         croak 'Expected either an on_read callback or to be able to ->on_read';
   }
}

sub _add_to_loop
{
   my $self = shift;

   if( defined $self->read_handle ) {
      $self->can_event( "on_read" ) or
         croak 'Expected either an on_read callback or to be able to ->on_read';
   }

   $self->SUPER::_add_to_loop( @_ );

   if( !$self->_is_empty ) {
      $self->want_writeready( 1 );
   }
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

sub _is_empty
{
   my $self = shift;
   return !@{ $self->{writequeue} };
}

sub _flush_one
{
   my $self = shift;

   my $head = $self->{writequeue}[WQ_DATA];

   if( !defined $head->[WQ_DATA] ) {
      my $gensub = $head->[WQ_GENSUB] or die "Internal consistency problem - empty writequeue item without a gensub\n";
      $head->[WQ_DATA] = $gensub->( $self );

      if( !defined $head->[WQ_DATA] ) {
         $head->[WQ_ON_FLUSH]->( $self ) if $head->[WQ_ON_FLUSH];
         shift @{ $self->{writequeue} };

         return 1;
      }
   }

   my $len = $self->write_handle->syswrite( $head->[WQ_DATA], $self->{write_len} );

   if( !defined $len ) {
      my $errno = $!;

      return 0 if _nonfatal_error( $errno );

      $self->maybe_invoke_event( on_write_eof => ) if $errno == EPIPE;

      $self->maybe_invoke_event( on_write_error => $errno )
         or $self->close_now;

      return 0;
   }

   substr( $head->[WQ_DATA], 0, $len ) = "";

   if( !length $head->[WQ_DATA] ) {
      if( $head->[WQ_GENSUB] ) {
         undef $head->[WQ_DATA]; # We'll get some more next time around
      }
      else {
         $head->[WQ_ON_FLUSH]->( $self ) if $head->[WQ_ON_FLUSH];
         shift @{ $self->{writequeue} };
      }
   }

   return 1;
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

   return $self->SUPER::close if $self->_is_empty;

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

   undef @{ $self->{writequeue} };
   undef $self->{stream_closing};

   $self->SUPER::close;
}

=head2 $stream->write( $data, %params )

This method adds data to the outgoing data queue, or writes it immediately,
according to the C<autoflush> parameter.

If the C<autoflush> option is set, this method will try immediately to write
the data to the underlying filehandle. If this completes successfully then it
will have been written by the time this method returns. If it fails to write
completely, then the data is queued as if C<autoflush> were not set, and will
be flushed as normal.

C<$data> can either be a plain string, or a CODE reference. If it is a CODE
reference, it will be invoked to generate data to be written. Each time the
filehandle is ready to receive more data to it, the function is invoked, and
what it returns written to the filehandle. Once the function has finished
generating data it should return undef. The function is passed the Stream
object as its first argument.

For example, to stream the contents of an existing opened filehandle:

 open my $fileh, "<", $path or die "Cannot open $path - $!";

 $stream->write( sub {
    my ( $stream ) = @_;

    sysread $fileh, my $buffer, 8192 or return;
    return $buffer;
 } );

Takes the following optional named parameters in C<%params>:

=over 8

=item on_flush => CODE

A CODE reference which will be invoked once the data queued by this C<write>
call has been flushed. This will be invoked even if the buffer itself is not
yet empty; if more data has been queued since the call.

 $on_flush->( $stream )

=back

If the object is not yet a member of a loop and doesn't yet have a
C<write_handle>, then calls to the C<write> method will simply queue the data
and return. It will be flushed when the object is added to the loop.

If C<$data> is a defined but empty string, the write is still queued, and the
C<on_flush> continuation will be invoked, if supplied. This can be used to
obtain a marker, to invoke some code once the output queue has been flushed up
to this point.

=cut

sub write
{
   my $self = shift;
   my ( $data, %params ) = @_;

   carp "Cannot write data to a Stream that is closing" and return if $self->{stream_closing};

   # Allow writes without a filehandle if we're not yet in a Loop, just don't
   # try to flush them
   my $handle = $self->write_handle;

   croak "Cannot write data to a Stream with no write_handle" if !$handle and $self->loop;

   if( my $encoding = $self->{encoding} ) {
      $data = $encoding->encode( $data );
   }

   # Combine short writes we can
   my $tail = @{ $self->{writequeue} } ? $self->{writequeue}[-1] : undef;

   if( $tail and
       !ref $data and
       !$tail->[WQ_GENSUB] and
       length($data) + length($tail->[WQ_DATA]) < $self->{write_len} and
       !$params{on_flush} and
       !$tail->[WQ_ON_FLUSH]) {
      $tail->[WQ_DATA] .= $data;
   }
   else {
      push @{ $self->{writequeue} }, my $elem = [];

      if( ref $data eq "CODE" ) {
         $elem->[WQ_GENSUB] = $data;
      }
      else {
         $elem->[WQ_DATA] = $data;
      }

      $elem->[WQ_ON_FLUSH] = delete $params{on_flush};
   }

   keys %params and croak "Unrecognised keys for ->write - " . join( ", ", keys %params );

   return unless $handle;

   if( $self->{autoflush} ) {
      1 while !$self->_is_empty and $self->_flush_one;

      if( $self->_is_empty ) {
         $self->want_writeready( 0 );
         return;
      }
   }

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

         $self->maybe_invoke_event( on_read_error => $errno )
            or $self->close_now;

         return;
      }

      my $eof = ( $len == 0 );

      if( my $encoding = $self->{encoding} ) {
         my $bytes = defined $self->{bytes_remaining} ? $self->{bytes_remaining} . $data : $data;
         $data = $encoding->decode( $bytes, STOP_AT_PARTIAL );
         $self->{bytes_remaining} = $bytes;
      }

      $self->{readbuff} .= $data if !$eof;

      while(1) {
         my $ret;
         if( my $on_read = $self->{current_on_read} ) {
            $ret = $on_read->( $self, \$self->{readbuff}, $eof );
         }
         else {
            $ret = $self->invoke_event( on_read => \$self->{readbuff}, $eof );
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
            $again = $ret && ( length( $self->{readbuff} ) > 0 || $eof );
         }

         last if !$again;
      }

      if( $eof ) {
         $self->maybe_invoke_event( on_read_eof => );
         $self->close_now if $self->{close_on_read_eof};
         return;
      }

      last unless $self->{read_all};
   }
}

sub on_write_ready
{
   my $self = shift;

   1 while !$self->_is_empty and $self->_flush_one and $self->{write_all};

   # All data successfully flushed
   if( $self->_is_empty ) {
      $self->want_writeready( 0 );

      $self->maybe_invoke_event( on_outgoing_empty => );

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

=head1 EXAMPLES

=head2 A line-based C<on_read> method

The following C<on_read> method accepts incoming C<\n>-terminated lines and
prints them to the program's C<STDOUT> stream.

 sub on_read
 {
    my $self = shift;
    my ( $buffref, $eof ) = @_;

    while( $$buffref =~ s/^(.*\n)// ) {
       print "Received a line: $1";
    }

    return 0;
 }

Because a reference to the buffer itself is passed, it is simple to use a
C<s///> regular expression on the scalar it points at, to both check if data
is ready (i.e. a whole line), and to remove it from the buffer. If no data is
available then C<0> is returned, to indicate it should not be tried again. If
a line was successfully extracted, then C<1> is returned, to indicate it
should try again in case more lines exist in the buffer.

For implementing real network protocols that are based on lines of text it may
be more appropriate to use a subclass of L<IO::Async::Protocol::LineStream>.

=head2 Reading binary data

This C<on_read> method accepts incoming records in 16-byte chunks, printing
each one.

 sub on_read
 {
    my ( $self, $buffref, $eof ) = @_;

    if( length $$buffref >= 16 ) {
       my $record = substr( $$buffref, 0, 16, "" );
       print "Received a 16-byte record: $record\n";

       return 1;
    }

    if( $eof and length $$buffref ) {
       print "EOF: a partial record still exists\n";
    }

    return 0;
 }

The 4-argument form of C<substr()> extracts the 16-byte record from the buffer
and assigns it to the C<$record> variable, if there was enough data in the
buffer to extract it.

A lot of protocols use a fixed-size header, followed by a variable-sized body
of data, whose size is given by one of the fields of the header. The following
C<on_read> method extracts messages in such a protocol.

 sub on_read
 {
    my ( $self, $buffref, $eof ) = @_;

    return 0 unless length $$buffref >= 8; # "N n n" consumes 8 bytes

    my ( $len, $x, $y ) = unpack $$buffref, "N n n";

    return 0 unless length $$buffref >= 8 + $len;

    substr( $$buffref, 0, 8, "" );
    my $data = substr( $$buffref, 0, $len, "" );

    print "A record with values x=$x y=$y\n";

    return 1;
 }

In this example, the header is C<unpack()>ed first, to extract the body
length, and then the body is extracted. If the buffer does not have enough
data yet for a complete message then C<0> is returned, and the buffer is left
unmodified for next time. Only when there are enough bytes in total does it
use C<substr()> to remove them.

=head2 Dynamic replacement of C<on_read>

Consider the following protocol (inspired by IMAP), which consists of
C<\n>-terminated lines that may have an optional data block attached. The
presence of such a data block, as well as its size, is indicated by the line
prefix.

 sub on_read
 {
    my $self = shift;
    my ( $buffref, $eof ) = @_;

    if( $$buffref =~ s/^DATA (\d+):(.*)\n// ) {
       my $length = $1;
       my $line   = $2;

       return sub {
          my $self = shift;
          my ( $buffref, $eof ) = @_;

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

In the case where trailing data is supplied, a new temporary C<on_read>
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

=cut

0x55AA;
