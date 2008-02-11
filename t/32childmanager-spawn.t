#!/usr/bin/perl -w

use strict;

use lib 't';
use IO::Async::Test;

use Test::More tests => 36;
use Test::Exception;

use POSIX qw( WIFEXITED WEXITSTATUS ENOENT EBADF );

use IO::Async::Loop::IO_Poll;

# Need to look this up, so we don't hardcode the message in the test script
# This might cause locale issues
use constant ENOENT_MESSAGE => do { local $! = ENOENT; "$!" };

my $loop = IO::Async::Loop::IO_Poll->new();
$loop->enable_childmanager;

testing_loop( $loop );

my $exited_pid;
my $exitcode;
my $dollarbang;
my $dollarat;

sub on_exit
{
   ( $exited_pid, $exitcode, $dollarbang, $dollarat ) = @_;
}

sub wait_for_exit
{
   undef $exitcode;
   return wait_for { defined $exitcode };
}

dies_ok( sub { $loop->spawn_child( badoption => 1 ); },
         'Bad option to spawn fails' );

dies_ok( sub { $loop->spawn_child( code => sub { 1 }, command => "hello" ); },
         'Both code and command options to spawn fails' );

dies_ok( sub { $loop->spawn_child( on_exit => sub { 1 } ); },
         'Bad option to spawn fails' );

my $spawned_pid;

$spawned_pid = $loop->spawn_child(
   code => sub { return 42; },
   on_exit => \&on_exit,
);

wait_for_exit;

is( $exited_pid, $spawned_pid,  '$exited_pid == $spawned_pid after spawn CODE' );
ok( WIFEXITED($exitcode),       'WIFEXITED($exitcode) after spawn CODE' );
is( WEXITSTATUS($exitcode), 42, 'WEXITSTATUS($exitcode) after spawn CODE' );
# dollarbang isn't interesting here
is( $dollarat,              '', '$dollarat after spawn CODE' );

my $ENDEXIT = 10;
END { exit $ENDEXIT if defined $ENDEXIT; }

$spawned_pid = $loop->spawn_child(
   code => sub { return 0; },
   on_exit => \&on_exit,
);

wait_for_exit;

is( $exited_pid, $spawned_pid, '$exited_pid == $spawned_pid after spawn CODE with END' );
ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after spawn CODE with END' );
# If this comes out as 10 then the END block ran and we fail.
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after spawn CODE with END' );
# dollarbang isn't interesting here
is( $dollarat,             '', '$dollarat after spawn CODE with END' );

$spawned_pid = $loop->spawn_child(
   code => sub { die "An exception here\n"; },
   on_exit => \&on_exit,
);

wait_for_exit;

is( $exited_pid, $spawned_pid,   '$exited_pid == $spawned_pid after spawn CODE with die with END' );
ok( WIFEXITED($exitcode),        'WIFEXITED($exitcode) after spawn CODE with die with END' );
is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after spawn CODE with die with END' );
# dollarbang isn't interesting here
is( $dollarat, "An exception here\n", '$dollarat after spawn CODE with die with END' );

undef $ENDEXIT;

# We need a command that just exits immediately with 0
my $true;
foreach (qw( /bin/true /usr/bin/true )) {
   $true = $_, last if -x $_;
}

# Didn't find a likely-looking candidate. We'll fake one using perl itself
$true = "$^X -e 1" if !defined $true;

$spawned_pid = $loop->spawn_child(
   command => $true,
   on_exit => \&on_exit,
);

wait_for_exit;

is( $exited_pid, $spawned_pid, '$exited_pid == $spawned_pid after spawn '.$true );
ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after spawn '.$true );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after spawn '.$true );
is( $dollarbang+0,          0, '$dollarbang after spawn '.$true );
is( $dollarat,             '', '$dollarat after spawn '.$true );

# Just be paranoid in case anyone actually has this
my $donotexist = "/bin/donotexist";
$donotexist .= "X" while -e $donotexist;

$spawned_pid = $loop->spawn_child(
   command => $donotexist,
   on_exit => \&on_exit,
);

wait_for_exit;

is( $exited_pid, $spawned_pid,   '$exited_pid == $spawned_pid after spawn donotexist' );
ok( WIFEXITED($exitcode),        'WIFEXITED($exitcode) after spawn donotexist' );
is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after spawn donotexist' );
is( $dollarbang+0, ENOENT,         '$dollarbang numerically after spawn donotexist' ); 
is( "$dollarbang", ENOENT_MESSAGE, '$dollarbang string after spawn donotexist' );
is( $dollarat,             '', '$dollarat after spawn donotexist' );

$spawned_pid = $loop->spawn_child(
   command => [ $^X, "-e", "exit 14" ],
   on_exit => \&on_exit,
);

wait_for_exit;

is( $exited_pid, $spawned_pid,  '$exited_pid == $spawned_pid after spawn ARRAY' );
ok( WIFEXITED($exitcode),       'WIFEXITED($exitcode) after spawn ARRAY' );
is( WEXITSTATUS($exitcode), 14, 'WEXITSTATUS($exitcode) after spawn ARRAY' );
is( $dollarbang+0,           0, '$dollarbang after spawn ARRAY' );
is( $dollarat,              '', '$dollarat after spawn ARRAY' );

{
   pipe( my( $pipe_r, $pipe_w ) ) or die "Cannot pipe() - $!";

   $spawned_pid = $loop->spawn_child(
      code => sub { return $pipe_w->syswrite( "test" ); },
      on_exit => \&on_exit,
   );

   wait_for_exit;

   is( $exited_pid, $spawned_pid,   '$exited_pid == $spawned_pid after pipe close test' );
   ok( WIFEXITED($exitcode),        'WIFEXITED($exitcode) after pipe close test' );
   is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after pipe close test' );
   is( $dollarbang+0,        EBADF, '$dollarbang numerically after pipe close test' );
   is( $dollarat,               '', '$dollarat after pipe close test' );
}
