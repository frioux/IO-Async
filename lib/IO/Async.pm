#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008,2009 -- leonerd@leonerd.org.uk

package IO::Async;

use strict;
use warnings;

# This package contains no code other than a declaration of the version.
# It is provided simply to keep CPAN happy:
#   cpan -i IO::Async

our $VERSION = '0.23';

=head1 NAME

C<IO::Async> - perform asynchronous filehandle IO and other operations

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
consist of a single subclass of C<IO::Async::Loop> to act as a container o
other objects, which perform the actual IO work required by the program. As
as IO handles, the loop also supports timers and signal handlers, and
includes more higher-level functionallity built on top of these basic parts.

Because there are a lot of classes in this collection, the following overview
gives a brief description of each.

=head2 File Handle IO

A L<IO::Async::Handle> object represents a single IO handle that is being
managed. While in most cases it will represent a single filehandle, such as a
socket (for example, an C<IO::Socket::INET> connection), it is possible to
have separate reading and writing handles (most likely for a program's
C<STDIN> and C<STDOUT> streams, or a pair of pipes connected to a child
process).

The L<IO::Async::Stream> class is a subclass of C<IO::Async::Handle> which
maintains internal incoming and outgoing data buffers. In this way, it
implements bidirectional buffering of a byte stream, such as a TCP socket. The
class automatically handles reading of incoming data into the incoming buffer,
and writing of the outgoing buffer. Methods or callbacks are used to inform
when new incoming data is available, or when the outgoing buffer is empty.

Both of the above are subclasses of L<IO::Async::Notifier>, which does not
perform any IO operations itself, but instead acts to coordinate a collection
of other Notifiers, or act as a base class to build the specific IO
functionallity upon. For other types of C<Notifier>, see Timers and Signals
below.

=head2 Loops

The L<IO::Async::Loop> object class represents an abstract collection of
C<IO::Async::Notifier> objects, filehandle IO watches, timers, signal
handlers, and other functionallity. It performs all of the abstract
collection management tasks, and leaves the actual OS interactions to a
particular subclass for the purpose.

L<IO::Async::Loop::Poll> uses an C<IO::Poll> object for this test.

L<IO::Async::Loop::Select> uses the C<select()> syscall.

Other subclasses of loop may appear on CPAN under their own dists; such
as L<IO::Async::Loop::Glib> which acts as a proxy for the C<Glib::MainLoop> of
a L<Glib>-based program, or L<IO::Async::Loop::IO_Ppoll> which uses the
L<IO::Ppoll> object to handle signals safely on Linux.

As well as these general-purpose classes, the C<IO::Async::Loop> constructor
also supports looking for OS-specific subclasses, in case a more efficient
implementation exists for the specific OS it runs on.

=head2 Child Processes

The C<IO::Async::Loop> object provides a number of methods to facilitate the
running of child processes. C<spawn_child> is primarily a wrapper around the
typical C<fork()>/C<exec()> style of starting child processes, C<open_child>
builds on this to provide management of child process file handles and streams
connected to them, and finally C<run_child> builds on that to provide a method
similar to perl's C<readpipe()> (which is used to implement backticks C<``>).

=head2 Detached Code

The C<IO::Async> framework generally provides mechanisms for multiplexing IO
tasks between different handles, so there aren't many occasions when it is
necessary to run code in another thread or process. Two cases where this does
become useful are when:

=over 4

=item *

A large amount of computationally-intensive work needs to be performed.

=item * 

An OS or library-level function needs to be called, that will block, and
no asynchronous version is supplied.

=back

For these cases, an instance of L<IO::Async::DetachedCode> can be used around
a code block, to execute it in a detached child process. The code in the
sub-process runs isolated from the main program, communicating only by
function call arguments and return values.

=head2 Timers

A L<IO::Async::Timer> object represents a counttime timer, which will invoke
a callback after a given delay. It can be stopped and restarted.

The L<IO::Async::Loop> also supports methods for managing timed events on a
lower level. Events may be absolute, or relative in time to the time they are
installed.

=head2 Signals

A L<IO::Async::Signal> object represents a POSIX signal, which will invoke a
callback when the given signal is received by the process. Multiple objects
watching the same signal can be used; they will all invoke in no particular
order.

=head2 Merge Points

The L<IO::Async::MergePoint> object class allows for a program to wait on the
completion of multiple seperate subtasks. It allows for each subtask to return
some data, which will be collected and given to the callback provided to the
merge point, which is called when every subtask has completed.

=head2 Networking

The C<IO::Async::Loop> provides several methods for performing network-based
tasks. Primarily, the C<connect> and C<listen> methods allow the creation of
client or server network sockets. Additionally, the C<resolve> method allows
the use of the system's name resolvers in an asynchronous way, to resolve
names into addresses, or vice versa.

=head1 TODO

This collection of modules is still very much in development. As a result,
some of the potentially-useful parts or features currently missing are:

=over 4

=item *

A C<IO::Async::Loop> subclass to perform integration with L<Event>. Consider
further ideas on Solaris' I<ports>, BSD's I<Kevents> and anything that might
be useful on Win32.

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

Paul Evans <leonerd@leonerd.org.uk>

=cut

# Keep perl happy; keep Britain tidy
1;
