#!/usr/bin/perl -w

use strict;

use lib 't';
use IO::Async::Test;

use Test::More tests => 36;
use Test::Exception;

use POSIX qw( WIFEXITED WEXITSTATUS ENOENT );

use IO::Async::Loop::IO_Poll;

# Need to look this up, so we don't hardcode the message in the test script
# This might cause locale issues
use constant ENOENT_MESSAGE => do { local $! = ENOENT; "$!" };

my $loop = IO::Async::Loop::IO_Poll->new();
$loop->enable_childmanager;

testing_loop( $loop );

my $exitcode;

$loop->open_child(
   code => sub { 0 },
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after sub { 0 }' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after sub { 0 }' );

$loop->open_child(
   code => sub { 3 },
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after sub { 3 }' );
is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after sub { 3 }' );

my ( $dollarbang, $dollarat );

$loop->open_child(
   code => sub { die "An error\n" },
   on_finish => sub { die "Test failed early\n" },
   on_error => sub { ( undef, $exitcode, $dollarbang, $dollarat ) = @_ },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),        'WIFEXITED($exitcode) after sub { die }' );
is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after sub { die }' );
is( $dollarat, "An error\n",     '$dollarat after sub { die }' );

$loop->open_child(
   command => [ $^X, "-e", '1' ],
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl -e 1' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl -e 1' );

$loop->open_child(
   command => [ $^X, "-e", 'exit 5' ],
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl -e exit 5' );
is( WEXITSTATUS($exitcode), 5, 'WEXITSTATUS($exitcode) after perl -e exit 5' );

# Just be paranoid in case anyone actually has this
my $donotexist = "/bin/donotexist";
$donotexist .= "X" while -e $donotexist;

$loop->open_child(
   command => $donotexist,
   on_finish => sub { die "Test failed early\n" },
   on_error => sub { ( undef, $exitcode, $dollarbang, $dollarat ) = @_ },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),          'WIFEXITED($exitcode) after donotexist' );
is( WEXITSTATUS($exitcode), 255,   'WEXITSTATUS($exitcode) after donotexist' );
is( $dollarbang+0, ENOENT,         '$dollarbang numerically after donotexist' ); 
is( "$dollarbang", ENOENT_MESSAGE, '$dollarbang string after donotexist' );
is( $dollarat, "",                 '$dollarat after donotexist' );

my @stdout_lines;

sub child_out_reader
{
   my ( $stream, $buffref ) = @_;

   while( $$buffref =~ s/^(.*\n)// ) {
      push @stdout_lines, $1;
   }

   return 0;
}

pipe( my $syncpipe_r, my $syncpipe_w ) or die "Cannot pipe - $!";
$syncpipe_w->autoflush;

$loop->open_child(
   code    => sub { print "hello\n"; 0 },
   stdout  => { on_read => \&child_out_reader },
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
undef @stdout_lines;

wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after sub { print }' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after sub { print }' );
is_deeply( \@stdout_lines, [ "hello\n" ], '@stdout_lines after sub { print }' );

$loop->open_child(
   command => [ $^X, "-e", 'print "goodbye\n"' ],
   stdout  => { on_read => \&child_out_reader },
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
undef @stdout_lines;

wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl STDOUT' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl STDOUT' );
is_deeply( \@stdout_lines, [ "goodbye\n" ], '@stdout_lines after perl STDOUT' );

my @stderr_lines;

sub child_err_reader
{
   my ( $stream, $buffref ) = @_;

   while( $$buffref =~ s/^(.*\n)// ) {
      push @stderr_lines, $1;
   }

   return 0;
}

$loop->open_child(
   command => [ $^X, "-e", 'print STDOUT "output\n"; print STDERR "error\n";' ],
   stdout  => { on_read => \&child_out_reader },
   stderr  => { on_read => \&child_err_reader },
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
undef @stdout_lines;

wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl STDOUT/STDERR' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl STDOUT/STDERR' );
is_deeply( \@stdout_lines, [ "output\n" ], '@stdout_lines after perl STDOUT/STDERR' );
is_deeply( \@stderr_lines, [ "error\n"  ], '@stderr_lines after perl STDOUT/STDERR' );

# perl -pe 1 behaves like cat; copies STDIN to STDOUT

$loop->open_child(
   command => [ $^X, "-pe", '1' ],
   stdin   => { from => "some data\n" },
   stdout  => { on_read => \&child_out_reader },
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
undef @stdout_lines;

wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl STDIN->STDOUT' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl STDIN->STDOUT' );
is_deeply( \@stdout_lines, [ "some data\n" ], '@stdout_lines after perl STDIN->STDOUT' );

# Now check fd[n] works just as well

$loop->open_child(
   command => [ $^X, "-pe", 'print STDERR "Error\n"' ],
   fd0     => { from => "some data\n" },
   stdout  => { on_read => \&child_out_reader },
   stderr  => { on_read => \&child_err_reader },
   on_finish => sub { ( undef, $exitcode ) = @_; },
);

undef $exitcode;
undef @stdout_lines;
undef @stderr_lines;

wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl STDIN->STDOUT using fd[n]' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl STDIN->STDOUT using fd[n]' );
is_deeply( \@stdout_lines, [ "some data\n" ], '@stdout_lines after perl STDIN->STDOUT using fd[n]' );
is_deeply( \@stderr_lines, [ "Error\n"     ], '@stderr_lines after perl STDIN->STDOUT using fd[n]' );

dies_ok( sub { $loop->open_child(
                  command => [ $^X, "-e", 1 ]
               ) },
         'Missing on_finish fails' );

dies_ok( sub { $loop->open_child( 
                  command => [ $^X, "-e", 1 ],
                  on_finish => "hello"
               ) },
         'on_finish not CODE ref fails' );

dies_ok( sub { $loop->open_child(
                  command => [ $^X, "-e", 1 ],
                  on_finish => sub {},
                  on_exit => sub {},
               ) },
          'on_exit parameter fails' );
