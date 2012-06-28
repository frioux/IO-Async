#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2011 -- leonerd@leonerd.org.uk

package IO::Async::Notifier;

use strict;
use warnings;

our $VERSION = '0.51_002';

use Carp;
use Scalar::Util qw( weaken );

# Perl 5.8.4 cannot do trampolines by modiying @_ then goto &$code
use constant HAS_BROKEN_TRAMPOLINES => ( $] == "5.008004" );

our $DEBUG = $ENV{IO_ASYNC_DEBUG} || 0;

=head1 NAME

C<IO::Async::Notifier> - base class for C<IO::Async> event objects

=head1 SYNOPSIS

Usually not directly used by a program, but one valid use case may be:

 use IO::Async::Notifier;

 use IO::Async::Stream;
 use IO::Async::Signal;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 my $notifier = IO::Async::Notifier->new;

 $notifier->add_child(
    IO::Async::Stream->new_for_stdin(
       on_read => sub {
          my $self = shift;
          my ( $buffref, $eof ) = @_;

          while( $$buffref =~ s/^(.*)\n// ) {
             print "You said $1\n";
          }

          return 0;
       },
    )
 );

 $notifier->add_child(
    IO::Async::Signal->new(
       name => 'INT',
       on_receipt => sub {
          print "Goodbye!\n";
          $loop->stop;
       },
    )
 );

 $loop->add( $notifier );

 $loop->run;

=head1 DESCRIPTION

This object class forms the basis for all the other event objects that an
C<IO::Async> program uses. It provides the lowest level of integration with a
C<IO::Async::Loop> container, and a facility to collect Notifiers together, in
a tree structure, where any Notifier can contain a collection of children.

Normally, objects in this class would not be directly used by an end program,
as it performs no actual IO work, and generates no actual events. These are all
left to the various subclasses, such as:

=over 4

=item *

L<IO::Async::Handle> - event callbacks for a non-blocking file descriptor

=item *

L<IO::Async::Stream> - event callbacks and write bufering for a stream
filehandle

=item *

L<IO::Async::Socket> - event callbacks and send buffering for a socket
filehandle

=item *

L<IO::Async::Sequencer> - handle a serial pipeline of requests / responses (EXPERIMENTAL)

=item *

L<IO::Async::Timer> - base class for Notifiers that use timed delays

=item *

L<IO::Async::Signal> - event callback on receipt of a POSIX signal

=item *

L<IO::Async::PID> - event callback on exit of a child process

=item *

L<IO::Async::Process> - start and manage a child process

=back

For more detail, see the SYNOPSIS section in one of the above.

One case where this object class would be used, is when a library wishes to
provide a sub-component which consists of multiple other C<Notifier>
subclasses, such as C<Handle>s and C<Timers>, but no particular object is
suitable to be the root of a tree. In this case, a plain C<Notifier> object
can be used as the tree root, and all the other notifiers added as children of
it.

=cut

=head1 AS A MIXIN

Rather than being used as a subclass this package also supports being used as
a non-principle superclass for an object, as a mix-in. It still provides
methods and satisfies an C<isa> test, even though the constructor is not
directly called. This simply requires that the object be based on a normal
blessed hash reference and include C<IO::Async::Notifier> somewhere in its
C<@ISA> list.

The methods in this class all use only keys in the hash prefixed by
C<"IO_Async_Notifier__"> for namespace purposes.

This is intended mainly for defining a subclass of some other object that is
also an C<IO::Async::Notifier>, suitable to be added to an C<IO::Async::Loop>.

 package SomeEventSource::Async;
 use base qw( SomeEventSource IO::Async::Notifier );

 sub _add_to_loop
 {
    my $self = shift;
    my ( $loop ) = @_;

    # Code here to set up event handling on $loop that may be required
 }

 sub _remove_from_loop
 {
    my $self = shift;
    my ( $loop ) = @_;

    # Code here to undo the event handling set up above
 }

Since all the methods documented here will be available, the implementation
may wish to use the C<configure> and C<make_event_cb> or C<invoke_event>
methods to implement its own event callbacks.

=cut

=head1 PARAMETERS

A specific subclass of C<IO::Async::Notifier> defines named parameters that
control its behaviour. These may be passed to the C<new> constructor, or to
the C<configure> method. The documentation on each specific subclass will give
details on the parameters that exist, and their uses. Some parameters may only
support being set once at construction time, or only support being changed if
the object is in a particular state.

The following parameters are supported by all Notifiers:

=over 8

=item notifier_name => STRING

Optional string used to identify this particular Notifier. This value will be
returned by the C<notifier_name> method.

=back

=cut

=head1 CONSTRUCTOR

=cut

=head2 $notifier = IO::Async::Notifier->new( %params )

This function returns a new instance of a C<IO::Async::Notifier> object with
the given initial values of the named parameters.

Up until C<IO::Async> version 0.19, this module used to implement the IO
handle features now found in the C<IO::Async::Handle> subclass. Code that
needs to use any of C<handle>, C<read_handle>, C<write_handle>,
C<on_read_ready> or C<on_write_ready> should use L<IO::Async::Handle> instead.

=cut

sub new
{
   my $class = shift;
   my %params = @_;

   my $self = bless {}, $class;

   $self->_init( \%params );

   $self->configure( %params );

   return $self;
}

=head1 METHODS

=cut

=head2 $notifier->configure( %params )

Adjust the named parameters of the C<Notifier> as given by the C<%params>
hash. 

=cut

# for subclasses to override and call down to
sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( notifier_name )) {
      $self->{"IO_Async_Notifier__$_"} = delete $params{$_} if exists $params{$_};
   }

   # We don't recognise any configure keys at this level
   if( keys %params ) {
      my $class = ref $self;
      croak "Unrecognised configuration keys for $class - " . join( " ", keys %params );
   }
}

=head2 $loop = $notifier->loop

Returns the C<IO::Async::Loop> that this Notifier is a member of.

=head2 $loop = $notifier->get_loop

Synonym for C<loop>.

=cut

sub loop
{
   my $self = shift;
   return $self->{IO_Async_Notifier__loop}
}

*get_loop = \&loop;

# Only called by IO::Async::Loop, not external interface
sub __set_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   # early exit if no change
   return if !$loop and !$self->loop or
             $loop and $self->loop and $loop == $self->loop;

   $self->_remove_from_loop( $self->loop ) if $self->loop;

   $self->{IO_Async_Notifier__loop} = $loop;
   weaken( $self->{IO_Async_Notifier__loop} ); # To avoid a cycle

   $self->_add_to_loop( $self->loop ) if $self->loop;
}

=head2 $name = $notifier->notifier_name

Returns the name to identify this Notifier. If a has not been set, it will
return the empty string. Subclasses may wish to override this behaviour to
return some more useful information, perhaps from configured parameters.

=cut

sub notifier_name
{
   my $self = shift;
   return $self->{IO_Async_Notifier__notifier_name} || "";
}

=head1 CHILD NOTIFIERS

During the execution of a program, it may be the case that certain IO handles
cause other handles to be created; for example, new sockets that have been
C<accept()>ed from a listening socket. To facilitate these, a notifier may
contain child notifier objects, that are automatically added to or removed
from the C<IO::Async::Loop> that manages their parent.

=cut

=head2 $parent = $notifier->parent

Returns the parent of the notifier, or C<undef> if does not have one.

=cut

sub parent
{
   my $self = shift;
   return $self->{IO_Async_Notifier__parent};
}

=head2 @children = $notifier->children

Returns a list of the child notifiers contained within this one.

=cut

sub children
{
   my $self = shift;
   return unless $self->{IO_Async_Notifier__children};
   return @{ $self->{IO_Async_Notifier__children} };
}

=head2 $notifier->add_child( $child )

Adds a child notifier. This notifier will be added to the containing loop, if
the parent has one. Only a notifier that does not currently have a parent and
is not currently a member of any loop may be added as a child. If the child
itself has grandchildren, these will be recursively added to the containing
loop.

=cut

sub add_child
{
   my $self = shift;
   my ( $child ) = @_;

   croak "Cannot add a child that already has a parent" if defined $child->{IO_Async_Notifier__parent};

   croak "Cannot add a child that is already a member of a loop" if defined $child->loop;

   if( defined( my $loop = $self->loop ) ) {
      $loop->add( $child );
   }

   push @{ $self->{IO_Async_Notifier__children} }, $child;
   $child->{IO_Async_Notifier__parent} = $self;
   weaken( $child->{IO_Async_Notifier__parent} );

   return;
}

=head2 $notifier->remove_child( $child )

Removes a child notifier. The child will be removed from the containing loop,
if the parent has one. If the child itself has grandchildren, these will be
recurively removed from the loop.

=cut

sub remove_child
{
   my $self = shift;
   my ( $child ) = @_;

   LOOP: {
      my $childrenref = $self->{IO_Async_Notifier__children};
      for my $i ( 0 .. $#$childrenref ) {
         next unless $childrenref->[$i] == $child;
         splice @$childrenref, $i, 1, ();
         last LOOP;
      }

      croak "Cannot remove child from a parent that doesn't contain it";
   }

   undef $child->{IO_Async_Notifier__parent};

   if( defined( my $loop = $self->loop ) ) {
      $loop->remove( $child );
   }
}

=head2 $notifier->remove_from_parent

Removes this notifier object from its parent (either another notifier object
or the containing loop) if it has one. If the notifier is not a child of
another notifier nor a member of a loop, this method does nothing.

=cut

sub remove_from_parent
{
   my $self = shift;

   if( my $parent = $self->parent ) {
      $parent->remove_child( $self );
   }
   elsif( my $loop = $self->loop ) {
      $loop->remove( $self );
   }
}

=head1 SUBCLASS METHODS

C<IO::Async::Notifier> is a base class provided so that specific subclasses of
it provide more specific behaviour. The base class provides a number of
methods that subclasses may wish to override.

If a subclass implements any of these, be sure to invoke the superclass method
at some point within the code.

=cut

=head2 $notifier->_init( $paramsref )

This method is called by the constructor just before calling C<configure>.
It is passed a reference to the HASH storing the constructor arguments.

This method may initialise internal details of the Notifier as required,
possibly by using parameters from the HASH. If any parameters are
construction-only they should be C<delete>d from the hash.

=cut

sub _init
{
   # empty default
}

=head2 $notifier->configure( %params )

This method is called by the constructor to set the initial values of named
parameters, and by users of the object to adjust the values once constructed.

This method should C<delete> from the C<%params> hash any keys it has dealt
with, then pass the remaining ones to the C<SUPER::configure>. The base
class implementation will throw an exception if there are any unrecognised
keys remaining.

=cut

=head2 $notifier->_add_to_loop( $loop )

This method is called when the Notifier has been added to a Loop; either
directly, or indirectly through being a child of a Notifer already in a loop.

This method may be used to perform any initial startup activity required for
the Notifier to be fully functional but which requires a Loop to do so.

=cut

sub _add_to_loop
{
   # empty default
}

=head2 $notifier->_remove_from_loop( $loop )

This method is called when the Notifier has been removed from a Loop; either
directly, or indirectly through being a child of a Notifier removed from the
loop.

This method may be used to undo the effects of any setup that the
C<_add_to_loop> method had originally done.

=cut

sub _remove_from_loop
{
   # empty default
}

=head1 UTILITY METHODS

=cut

=head2 $mref = $notifier->_capture_weakself( $code )

Returns a new CODE ref which, when invoked, will invoke the originally-passed
ref, with additionally a reference to the Notifier as its first argument. The
Notifier reference is stored weakly in C<$mref>, so this CODE ref may be
stored in the Notifier itself without creating a cycle.

For example,

 my $mref = $notifier->_capture_weakself( sub {
    my ( $notifier, $arg ) = @_;
    print "Notifier $notifier got argument $arg\n";
 } );

 $mref->( 123 );

This is provided as a utility for Notifier subclasses to use to build a
callback CODEref to pass to a Loop method, but which may also want to store
the CODE ref internally for efficiency.

The C<$code> argument may also be a plain string, which will be used as a
method name; the returned CODE ref will then invoke that method on the object.
In this case the method name is stored symbolically in the returned CODE
reference, and dynamically dispatched each time the reference is invoked. This
allows it to follow code reloading, dynamic replacement of class methods, or
other similar techniques.

If the C<$mref> CODE reference is being stored in some object other than the
one it refers to, remember that since the Notifier is only weakly captured, it
is possible that it has been destroyed by the time the code runs, and so the
reference will be passed as C<undef>. This should be protected against by the
code body.

 $other_object->{on_event} = $notifier->_capture_weakself( sub {
    my $notifier = shift or return;
    my ( @event_args ) = @_;
    ...
 } );

=cut

sub _capture_weakself
{
   my $self = shift;
   my ( $code ) = @_;   # actually bare method names work too

   if( !ref $code ) {
      my $class = ref $self;
      # Don't save this coderef, or it will break dynamic method dispatch,
      # which means code reloading, dynamic replacement, or other funky
      # techniques stop working
      $self->can( $code ) or
         croak qq(Can't locate object method "$code" via package "$class");
   }

   weaken $self;

   return sub {
      my $cv = ref( $code ) ? $code : $self->can( $code );

      if( HAS_BROKEN_TRAMPOLINES ) {
         return $cv->( $self, @_ );
      }
      else {
         unshift @_, $self;
         goto &$cv;
      }
   };
}

=head2 $mref = $notifier->_replace_weakself( $code )

Returns a new CODE ref which, when invoked, will invoke the originally-passed
ref, with a reference to the Notifier replacing its first argument. The
Notifier reference is stored weakly in C<$mref>, so this CODE ref may be
stored in the Notifier itself without creating a cycle.

For example,

 my $mref = $notifier->_replace_weakself( sub {
    my ( $notifier, $arg ) = @_;
    print "Notifier $notifier got argument $arg\n";
 } );

 $mref->( $object, 123 );

This is provided as a utility for Notifier subclasses to use for event
callbacks on other objects, where the delegated object is passed in the
function's arguments.

The C<$code> argument may also be a plain string, which will be used as a
method name; the returned CODE ref will then invoke that method on the object.
As with C<_capture_weakself> this is stored symbolically.

As with C<_capture_weakself>, care should be taken against Notifier
destruction if the C<$mref> CODE reference is stored in some other object.

=cut

sub _replace_weakself
{
   my $self = shift;
   my ( $code ) = @_;   # actually bare method names work too

   if( !ref $code ) {
      # Don't save this coderef, see _capture_weakself for why
      my $class = ref $self;
      $self->can( $code ) or
         croak qq(Can't locate object method "$code" via package "$class");
   }

   weaken $self;

   return sub {
      my $cv = ref( $code ) ? $code : $self->can( $code );

      if( HAS_BROKEN_TRAMPOLINES ) {
         return $cv->( $self, @_[1..$#_] );
      }
      else {
         # Don't assign to $_[0] directly or we will change caller's first argument
         shift @_;
         unshift @_, $self;
         goto &$cv;
      }
   };
}

=head2 $code = $notifier->can_event( $event_name )

Returns a C<CODE> reference if the object can perform the given event name,
either by a configured C<CODE> reference parameter, or by implementing a
method. If the object is unable to handle this event, C<undef> is returned.

=cut

sub can_event
{
   my $self = shift;
   my ( $event_name ) = @_;

   return $self->{$event_name} || $self->can( $event_name );
}

=head2 $callback = $notifier->make_event_cb( $event_name )

Returns a C<CODE> reference which, when invoked, will execute the given event
handler. Event handlers may either be subclass methods, or parameters given to
the C<new> or C<configure> method.

The event handler can be passed extra arguments by giving them to the C<CODE>
reference; the first parameter received will be a reference to the notifier
itself. This is stored weakly in the closure, so it is safe to store the
resulting C<CODE> reference in the object itself without causing a reference
cycle.

=cut

sub make_event_cb
{
   my $self = shift;
   my ( $event_name ) = @_;

   my $code = $self->can_event( $event_name )
      or croak "$self cannot handle $event_name event";

   my $caller = caller;

   return $self->_capture_weakself( 
      !$DEBUG ? $code : sub {
         my $self = $_[0];
         $self->debug_printf_event( $caller, $event_name );
         goto &$code;
      }
   );
}

=head2 $callback = $notifier->maybe_make_event_cb( $event_name )

Similar to C<make_event_cb> but will return C<undef> if the object cannot
handle the named event, rather than throwing an exception.

=cut

sub maybe_make_event_cb
{
   my $self = shift;
   my ( $event_name ) = @_;

   my $code = $self->can_event( $event_name )
      or return undef;

   my $caller = caller;

   return $self->_capture_weakself(
      !$DEBUG ? $code : sub {
         my $self = $_[0];
         $self->debug_printf_event( $caller, $event_name );
         goto &$code;
      }
   );
}

=head2 @ret = $notifier->invoke_event( $event_name, @args )

Invokes the given event handler, passing in the given arguments. Event
handlers may either be subclass methods, or parameters given to the C<new> or
C<configure> method. Returns whatever the underlying method or CODE reference
returned.

=cut

sub invoke_event
{
   my $self = shift;
   my ( $event_name, @args ) = @_;

   my $code = $self->can_event( $event_name )
      or croak "$self cannot handle $event_name event";

   $self->debug_printf_event( scalar caller, $event_name ) if $DEBUG;
   return $code->( $self, @args );
}

=head2 $retref = $notifier->maybe_invoke_event( $event_name, @args )

Similar to C<invoke_event> but will return C<undef> if the object cannot
handle the name event, rather than throwing an exception. In order to
distinguish this from an event-handling function that simply returned
C<undef>, if the object does handle the event, the list that it returns will
be returned in an ARRAY reference.

=cut

sub maybe_invoke_event
{
   my $self = shift;
   my ( $event_name, @args ) = @_;

   my $code = $self->can_event( $event_name )
      or return undef;

   $self->debug_printf_event( scalar caller, $event_name ) if $DEBUG;
   return [ $code->( $self, @args ) ];
}

=head1 DEBUGGING SUPPORT

The following methods and behaviours are still experimental and may change or
even be removed in future.

Debugging support is enabled by an environment variable called
C<IO_ASYNC_DEBUG> having a true value.

When debugging is enabled, the C<make_event_cb> and C<invoke_event> methods
(and their C<maybe_> variants) are altered such that when the event is fired,
a debugging line is printed, using the C<debug_printf> method. This identifes
the name of the event.

=cut

=head2 $notifier->debug_printf( $format, @args )

Conditionally print a debugging message to C<STDERR> if debugging is enabled.
If such a message is printed, it will be printed using C<printf> using the
given format and arguments. The message will be prefixed with an string, in
square brackets, to help identify the C<$notifier> instance. This string will
be the class name of the notifier, and any parent notifiers it is contained
by, joined by an arrow C<< <- >>. To ensure this string does not grow too
long, certain prefixes are abbreviated:

 IO::Async::Protocol::  =>  IaP:
 IO::Async::            =>  Ia:
 Net::Async::           =>  Na:

Finally, each notifier that has a name defined using the C<notifier_name>
parameter has that name appended in braces.

For example, invoking

 $stream->debug_printf( "EVENT on_read" )

On an C<IO::Async::Stream> instance reading and writing a file descriptor
whose C<fileno> is 4, which is a child of an C<IO::Async::Protocol::Stream>,
will produce a line of output:

 [Ia:Stream{rw=4}<-IaP:Stream] EVENT on_read

=cut

sub debug_printf
{
   $DEBUG or return;

   my $self = shift;
   my ( $format, @args ) = @_;

   my @id;
   while( $self ) {
      push @id, ref $self;

      my $name = $self->notifier_name;
      $id[-1] .= "{$name}" if defined $name and length $name;

      $self = $self->parent;
   }

   s/^IO::Async::Protocol::/IaP:/,
   s/^IO::Async::/Ia:/,
   s/^Net::Async::/Na:/ for @id;

   printf STDERR "[%s] $format\n",
      join("<-", @id), @args;
}

sub debug_printf_event
{
   my $self = shift;
   my ( $caller, $event_name ) = @_;

   my $class = ref $self;

   if( $DEBUG > 1 or $class eq $caller ) {
      s/^IO::Async::Protocol::/IaP:/,
      s/^IO::Async::/Ia:/,
      s/^Net::Async::/Na:/ for my $str_caller = $caller;

      $self->debug_printf( "EVENT %s",
         ( $class eq $caller ? $event_name : "${str_caller}::$event_name" )
      );
   }
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
