#!/usr/bin/perl -w

use strict;

use Test::More tests => 38;
use Test::Exception;

use IO::Async::ChildManager;

use POSIX qw( WIFEXITED WEXITSTATUS ENOENT );

use IO::Async::Set::IO_Poll;

my $manager = IO::Async::ChildManager->new();

dies_ok( sub { $manager->spawn( command => "/bin/true", on_exit => sub {} ); },
         'Spawn on unassociated ChildManager fails' );

my $set = IO::Async::Set::IO_Poll->new();
$set->enable_childmanager;

$manager = $set->get_childmanager;

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
   my $ready = 0;
   undef $exitcode;

   while( !defined $exitcode ) {
      $_ = $set->loop_once( 2 ); # Give code a generous 2 seconds to exit
      die "Nothing was ready after 2 second wait" if $_ == 0;
      $ready += $_;
   }

   $ready;
}

dies_ok( sub { $manager->spawn( badoption => 1 ); },
         'Bad option to spawn fails' );

dies_ok( sub { $manager->spawn( code => sub { 1 }, command => "hello" ); },
         'Both code and command options to spawn fails' );

dies_ok( sub { $manager->spawn( on_exit => sub { 1 } ); },
         'Bad option to spawn fails' );

my $spawned_pid;

$spawned_pid = $manager->spawn(
   code => sub { return 42; },
   on_exit => \&on_exit,
);

my $ready;
$ready = wait_for_exit;

is( $ready, 3, '$ready after spawn CODE' );

is( $exited_pid, $spawned_pid,  '$exited_pid == $spawned_pid after spawn CODE' );
ok( WIFEXITED($exitcode),       'WIFEXITED($exitcode) after spawn CODE' );
is( WEXITSTATUS($exitcode), 42, 'WEXITSTATUS($exitcode) after spawn CODE' );
# dollarbang isn't interesting here
is( $dollarat,              '', '$dollarat after spawn CODE' );

my $ENDEXIT = 10;
END { exit $ENDEXIT if defined $ENDEXIT; }

$spawned_pid = $manager->spawn(
   code => sub { return 0; },
   on_exit => \&on_exit,
);

$ready = wait_for_exit;

is( $ready, 3, '$ready after spawn CODE with END' );

is( $exited_pid, $spawned_pid, '$exited_pid == $spawned_pid after spawn CODE with END' );
ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after spawn CODE with END' );
# If this comes out as 10 then the END block ran and we fail.
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after spawn CODE with END' );
# dollarbang isn't interesting here
is( $dollarat,             '', '$dollarat after spawn CODE with END' );

$spawned_pid = $manager->spawn(
   code => sub { die "An exception here\n"; },
   on_exit => \&on_exit,
);

$ready = wait_for_exit;

is( $ready, 3, '$ready after spawn CODE with die with END' );

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

$spawned_pid = $manager->spawn(
   command => $true,
   on_exit => \&on_exit,
);

$ready = wait_for_exit;

is( $ready, 2, '$ready after spawn '.$true );

is( $exited_pid, $spawned_pid, '$exited_pid == $spawned_pid after spawn '.$true );
ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after spawn '.$true );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after spawn '.$true );
is( $dollarbang+0,          0, '$dollarbang after spawn '.$true );
is( $dollarat,             '', '$dollarat after spawn '.$true );

# Just be paranoid in case anyone actually has this
my $donotexist = "/bin/donotexist";
$donotexist .= "X" while -e $donotexist;

$spawned_pid = $manager->spawn(
   command => $donotexist,
   on_exit => \&on_exit,
);

$ready = wait_for_exit;

is( $ready, 3, '$ready after spawn donotexist' );

is( $exited_pid, $spawned_pid,   '$exited_pid == $spawned_pid after spawn donotexist' );
ok( WIFEXITED($exitcode),        'WIFEXITED($exitcode) after spawn donotexist' );
is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after spawn donotexist' );
is( $dollarbang+0, ENOENT,                      '$dollarbang numerically after spawn donotexist' ); 
is( "$dollarbang", "No such file or directory", '$dollarbang string after spawn donotexist' );
is( $dollarat,             '', '$dollarat after spawn donotexist' );

$spawned_pid = $manager->spawn(
   command => [ $^X, "-e", "exit 14" ],
   on_exit => \&on_exit,
);

$ready = wait_for_exit;

is( $ready, 2, '$ready after spawn ARRAY' );

is( $exited_pid, $spawned_pid,  '$exited_pid == $spawned_pid after spawn ARRAY' );
ok( WIFEXITED($exitcode),       'WIFEXITED($exitcode) after spawn ARRAY' );
is( WEXITSTATUS($exitcode), 14, 'WEXITSTATUS($exitcode) after spawn ARRAY' );
is( $dollarbang+0,           0, '$dollarbang after spawn ARRAY' );
is( $dollarat,              '', '$dollarat after spawn ARRAY' );
