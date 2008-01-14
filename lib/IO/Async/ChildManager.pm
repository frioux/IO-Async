#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::ChildManager;

use strict;

our $VERSION = '0.11';

# Not a notifier

use IO::Async::Stream;

use Carp;
use Fcntl qw( F_GETFL F_SETFL FD_CLOEXEC );
use POSIX qw( WNOHANG _exit sysconf _SC_OPEN_MAX dup2 );

use constant LENGTH_OF_I => length( pack( "I", 0 ) );
use constant OPEN_MAX_FD => sysconf(_SC_OPEN_MAX);

=head1 NAME

C<IO::Async::ChildManager> - facilitates the execution of child processes

=head1 SYNOPSIS

Usually this object would be used indirectly, via an C<IO::Async::Loop>:

 use IO::Async::Loop::...;
 my $loop = IO::Async::Loop::...

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

It can also be used directly. In this case, extra effort must be taken to
ensure a C<IO::Async::Loop> object is available if the C<spawn()> method is
used:

 use IO::Async::Loop;
 use IO::Async::ChildManager;

 my $loop = IO::Async::Loop::...

 my $manager = IO::Async::ChildManager->new( loop => $loop );

 $loop->attach_signal( CHLD => sub { $manager->SIGCHLD } );

 ...

 $manager->watch( 1234 => sub { print "Child 1234 exited\n" } );

 ...

 $manager->spawn( ... );

It is therefore usually easiest to just use the convenience methods provided
by the C<IO::Async::Loop> object.

=head1 DESCRIPTION

This module provides a class that manages the execution of child processes. It
acts as a central point to store PID values of currently-running children, and
to call the appropriate callback handler code when the process terminates.

=head2 Callbacks

When the C<waitpid()> call returns a PID that the manager is observing, the
registered callback function is invoked with its PID and the current value of
the C<$?> variable.

 $code->( $pid, $? )

After invocation, the handler is automatically removed from the manager.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $manager = IO::Async::ChildManager->new( %params )

This function returns a new instance of a C<IO::Async::ChildManager> object.
The C<%params> hash takes the following keys:

=over 8

=item loop => IO::Async::Loop

A reference to an C<IO::Async::Loop> object. This is required to be able to use
the C<spawn()> method.

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $loop = delete $params{loop} or croak "Expected a 'loop'";

   my $self = bless {
      childdeathhandlers => {},
      loop => $loop,
   }, $class;

   return $self;
}

=head1 METHODS

=cut

=head2 $count = $manager->SIGCHLD

This method notifies the manager that one or more child processes may have
terminated, and that it should check using C<waitpid()>. It returns the number
of child process terminations that were handled.

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

=head2 $manager->watch( $kid, $code )

This method adds a new handler for the termination of the given child PID.

=over 8

=item $kid

The PID to watch.

=item $code

A CODE reference to the handling function.

=back

=cut

sub watch
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

=head2 $pid = $manager->detach_child( %params )

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

   if( defined $params{on_exit} ) {
      $self->watch( $kid => $params{on_exit} );
   }

   return $kid;
}

=head2 $pid = $manager->spawn( %params )

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

=cut

sub spawn
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

   my $kid = $self->detach_child( 
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

=back

=item fdI<n> => IO

A shortcut for the C<dup> case given above.

=item stdin => ...

=item stdout => ...

=item stderr => ...

Shortcuts for C<fd0>, C<fd1> and C<fd2> respectively.

=back

=item env => HASH

A reference to a hash to set as the child process's environment.

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
            croak "Operation for file descriptor $fd must be a reference";
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
         grep { $_ eq $operation } qw( open close dup ) or 
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

   $self->watch( $kid => sub { 
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
      my %keep_fds = ( 0 => 1, 1 => 1, 2 => 1 ); # Keep STDIN, STDOUT, STDERR

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
               delete $keep_fds{$fd};
            };

            $operation eq "dup" and do {
               my $fileno = fileno $params[0];
               # Keep a count of how many times it will be dup()ed from so we
               # can close it once we've finished
               $keep_fds{$fileno}++;
            };
         }
      }

      $keep_fds{fileno $writepipe} = 1;

      foreach ( 0 .. OPEN_MAX_FD ) {
         next if exists $keep_fds{$_};
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

                  $keep_fds{$from}--;
                  if( !$keep_fds{$from} ) {
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

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
