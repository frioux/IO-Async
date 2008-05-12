#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::ChildManager;

use strict;

our $VERSION = '0.14_2';

# Not a notifier

use IO::Async::Stream;
use IO::Async::MergePoint;

use Carp;
use Fcntl qw( F_GETFL F_SETFL FD_CLOEXEC );
use POSIX qw( WNOHANG _exit sysconf _SC_OPEN_MAX dup2 );

use constant LENGTH_OF_I => length( pack( "I", 0 ) );

# Win32 [and maybe other places] don't have an _SC_OPEN_MAX. About the best we
# can do really is just make up some largeish number and hope for the best.
use constant OPEN_MAX_FD => eval { sysconf(_SC_OPEN_MAX) } || 1024;

=head1 NAME

C<IO::Async::ChildManager> - facilitates the execution of child processes

=head1 SYNOPSIS

This object is used indirectly via an C<IO::Async::Loop>:

 use IO::Async::Loop::IO_Poll;
 my $loop = IO::Async::Loop::IO_Poll->new();

 $loop->enable_childmanager;

 ...

 $loop->watch_child( 1234 => sub { print "Child 1234 exited\n" } );

 $loop->spawn_child(
    command => "/usr/bin/something",
    on_exit => \&exit_handler,
    setup => [
       stdout => $pipe,
    ]
 );

=head1 DESCRIPTION

This module extends the functionallity of the containing C<IO::Async::Loop> to
manage the execution of child processes. It acts as a central point to store
PID values of currently-running children, and to call the appropriate callback
handler code when the process terminates.

=cut

# Internal constructor
sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $loop = delete $params{loop} or croak "Expected a 'loop'";

   my $self = bless {
      childdeathhandlers => {},
      loop => $loop,
   }, $class;

   $loop->attach_signal( CHLD => sub { $self->SIGCHLD } );

   return $self;
}

sub disable
{
   my $self = shift;

   my $loop = $self->{loop};

   $loop->detach_signal( 'CHLD' );
}

=head1 METHODS

When active, the following methods are available on the containing C<Loop>
object.

=cut

sub SIGCHLD
{
   my $self = shift;

   my $handlermap = $self->{childdeathhandlers};

   my $count = 0;

   while( 1 ) {
      my $zid = waitpid( -1, WNOHANG );

      last if !defined $zid or $zid < 1;
 
      if( defined $handlermap->{$zid} ) {
         $handlermap->{$zid}->( $zid, $? );
         delete $handlermap->{$zid};
      }
      else {
         carp "No child death handler for '$zid'";
      }

      $count++;
   }

   return $count;
}

=head2 $loop->watch_child( $kid, $code )

This method adds a new handler for the termination of the given child PID.

=over 8

=item $kid

The PID to watch.

=item $code

A CODE reference to the handling function. It will be invoked as

 $code->( $pid, $? )

After invocation, the handler is automatically removed from the manager.

=back

=cut

sub watch_child
{
   my $self = shift;
   my ( $kid, $code ) = @_;

   my $handlermap = $self->{childdeathhandlers};

   croak "Already have a handler for $kid" if exists $handlermap->{$kid};
   $handlermap->{$kid} = $code;

   return;
}

=head2 $watching = $manager->is_watching( $kid )

This method tests if the manager is currently watching for termination of the
given PID. It returns a boolean value.

=over 8

=item $kid

The PID.

=back

=cut

sub is_watching
{
   my $self = shift;
   my ( $kid ) = @_;

   my $handlermap = $self->{childdeathhandlers};

   return exists $handlermap->{$kid};
}

=head2 @kids = $manager->list_watching()

This method returns a list of the PIDs that the manager is currently watching
for. The list is returned in no particular order.

=cut

sub list_watching
{
   my $self = shift;

   my $handlermap = $self->{childdeathhandlers};

   return keys %$handlermap;
}

=head2 $pid = $loop->detach_child( %params )

This method creates a new child process to run a given code block.

=over 8

=item code => CODE

A block of code to execute in the child process. It will be called in scalar
context inside an C<eval> block. The return value will be used as the
C<exit()> code from the child if it returns (or 255 if it returned C<undef> or
thows an exception).

=item on_exit => CODE

A optional callback function to be called when the child processes exits. It
will be invoked in the following way:

 $on_exit->( $pid, $exitcode )

This key is optional; if not supplied, the calling code should install a
handler using the C<watch_child()> method.

=item keep_signals => BOOL

Optional boolean. If missing or false, any CODE references in the C<%SIG> hash
will be removed and restored back to C<DEFAULT> in the child process. If true,
no adjustment of the C<%SIG> hash will be performed.

=back

=cut

sub detach_child
{
   my $self = shift;
   my %params = @_;

   my $code = $params{code};

   my $kid = fork();
   defined $kid or croak "Cannot fork() - $!";

   if( $kid == 0 ) {
      unless( $params{keep_signals} ) {
         foreach( keys %SIG ) {
            next if m/^__(WARN|DIE)__$/;
            $SIG{$_} = "DEFAULT" if ref $SIG{$_} eq "CODE";
         }
      }

      my $exitvalue = eval { $code->() };

      defined $exitvalue or $exitvalue = -1;
      _exit( $exitvalue );
   }

   my $loop = $self->{loop};

   if( defined $params{on_exit} ) {
      $loop->watch_child( $kid => $params{on_exit} );
   }

   return $kid;
}

=head2 $pid = $loop->spawn_child( %params )

This method creates a new child process to run a given code block or command.
The C<%params> hash takes the following keys:

=over 8

=item command => ARRAY or STRING

Either a reference to an array containing the command and its arguments, or a
plain string containing the command. This value is passed into perl's
C<exec()> function.

=item code => CODE

A block of code to execute in the child process. It will be called in scalar
context inside an C<eval> block.

=item setup => ARRAY

A reference to an array which gives file descriptors to set up in the child
process before running the code or command. See below.

=item on_exit => CODE

A callback function to be called when the child processes exits. It will be
invoked in the following way:

 $on_exit->( $pid, $exitcode, $dollarbang, $dollarat )

=back

Exactly one of the C<command> or C<code> keys must be specified.

If the C<command> key is used, the given array or string is executed using the
C<exec()> function. 

If the C<code> key is used, the return value will be used as the C<exit()>
code from the child if it returns (or 255 if it returned C<undef> or thows an
exception).

 Case            | WEXITSTATUS($exitcode) | $dollarbang | $dollarat
 ----------------+------------------------+-------------+----------
 exec() succeeds | exit code from program |     0       |    ""
 exec() fails    |         255            |     $!      |    ""
 $code returns   |     return value       |     $!      |    ""
 $code dies      |         255            |     $!      |    $@

It is usually more convenient to use the C<open()> method in simple cases
where an external program is being started in order to interact with it via
file IO.

=cut

sub spawn_child
{
   my $self = shift;
   my %params = @_;

   my $command = delete $params{command};
   my $code    = delete $params{code};
   my $setup   = delete $params{setup};
   my $on_exit = delete $params{on_exit};

   if( %params ) {
      croak "Unrecognised options to spawn: " . join( ",", keys %params );
   }

   defined $command and defined $code and 
      croak "Cannot pass both 'command' and 'code' to spawn";

   defined $command or defined $code or
      croak "Must pass one of 'command' or 'code' to spawn";

   my @setup = defined $setup ? $self->_check_setup_and_canonicise( $setup ) : ();

   pipe( my $readpipe, my $writepipe ) or croak "Cannot pipe() - $!";

   my $flags = fcntl( $writepipe, F_GETFL, 0 ) or 
      croak "Cannot fcntl(F_GETFL) - $!";
   fcntl( $writepipe, F_SETFL, $flags | FD_CLOEXEC ) or
      croak "Cannot fcntl(F_SETFL) - $!";

   if( defined $command ) {
      my @command = ref( $command ) ? @$command : ( $command );

      $code = sub {
         no warnings;
         exec( @command );
         return;
      };
   }

   my $loop = $self->{loop};

   my $kid = $loop->detach_child( 
      code => sub {
         # Child
         close( $readpipe );
         $self->_spawn_in_child( $writepipe, $code, \@setup );
      },
   );

   # Parent
   close( $writepipe );
   return $self->_spawn_in_parent( $readpipe, $kid, $on_exit );
}

=head2 C<setup> array

This array gives a list of file descriptor operations to perform in the child
process after it has been C<fork()>ed from the parent, before running the code
or command. It consists of name/value pairs which are ordered; the operations
are performed in the order given.

=over 8

=item fdI<n> => ARRAY

Gives an operation on file descriptor I<n>. The first element of the array
defines the operation to be performed:

=over 4

=item [ 'close' ]

The file descriptor will be closed.

=item [ 'dup', $io ]

The file descriptor will be C<dup2()>ed from the given IO handle.

=item [ 'open', $mode, $file ]

The file descriptor will be opened from the named file in the given mode. The
C<$mode> string should be in the form usually given to the C<open()> function;
such as '<' or '>>'.

=item [ 'keep' ]

The file descriptor will not be closed; it will be left as-is.

=back

A non-reference value may be passed as a shortcut, where it would contain the
name of the operation with no arguments (i.e. for the C<close> and C<keep>
operations).

=item fdI<n> => IO

A shortcut for the C<dup> case given above.

=item stdin => ...

=item stdout => ...

=item stderr => ...

Shortcuts for C<fd0>, C<fd1> and C<fd2> respectively.

=item env => HASH

A reference to a hash to set as the child process's environment.

=back

If no directions for what to do with C<stdin>, C<stdout> and C<stderr> are
given, a default of C<keep> is implied. All other file descriptors will be
closed, unless a C<keep> operation is given for them.

=cut

sub _check_setup_and_canonicise
{
   my $self = shift;
   my ( $setup ) = @_;

   ref $setup eq "ARRAY" or croak "'setup' must be an ARRAY reference";

   return () if !@$setup;

   my @setup;

   foreach my $i ( 0 .. $#$setup / 2 ) {
      my ( $key, $value ) = @$setup[$i*2, $i*2 + 1];

      # Rewrite stdin/stdout/stderr
      $key eq "stdin"  and $key = "fd0";
      $key eq "stdout" and $key = "fd1";
      $key eq "stderr" and $key = "fd2";

      if( $key =~ m/^fd(\d+)$/ ) {
         my $fd = $1;
         my $ref = ref $value;

         if( !$ref ) {
            $value = [ $value ];
         }
         elsif( $ref eq "ARRAY" ) {
            # Already OK
         }
         elsif( $ref eq "GLOB" ) {
            $value = [ 'dup', $value ];
         }
         else {
            croak "Unrecognised reference type '$ref' for file descriptor $fd";
         }

         my $operation = $value->[0];
         grep { $_ eq $operation } qw( open close dup keep ) or 
            croak "Unrecognised operation '$operation' for file descriptor $fd";
      }
      elsif( $key eq "env" ) {
         ref $value eq "HASH" or croak "Expected HASH reference for 'env' setup key";
      }
      else {
         croak "Unrecognised setup operation '$key'";
      }

      push @setup, $key => $value;
   }

   return @setup;
}

sub _spawn_in_parent
{
   my $self = shift;
   my ( $readpipe, $kid, $on_exit ) = @_;

   my $loop = $self->{loop};

   # We need to wait for both the errno pipe to close, and for waitpid()
   # to give us an exit code. We'll form two closures over these two
   # variables so we can cope with those happening in either order

   my $dollarbang;
   my ( $dollarat, $length_dollarat );
   my $exitcode;
   my $pipeclosed = 0;

   $loop->add( IO::Async::Stream->new(
      read_handle => $readpipe,

      on_read => sub {
         my ( $self, $buffref, $closed ) = @_;

         if( !defined $dollarbang ) {
            if( length( $$buffref ) >= 2 * LENGTH_OF_I ) {
               ( $dollarbang, $length_dollarat ) = unpack( "II", $$buffref );
               substr( $$buffref, 0, 2 * LENGTH_OF_I, "" );
               return 1;
            }
         }
         elsif( !defined $dollarat ) {
            if( length( $$buffref ) >= $length_dollarat ) {
               $dollarat = substr( $$buffref, 0, $length_dollarat, "" );
               return 1;
            }
         }

         if( $closed ) {
            $dollarbang = 0  if !defined $dollarbang;
            if( !defined $length_dollarat ) {
               $length_dollarat = 0;
               $dollarat = "";
            }

            $pipeclosed = 1;

            if( defined $exitcode ) {
               local $! = $dollarbang;
               $on_exit->( $kid, $exitcode, $!, $dollarat );
            }

            $loop->remove( $self );
         }

         return 0;
      }
   ) );

   $loop->watch_child( $kid => sub { 
      ( my $kid, $exitcode ) = @_;

      if( $pipeclosed ) {
         local $! = $dollarbang;
         $on_exit->( $kid, $exitcode, $!, $dollarat );
      }
   } );

   return $kid;
}

sub _spawn_in_child
{
   my $self = shift;
   my ( $writepipe, $code, $setup ) = @_;

   my $exitvalue = eval {
      # Map of which handles will be in use by the end
      my %fd_in_use = ( 0 => 1, 1 => 1, 2 => 1 ); # Keep STDIN, STDOUT, STDERR

      # Count of how many times we'll need to use the current handles.
      my %fds_refcount = %fd_in_use;

      my $max_fd = 0;
      my $writepipe_clashes = 0;

      if( @$setup ) {
         # The writepipe might be in the way of a setup filedescriptor. If it
         # is we'll have to dup2() it out of the way then close the original.
         foreach my $i ( 0 .. $#$setup/2 ) {
            my ( $key, $value ) = @$setup[$i*2, $i*2 + 1];
            $key =~ m/^fd(\d+)$/ or next;
            my $fd = $1;

            $max_fd = $fd if $fd > $max_fd;
            $writepipe_clashes = 1 if $fd == fileno $writepipe;

            my ( $operation, @params ) = @$value;

            $operation eq "close" and do {
               delete $fd_in_use{$fd};
               delete $fds_refcount{$fd};
            };

            $operation eq "dup" and do {
               $fd_in_use{$fd} = 1;

               my $fileno = fileno $params[0];
               # Keep a count of how many times it will be dup()ed from so we
               # can close it once we've finished
               $fds_refcount{$fileno}++;
            };

            $operation eq "keep" and do {
               $fds_refcount{$fd} = 1;
            };
         }
      }

      foreach ( 0 .. OPEN_MAX_FD ) {
         next if $fds_refcount{$_};
         next if $_ == fileno $writepipe;
         POSIX::close( $_ );
      }

      if( @$setup ) {
         if( $writepipe_clashes ) {
            $max_fd++;

            dup2( fileno $writepipe, $max_fd ) or die "Cannot dup2(writepipe to $max_fd) - $!\n";
            undef $writepipe;
            open( $writepipe, ">&=$max_fd" ) or die "Cannot fdopen($max_fd) as writepipe - $!\n";
         }

         foreach my $i ( 0 .. $#$setup/2 ) {
            my ( $key, $value ) = @$setup[$i*2, $i*2 + 1];

            if( $key =~ m/^fd(\d+)$/ ) {
               my $fd = $1;
               my( $operation, @params ) = @$value;

               $operation eq "dup"   and do {
                  my $from = fileno $params[0];

                  if( $from != $fd ) {
                     POSIX::close( $fd );
                     dup2( $from, $fd ) or die "Cannot dup2($from to $fd) - $!\n";
                  }

                  $fds_refcount{$from}--;
                  if( !$fds_refcount{$from} and !$fd_in_use{$from} ) {
                     POSIX::close( $from );
                  }
               };

               $operation eq "open"  and do {
                  my ( $mode, $filename ) = @params;
                  open( my $fh, $mode, $filename ) or die "Cannot open('$mode', '$filename') - $!\n";

                  my $from = fileno $fh;
                  dup2( $from, $fd ) or die "Cannot dup2($from to $fd) - $!\n";

                  close $fh;
               };
            }
            elsif( $key eq "env" ) {
               %ENV = %$value;
            }
         }
      }

      $code->();
   };

   my $writebuffer = "";
   $writebuffer .= pack( "I", $!+0 );
   $writebuffer .= pack( "I", length( $@ ) ) . $@;

   syswrite( $writepipe, $writebuffer );

   return $exitvalue;
}

=head2 $pid = $loop->open_child( %params )

This creates a new child process to run the given code block or command, and
attaches filehandles to it that the parent will watch. The C<%params> hash
takes the following keys:

=over 8

=item command => ARRAY or STRING

=item code => CODE

The command or code to run in the child process (as per the C<spawn> method)

=item on_finish => CODE

A callback function to be called when the child process exits and has closed
all of the filehandles that were set up for it. It will be invoked in the
following way:

 $on_finish->( $pid, $exitcode )

=item on_error => CODE

Optional callback to be called when the child code block throws an exception,
or the command could not be C<exec()>ed. It will be invoked in the following
way (as per C<spawn>)

 $on_error->( $pid, $exitcode, $dollarbang, $dollarat )

If this callback is not supplied, then C<on_finish> is used instead. The value
of C<$!> and C<$@> will not be reported.

=item setup => ARRAY

Optional reference to an array to pass to the underlying C<spawn> method.

=back

In addition, the hash takes keys that define how to set up file descriptors in
the child process. (If the C<setup> array is also given, these operations will
be performed after those specified by C<setup>.)

=over 8

=item fdI<n> => HASH

A hash describing how to set up file descriptor I<n>. The hash may contain one
of the following sets of keys:

=over 4

=item on_read => CODE

The child will be given the writing end of a pipe. The reading end will be
wrapped by an C<IO::Async::Stream> using this C<on_read> callback function.

=item from => STRING

The child will be given the reading end of a pipe. The string given by the
C<from> parameter will be written to the child. When all of the data has been
written the pipe will be closed.

=back

=item stdin => ...

=item stdout => ...

=item stderr => ...

Shortcuts for C<fd0>, C<fd1> and C<fd2> respectively.

=back

=cut

sub open_child
{
   my $self = shift;
   my %params = @_;

   my %subparams;
   my @setup;
   my %filehandles;

   my $on_finish = delete $params{on_finish};
   ref $on_finish eq "CODE" or croak "Expected 'on_finish' to be a CODE ref";

   my $on_error = delete $params{on_error};
   if( $on_error ) {
      ref $on_error eq "CODE" or croak "Expected 'on_error' to be a CODE ref";
   }

   $params{on_exit} and croak "Cannot pass 'on_exit' parameter through ChildManager->open";

   if( $params{setup} ) {
      ref $params{setup} eq "ARRAY" or croak "Expected 'setup' to be an ARRAY ref";
      @setup = @{ $params{setup} };
      delete $params{setup};
   }

   foreach my $key ( keys %params ) {
      my $value = $params{$key};

      my $orig_key = $key;

      # Rewrite stdin/stdout/stderr
      $key eq "stdin"  and $key = "fd0";
      $key eq "stdout" and $key = "fd1";
      $key eq "stderr" and $key = "fd2";

      if( $key =~  m/^fd\d+$/ ) {
         ref $value eq "HASH" or croak "Expected '$orig_key' to be a HASH ref";

         pipe( my ( $pipe_r, $pipe_w ) ) or croak "Unable to pipe() - $!";

         my ( $myfd, $childfd );

         if( exists $value->{on_read} ) {
            ref $value->{on_read} eq "CODE" or croak "Expected 'on_read' for '$orig_key' be a CODE ref";
            scalar keys %$value == 1 or croak "Found other keys than 'on_read' for '$orig_key'";

            $myfd    = $pipe_r;
            $childfd = $pipe_w;
         }
         elsif( exists $value->{from} ) {
            ref $value->{from} eq "" or croak "Expected 'from' for '$orig_key' not to be a reference";
            scalar keys %$value == 1 or croak "Found other keys than 'from' for '$orig_key'";

            $myfd    = $pipe_w;
            $childfd = $pipe_r;
         }
         else {
            croak "Cannot recognise what to do with '$orig_key'";
         }

         $filehandles{$key} = [ $myfd, $childfd, $value ];
         push @setup, $key => [ dup => $childfd ];
      }
      else {
         $subparams{$orig_key} = $value;
      }
   }

   my $pid;

   my $mergepoint = IO::Async::MergePoint->new(
      needs => [ "exit", keys %filehandles ],

      on_finished => sub {
         my %items = @_;
         my ( $exitcode, $dollarbang, $dollarat ) = @{ $items{exit} };

         if( $params{code} and $dollarat eq "" or $params{command} and $dollarbang == 0 ) {
            $on_finish->( $pid, $exitcode );
         }
         else {
            if( $on_error ) {
               $on_error->( $pid, $exitcode, $dollarbang, $dollarat );
            }
            else {
               $on_finish->( $pid, $exitcode ); # Don't have a way to report dollarbang/dollarat
            }
         }
      },
   );

   my $loop = $self->{loop};

   $pid = $loop->spawn_child( %subparams, 
      setup => \@setup,
      on_exit => sub {
         my ( undef, $exitcode, $dollarbang, $dollarat ) = @_;
         $mergepoint->done( "exit", [ $exitcode, $dollarbang, $dollarat ] );
      },
   );

   return undef unless defined $pid;

   # Now install the handlers

   foreach my $fd ( keys %filehandles ) {
      my ( $myfd, $childfd, $fdopts ) = @{ $filehandles{$fd} };

      close( $childfd );

      my $notifier;

      if( exists $fdopts->{on_read} ) {
         my $on_read = $fdopts->{on_read};

         $notifier = IO::Async::Stream->new(
            read_handle => $myfd,

            on_read => $on_read,

            on_closed => sub {
               $mergepoint->done( $fd );
            },
         );
      }
      elsif( exists $fdopts->{from} ) {
         $notifier = IO::Async::Stream->new(
            write_handle => $myfd,

            on_outgoing_empty => sub {
               $notifier->close;
            },

            on_closed => sub {
               $mergepoint->done( $fd );
            },
         );

         $notifier->write( $fdopts->{from} );
      }

      $loop->add( $notifier );
   }

   return $pid;
}

=head2 $pid = $loop->run_child( %params )

This creates a new child process to run the given code block or command,
capturing its STDOUT and STDERR streams. When the process exits, the callback
is invoked being passed the exitcode, and content of the streams.

=over 8

=item command => ARRAY or STRING

=item code => CODE

The command or code to run in the child process (as per the C<spawn> method)

=item on_finish => CODE

A callback function to be called when the child process exits and closed its
STDOUT and STDERR streams. It will be invoked in the following way:

 $on_finish->( $pid, $exitcode, $stdout, $stderr )

=item stdin => STRING

Optional. String to pass in to the child process's STDIN stream.

=back

This function is intended mainly as an IO::Async-compatible replacement for
the perl C<readpipe> function (`backticks`), allowing it to replace

  my $output = `command here`;

with

 $loop->run_child(
    command => "command here", 
    on_finish => sub {
       my ( undef, $exitcode, $output ) = @_;
       ...
    }
 );

=cut

sub run_child
{
   my $self = shift;
   my %params = @_;

   my $on_finish = delete $params{on_finish};
   ref $on_finish eq "CODE" or croak "Expected 'on_finish' to be a CODE ref";

   my $child_out;
   my $child_err;

   my %subparams;

   if( my $child_stdin = delete $params{stdin} ) {
      ref $child_stdin and croak "Expected 'stdin' not to be a reference";
      $subparams{stdin} = { from => $child_stdin };
   }

   $subparams{code}    = delete $params{code};
   $subparams{command} = delete $params{command};

   croak "Unrecognised parameters " . join( ", ", keys %params ) if keys %params;

   my $loop = $self->{loop};
   $loop->open_child(
      %subparams,
      stdout => {
         on_read => sub { 
            my ( $stream, $buffref, $closed ) = @_;
            $child_out = $$buffref if $closed;
            return 0;
         }
      },

      stderr => { 
         on_read => sub {
            my ( $stream, $buffref, $closed ) = @_;
            $child_err = $$buffref if $closed;
            return 0;
         }
      },

      on_finish => sub {
         my ( $kid, $exitcode ) = @_;
         $on_finish->( $kid, $exitcode, $child_out, $child_err );
      },
   );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
