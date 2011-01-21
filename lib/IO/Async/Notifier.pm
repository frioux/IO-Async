#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2011 -- leonerd@leonerd.org.uk

package IO::Async::Notifier;

use strict;
use warnings;

our $VERSION = '0.37';

use Carp;
use Scalar::Util qw( weaken );

# Perl 5.8.4 cannot do trampolines by modiying @_ then goto &$code
use constant HAS_BROKEN_TRAMPOLINES => ( $] == "5.008004" );

=head1 NAME

C<IO::Async::Notifier> - base class for C<IO::Async> event objects

=head1 SYNOPSIS

Usually not directly used by a program, but one valid use case may be:

 use IO::Async::Notifier;

 use IO::Async::Stream;
 use IO::Async::Signal;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $notifier = IO::Async::Notifier->new();

 $notifier->add_child(
    IO::Async::Stream->new_for_stdin(
       on_read => sub {
          my $self = shift;
          my ( $buffref, $eof ) = @_;
          $$buffref =~ s/^(.*)\n// or return 0;
          print "You said $1\n";
          return 1;
       },
    )
 );

 $notifier->add_child(
    IO::Async::Signal->new(
       name => 'INT',
       on_receipt => sub {
          print "Goodbye!\n";
          $loop->loop_stop;
       },
    )
 );

 $loop->add( $notifier );

 $loop->loop_forever;

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

=head1 PARAMETERS

A specific subclass of C<IO::Async::Notifier> defines named parameters that
control its behaviour. These may be passed to the C<new> constructor, or to
the C<configure> method. The documentation on each specific subclass will give
details on the parameters that exist, and their uses. Some parameters may only
support being set once at construction time, or only support being changed if
the object is in a particular state.

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

   if( $class eq __PACKAGE__ and 
      grep { exists $params{$_} } qw( handle read_handle write_handle on_read_ready on_write_ready ) ) {
      carp "IO::Async::Notifier no longer wraps a filehandle; see instead IO::Async::Handle";

      require IO::Async::Handle;
      return IO::Async::Handle->new( %params );
   }

   my $self = bless {
      children => [],
      parent   => undef,
   }, $class;

   $self->_init( \%params );

   $self->configure( %params );

   return $self;
}

=head2 $notifier->configure( %params )

Adjust the named parameters of the C<Notifier> as given by the C<%params>
hash. 

=cut

# for subclasses to override and call down to
sub configure
{
   my $self = shift;
   my %params = @_;

   # We don't recognise any configure keys at this level
   if( keys %params ) {
      my $class = ref $self;
      croak "Unrecognised configuration keys for $class - " . join( " ", keys %params );
   }
}

=head2 $notifier->get_loop

Returns the C<IO::Async::Loop> that this Notifier is a member of.

=cut

sub get_loop
{
   my $self = shift;
   return $self->{loop}
}

# Only called by IO::Async::Loop, not external interface
sub __set_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   # early exit if no change
   return if !$loop and !$self->{loop} or
             $loop and $self->{loop} and $loop == $self->{loop};

   $self->_remove_from_loop( $self->{loop} ) if $self->{loop};

   $self->{loop} = $loop;
   weaken( $self->{loop} ); # To avoid a cycle

   $self->_add_to_loop( $self->{loop} ) if $self->{loop};
}

=head1 CHILD NOTIFIERS

During the execution of a program, it may be the case that certain IO handles
cause other handles to be created; for example, new sockets that have been
C<accept()>ed from a listening socket. To facilitate these, a notifier may
contain child notifier objects, that are automatically added to or removed
from the C<IO::Async::Loop> that manages their parent.

=cut

=head2 $parent = $notifier->parent()

Returns the parent of the notifier, or C<undef> if does not have one.

=cut

sub parent
{
   my $self = shift;
   return $self->{parent};
}

=head2 @children = $notifier->children()

Returns a list of the child notifiers contained within this one.

=cut

sub children
{
   my $self = shift;
   return @{ $self->{children} };
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

   croak "Cannot add a child that already has a parent" if defined $child->{parent};

   croak "Cannot add a child that is already a member of a loop" if defined $child->{loop};

   if( defined( my $loop = $self->{loop} ) ) {
      $loop->add( $child );
   }

   push @{ $self->{children} }, $child;
   $child->{parent} = $self;
   weaken( $child->{parent} );

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
      my $childrenref = $self->{children};
      for my $i ( 0 .. $#$childrenref ) {
         next unless $childrenref->[$i] == $child;
         splice @$childrenref, $i, 1, ();
         last LOOP;
      }

      croak "Cannot remove child from a parent that doesn't contain it";
   }

   undef $child->{parent};

   if( defined( my $loop = $self->{loop} ) ) {
      $loop->remove( $child );
   }
}

sub _remove_from_outer
{
   my $self = shift;

   if( my $parent = $self->parent ) {
      $parent->remove_child( $self );
   }
   elsif( my $loop = $self->get_loop ) {
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

This method is called by the constructor just before calling C<configure()>.
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
with, then pass the remaining ones to the C<SUPER::configure()>. The base
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

=cut

sub _capture_weakself
{
   my $self = shift;
   my ( $code ) = @_;   # actually bare method names work too

   if( !ref $code ) {
      my $class = ref $self;
      my $coderef = $self->can( $code ) or
         croak qq(Can't locate object method "$code" via package "$class");

      $code = $coderef;
   }

   weaken $self;

   return sub {
      if( HAS_BROKEN_TRAMPOLINES ) {
         return $code->( $self, @_ );
      }
      else {
         unshift @_, $self;
         goto &$code;
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

=cut

sub _replace_weakself
{
   my $self = shift;
   my ( $code ) = @_;   # actually bare method names work too

   if( !ref $code ) {
      my $class = ref $self;
      my $coderef = $self->can( $code ) or
         croak qq(Can't locate object method "$code" via package "$class");

      $code = $coderef;
   }

   weaken $self;

   return sub {
      if( HAS_BROKEN_TRAMPOLINES ) {
         return $code->( $self, @_[1..$#_] );
      }
      else {
         # Don't assign to $_[0] directly or we will change caller's first argument
         shift @_;
         unshift @_, $self;
         goto &$code;
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

   return $self->_capture_weakself( $code );
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

   return $self->_capture_weakself( $code );
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

   return [ $code->( $self, @args ) ];
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
