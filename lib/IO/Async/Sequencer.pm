#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2011 -- leonerd@leonerd.org.uk

package IO::Async::Sequencer;

use strict;
use warnings;

our $VERSION = '0.45';

use base qw( IO::Async::Stream );

use Carp;

=head1 NAME

C<IO::Async::Sequencer> - handle a serial pipeline of requests / responses (EXPERIMENTAL)

=head1 SYNOPSIS

When used as a client:

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 my $sock = ...

 my $sequencer = IO::Async::Sequencer->new(
    handle => $sock,

    on_read => sub {
       my ( $self, $buffref, $eof ) = @_;

       return 0 unless $$buffref =~ s/^(.*)\n//;
       my $line = $1;

       $line =~ m/^RESPONSE (.*)$/ and
          $self->incoming_response( $1 ), return 1;

       print STDERR "An error - didn't recognise the line $line\n";
    },

    marshall_request => sub {
       my ( $self, $request ) = @_;
       return "REQUEST $request\n";
    },
 );

 $loop->add( $sequencer );

 $sequencer->request(
    request     => "hello",
    on_response => sub {
       my ( $response ) = @_;
       print "The response is: $response\n";
    },
 );

When used as a server:

 my $sequencer = IO::Async::Sequencer->new(
    handle => $sock,

    on_read => sub {
       my ( $self, $buffref, $eof ) = @_;

       return 0 unless $$buffref =~ s/^(.*)\n//;
       my $line = $1;

       $line =~ m/^REQUEST (.*)$/ and
          $self->incoming_request( $1 ), return 1;

       print STDERR "An error - didn't recognise the line $line\n";
    },

    on_request => sub {
       my ( $self, $token, $request ) = @_;

       # Now to invoke the application logic, whatever it may be
       solve_request(
          request      => $request,
          on_completed => sub {
             my ( $response ) = @_;
             $self->respond( $token, $response );
          }
       );
    },

    marshall_response => sub {
       my ( $self, $response ) = @_;
       return "RESPONSE $response\n";
    },
 );

=head1 DESCRIPTION

This module provides an EXPERIMENTAL subclass of C<IO::Async::Stream> which
may be helpful in implementing serial pipeline-based network protocols of
requests and responses. It deals with low-level details such as pairing up
responses to requests in ordered protocols, and allows a convenient location
to store the line stream marshalling and demarshalling code.

The intention is that individual network protocols may be implemented as a
subclass of this class, providing the marshalling and demarshalling code
itself, providing a clean implementation to be used by the using code. An
example protocol that would be easy to implement in this way would be HTTP.

Objects in this class can operate in any of three ways:

=over 4

=item * A pure client

The object is asked to send requests by the containing code and invokes
response handling code when responses arrive.

=item * A pure server

The object receives requests from the filehandle, processes them, and sends
responses back, but does not initiate any traffic of its own.

=item * Mixed

The object behaves as a mixture of the two; initiating requests, as well as
responding to those of its peer connection.

=back

The exact mode of operation of any object is not declared explicitly, but
instead is an artefact of the set of callbacks provided to the constructor or
methods defined by the subclass. Certain callbacks or methods only make sense
for one mode or the other.

The various operations required can each be provided as callback functions
given in keys to the constructor, or as object methods on a subclass of this
class. Keys passed to the constructor will take precidence over defined
methods.

As it is still EXPERIMENTAL, any details of this class are liable to change in
future versions. It shouldn't yet be relied upon as a stable interface.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_read => CODE

As for L<IO::Async::Stream>. The code here should invoke the
C<incoming_request> or C<incoming_response> methods when appropriate,
after having parsed the incoming stream. See the SYNOPSIS or EXAMPLES sections
for more detail.

Each request can optionally provide its own handler for reading its response,
using the C<on_read> key to the C<request> method. The handler provided to
the constructor is only used if this is not provided.

=item on_request => CODE

A callback that is invoked when the C<incoming_request> method is called
(i.e. when operating in server mode). It is passed the request, and a token to
identify it when sending a response.

 $on_request->( $self, $token, $request );

The token should be considered as an opaque value - passed into the
C<respond> method when a response is ready, but not otherwise used or
modified.

=item marshall_request => CODE

=item marshall_response => CODE

Callbacks that the C<request> or C<respond> methods will use,
respectively, to stream a request or response object into a string of bytes to
write to the underlying file handle.

 $string = $marshall_request->( $self, $request );

 $string = $marshall_response->( $self, $response );

These are used respectively by the client and server modes.

=item pipeline => BOOL

Optional. Controls whether requests will be pipelined; that is, all requests
will be sent by the client before responses are received. If this option is
disabled, only the first request will be sent. Other requests will be queued
internally, and each will be sent when the response to the previous has been
received. Defaults enabled; supply a defined but false value to disable.

=back

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;

   $self->SUPER::_init( @_ );

   $self->{pipeline} = 1; # default on

   # Queue to use in server mode - stores pending responses to be sent
   $self->{server_queue} = []; # element is: $streamed_response

   # Queue to use in client mode - stores pending on_response handlers to be called
   $self->{client_queue} = []; # element is: [ $on_response, $delegated_on_read ]

   my $on_read = delete $params->{on_read} || $self->can( "on_read" );

   # Since our ->configure has banned 'on_read', we need to call SUPER one from here
   $self->SUPER::configure(
      on_read => sub {
         my ( $self, $buffref, $eof ) = @_;

         my $front = $self->{client_queue}[0];

         if( !$self->{pipeline} and $front and defined $front->[2] ) {
            # Next request needs sending
            $self->write( $front->[2] );
            undef $front->[2];
         }

         if( $front and $front->[1] ) {
            # Delegate to the one provided by the request
            my $delegated_on_read = $front->[1];
            shift @{ $self->{client_queue} };
            return $delegated_on_read;
         }

         # Perhaps we got switched back after delegated handler returned undef
         return 0 unless length $$buffref;

         # No delegation to perform, instead just call the provided one
         goto &$on_read;
      },
   );
}

sub configure
{
   my $self = shift;
   my %params = @_;

   if( exists $params{on_read} ) {
      croak "Cannot modify 'on_read' of a " . __PACKAGE__;
   }

   foreach (qw( marshall_request marshall_response on_request )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   if( exists $params{pipeline} ) {
      $self->{pipeline} = !!delete $params{pipeline};
   }

   $self->SUPER::configure( %params );
}

=head1 SUBCLASS METHODS

This class is intended as a base class for building specific protocol handling
code on top of. These methods are intended to be called by the specific
subclass, rather than the containing application code.

=cut

=head2 $sequencer->incoming_request( $request )

To be called from C<on_read>.

This method informs the sequencer that a new request has arrived. It will
invoke C<on_request>, passing in a token to identify the request for stream
ordering purposes, and the request itself.

=cut

sub incoming_request
{
   my $self = shift;
   my ( $request ) = @_;

   my $on_request = $self->{on_request}
                    || $self->can( "on_request" );

   defined $on_request or
      croak "Cannot process incoming request without an 'on_request'";

   push @{ $self->{server_queue} }, undef;
   my $token = \$self->{server_queue}[-1];

   $on_request->( $self, $token, $request );
}

sub _flush_server_queue
{
   my $self = shift;

   while( @{ $self->{server_queue} } and defined $self->{server_queue}[0] ) {
      my $response = shift @{ $self->{server_queue} };
      $self->write( $response );
   }
}

=head2 $sequencer->incoming_response( $response )

To be called from C<on_read>.

This method informs the sequencer that a response has arrived. It will invoke
C<on_response> that had been passed to the C<request> method that sent the
original request.

=cut

sub incoming_response
{
   my $self = shift;
   my ( $response ) = @_;

   my $client_queue = $self->{client_queue};

   my $cq = shift @$client_queue;
   my $on_response = $cq->[0];

   defined $on_response or croak "Cannot 'incoming_response' without a stored 'on_response' handler";

   my $front = $self->{client_queue}[0];

   # Send the next request if there's one queued
   if( !$self->{pipeline} and $front and defined $front->[2] ) {
      $self->write( $front->[2] );
      undef $front->[2];
   }

   $on_response->( $response );
}

=head1 PUBLIC METHODS

These methods are intended to be called by the application code using a
subclass of this class.

=cut

=head2 $sequencer->request( %params )

Called in client mode, this method sends a request upstream, and awaits a
response to it. Can be called in one of two ways; either giving a specific
C<on_read> handler to be used when the response to this request is expected,
or by providing an C<on_response> handler for when the default handler invokes
C<incoming_response>.

The C<%params> hash takes the following arguments:

=over 8

=item request => SCALAR

The request value to pass to C<marshall_request>.

=item on_response => CODE

A continuation to invoke when a response to this request arrives from the
upstream server. It will be invoked as

 $on_response->( $response );

=item on_read => CODE

A callback to use to parse the incoming stream while the response to this
particular request is expected. It will be invoked the same as for
C<IO::Async::Stream>; i.e.

 $on_read->( $self, $buffref, $eof )

This handler should return C<undef> when it has finished handling the
response, so that the next one queued can be invoked (or the default if none
exists). It MUST NOT call C<incoming_response>. Instead, the code should
directly implement the behaviour for receipt of a response.

=back

If the C<on_read> key is used, it is intended that a specific subclass that
implements a specific protocol would construct the callback code in a method
it provides, intended for the using code to call.

=cut

sub request
{
   my $self = shift;
   my %params = @_;

   my $request = $params{request};

   my $marshall_request = $self->{marshall_request}
                           || $self->can( "marshall_request" );

   defined $marshall_request or
      croak "Cannot send request without a 'marshall_request'";

   my $on_response = $params{on_response};
   my $on_read     = $params{on_read};

   defined $on_response and defined $on_read and
      croak "Cannot pass both 'on_response' and 'on_read'";

   defined $on_response or defined $on_read or
      croak "Need one of 'on_response' or 'on_read'";

   my $client_queue = $self->{client_queue};

   my $request_encoded = $marshall_request->( $self, $request );

   if( $self->{pipeline} or not @$client_queue ) {
      # Clear to send
      $self->write( $request_encoded );
      push @{ $self->{client_queue} }, [ $on_response, $on_read, undef ];
   }
   else {
      # Have to wait
      push @{ $self->{client_queue} }, [ $on_response, $on_read, $request_encoded ];
   }
}

=head2 $sequencer->respond( $token, $response )

Called in server mode, usually at the end of C<on_request>, or some
continuation created within it, this method sends a response back downstream
to a client that had earlier requested it.

=over 8

=item $token

The token that was passed into the C<on_request>. Used to ensure responses are
sent in the right order.

=item $response

The response value to pass to C<marshall_response>.

=back

=cut

sub respond
{
   my $self = shift;
   my ( $token, $response ) = @_;

   my $marshall_response = $self->{marshall_response} 
                            || $self->can( "marshall_response" );

   defined $marshall_response or
      croak "Cannot send response without a 'marshall_response'";

   my $response_stream = $marshall_response->( $self, $response );

   $$token = $response_stream;

   $self->_flush_server_queue;
}

=head1 EXAMPLES

=head2 A simple line-based server

The following sequencer implements a simple server which takes and responds
with CRLF-delimited lines.

 package LineSequencer;

 use base qw( IO::Async::Sequencer );

 my $CRLF = "\x0d\x0a"; # More portable than \r\n

 sub on_read {
    my ( $self, $buffref, $eof ) = @_;

    while( $buffref =~ s/^(.*)$CRLF// ) {
       $self->incoming_request( $1 );
    }

    return 0;
 }

 sub marshall_response {
    my ( $self, $response ) = @_;
    return $response . $CRLF;
 }

 1;

The server could then be used, for example, as a simple echo server that
replies whatever the client said, in uppercase. This would be done using an
C<on_request> like the following.

 my $linesequencer = LineSequencer->new(
    handle => ...

    on_request => sub {
       my ( $self, $token, $request ) = @_;
       $self->respond( $token, uc $request );
    }
 );

It is likely, however, that any real use of the server in a non-trivial way
would perform much more work than this, and only call C<< $self->respond >>
in an eventual continuation at the end of performing its work. The C<$token>
is used to identify the request that the response responds to, so that it can
be sent in the correct order.

=head2 Per-request C<on_read> handler

If an C<on_read> handler is provided to the C<request> method in client
mode, then that handler will be used when the response to that request is
expected to arrive. This will be used instead of the C<incoming_response>
method and the C<on_response> handler. If every request provides its own
handler, then the one in the constructor would only be used for unrequested
input from the server - perhaps to generate an error condition of some kind.

 my $sequencer = IO::Async::Sequencer->new(
    ...

    on_read => sub {
       my ( $self, $buffref, $eof ) = @_;

       print STDERR "Spurious input: $$buffref\n";
       $self->close;
       return 0;
    },

    marshall_request => sub {
       my ( $self, $request ) = @_;
       return "GET $request" . $CRLF;
    },
 );

 $sequencer->request(
    request => "some key",
    on_read => sub {
       my ( $self, $buffref, $eof ) = @_;

       return 0 unless $$buffref =~ s/^(.*)$CRLF//;
       my $line = $1;

       print STDERR "Got response: $1\n" if $line =~ m/^HAVE (.*)$/;

       return undef; # To indicate that this response is finished
    }
 );

=head1 TODO

=over 4

=item *

Some consideration of streaming errors. How does the C<on_read> signal to the
containing object that a stream error has occured? Is it fatal?  Can
resynchronisation be attempted later?

=item *

Support, either here or in a different class, for out-of-order protocols, such
as IMAP, where responses can arrive in a different order than the requests
were sent.

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
