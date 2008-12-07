#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package IO::Async;

use strict;

# This package contains no code other than a declaration of the version.
# It is provided simply to keep CPAN happy:
#   cpan -i IO::Async

our $VERSION = '0.18';

=head1 NAME

C<IO::Async> - a collection of modules that implement asynchronous filehandle
IO

=head1 SYNOPSIS

 use IO::Async::Stream;
 use IO::Async::Loop;

 use Socket qw( SOCK_STREAM );

 my $loop = IO::Async::Loop->new();

 $loop->connect(
    host     => "some.other.host",
    service  => 12345,
    socktype => SOCK_STREAM,

    on_connected => sub {
       my ( $socket ) = @_;

       my $stream = IO::Async::Stream->new(
          handle => $socket,

          on_read => sub {
             my ( $self, $buffref, $closed ) = @_;

             return 0 unless( $buffref =~ s/^(.*\n)// );

             print "Received a line $1";

             return 1;
          }
       );

       $stream->write( "An initial line here\n" );

       $loop->add( $stream );
    },

    ...
 );

 $loop->loop_forever();

=head1 DESCRIPTION

This collection of modules allows programs to be written that perform
asynchronous filehandle IO operations. A typical program using them would
consist of a single subclass of C<IO::Async::Loop> to act as a container for a
number of C<IO::Async::Notifier> objects (or subclasses thereof). The loop
itself is responsible for performing the lower level OS interactions. The
notifiers then perform whatever work is required on these conditions, by using
subclass methods or callback functions.

=head2 Notifiers

A L<IO::Async::Notifier> object represents a single IO handle that is being
managed. While in most cases it will represent a single filehandle, such as a
socket (for example, an C<IO::Socket::INET> connection), it is possible to
have separate reading and writing handles (most likely for a program's
C<STDIN> and C<STDOUT> streams, or a pair of pipes connected to a child
process).

The L<IO::Async::Stream> class is a subclass of C<IO::Async::Notifier> which
maintains internal incoming and outgoing data buffers. In this way, it
implements bidirectional buffering of a byte stream, such as a TCP socket. The
class automatically handles reading of incoming data into the incoming buffer,
and writing of the outgoing buffer. Methods or callbacks are used to inform
when new incoming data is available, or when the outgoing buffer is empty.

=head2 Loops

The L<IO::Async::Loop> object class represents an abstract collection of
C<IO::Async::Notifier> objects. It performs all of the abstract set
management tasks, and leaves the actual OS interactions to a particular
subclass for the purpose.

L<IO::Async::Loop::IO_Poll> uses an C<IO::Poll> object for this test.

L<IO::Async::Loop::Select> provides methods to prepare and test three
bitvectors for a C<select()> syscall.

Other subclasses of loop may appear on CPAN under their own dists; such
as L<IO::Async::Loop::Glib> which acts as a proxy for the C<Glib::MainLoop> of
a L<Glib>-based program, or L<IO::Async::Loop::IO_Ppoll> which uses the
L<IO::Ppoll> object to handle signals safely on Linux.

=head2 Detached Code

The C<IO::Async> framework generally provides mechanisms for multiplexing IO
tasks between different handles, so there aren't many occasions when such
detached code is necessary. Two cases where this does become useful are when
a large amount of computationally-intensive work needs to be performed, or
when an OS or library-level function needs to be called, that will block, and
no asynchronous version is supplied. For these cases, an instance of
L<IO::Async::DetachedCode> can be used around a code block, to execute it in
a detached child process.

=head2 Timers

The L<IO::Async::Loop> supports a pair of methods for installing and
cancelling timers. These are callbacks invoked at some fixed future time.
Once installed, a timer will be called at or after its expiry time, which may
be absolute, or relative to the time it was installed. An installed timer
which has not yet expired may be cancelled.

=head2 Merge Points

The L<IO::Async::MergePoint> object class allows for a program to wait on the
completion of multiple seperate subtasks. It allows for each subtask to return
some data, which will be collected and given to the callback provided to the
merge point, which is called when every subtask has completed.

=head2 Resolver

The L<IO::Async::Resolver> extension to the C<IO::Async::Loop> allows
asynchronous use of any name resolvers the system provides; such as
C<getaddrinfo> for resolving host/service names into connectable addresses.

=head2 Connector

The L<IO::Async::Connector> extension allows socket connections to be
established asynchronously, perhaps via the use of the resolver to first
resolve names into addresses.

=head1 TODO

This collection of modules is still very much in development. As a result,
some of the potentially-useful parts or features currently missing are:

=over 4

=item *

A C<IO::Async::Loop> subclass to perform integration with L<Event>. Consider
further ideas on Linux's I<epoll>, Solaris' I<ports>, BSD's I<Kevents> and
anything that might be useful on Win32.

=item *

A consideration on how to provide per-OS versions of the utility classes. For
example, Win32 would probably need an extensively-different C<ChildManager>,
or OSes may have specific ways to perform asynchronous name resolution
operations better than the generic C<DetachedCode> approach. This should be
easier to implement now that the C<IO::Async::Loop> magic constructor looks
for OS-specific subclasses first.

=item *

A consideration of whether it is useful and possible to provide integration
with L<POE> or L<AnyEvent>.

=back

=head1 SEE ALSO

=over 4

=item *

L<Event> - Event loop processing

=item *

L<POE> - portable multitasking and networking framework for Perl

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>

=cut

# Keep perl happy; keep Britain tidy
1;
