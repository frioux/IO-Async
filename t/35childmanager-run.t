#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 36;
use Test::Exception;

use POSIX qw( WIFEXITED WEXITSTATUS );

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();

testing_loop( $loop );

my ( $exitcode, $child_out, $child_err );

$loop->run_child(
   code => sub { 0 },
   on_finish => sub { ( undef, $exitcode, $child_out, $child_err ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after sub { 0 }' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after sub { 0 }' );
is( $child_out, "",            '$child_out after sub { 0 }' );
is( $child_err, "",            '$child_err after sub { 0 }' );

$loop->run_child(
   code => sub { 3 },
   on_finish => sub { ( undef, $exitcode, $child_out, $child_err ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after sub { 3 }' );
is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after sub { 3 }' );
is( $child_out, "",            '$child_out after sub { 3 }' );
is( $child_err, "",            '$child_err after sub { 3 }' );

$loop->run_child(
   command => [ $^X, "-e", '1' ],
   on_finish => sub { ( undef, $exitcode, $child_out, $child_err ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl -e 1' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl -e 1' );
is( $child_out, "",            '$child_out after perl -e 1' );
is( $child_err, "",            '$child_err after perl -e 1' );

$loop->run_child(
   command => [ $^X, "-e", 'exit 5' ],
   on_finish => sub { ( undef, $exitcode, $child_out, $child_err ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl -e exit 5' );
is( WEXITSTATUS($exitcode), 5, 'WEXITSTATUS($exitcode) after perl -e exit 5' );
is( $child_out, "",            '$child_out after perl -e exit 5' );
is( $child_err, "",            '$child_err after perl -e exit 5' );

$loop->run_child(
   code    => sub { print "hello\n"; 0 },
   on_finish => sub { ( undef, $exitcode, $child_out, $child_err ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after sub { print }' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after sub { print }' );
is( $child_out, "hello\n",     '$child_out after sub { print }' );
is( $child_err, "",            '$child_err after sub { print }' );

$loop->run_child(
   command => [ $^X, "-e", 'print "goodbye\n"' ],
   on_finish => sub { ( undef, $exitcode, $child_out, $child_err ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl STDOUT' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl STDOUT' );
is( $child_out, "goodbye\n",   '$child_out after perl STDOUT' );
is( $child_err, "",            '$child_err after perl STDOUT' );

$loop->run_child(
   command => [ $^X, "-e", 'print STDOUT "output\n"; print STDERR "error\n";' ],
   on_finish => sub { ( undef, $exitcode, $child_out, $child_err ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl STDOUT/STDERR' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl STDOUT/STDERR' );
is( $child_out, "output\n",    '$child_out after perl STDOUT/STDERR' );
is( $child_err, "error\n",     '$child_err after perl STDOUT/STDERR' );

# perl -pe 1 behaves like cat; copies STDIN to STDOUT

$loop->run_child(
   command => [ $^X, "-pe", '1' ],
   stdin   => "some data\n",
   on_finish => sub { ( undef, $exitcode, $child_out, $child_err ) = @_; },
);

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after perl STDIN->STDOUT' );
is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after perl STDIN->STDOUT' );
is( $child_out, "some data\n", '$child_out after perl STDIN->STDOUT' );
is( $child_err, "",            '$child_err after perl STDIN->STDOUT' );

dies_ok( sub { $loop->run_child(
                  command => [ $^X, "-e", 1 ]
               ) },
         'Missing on_finish fails' );

dies_ok( sub { $loop->run_child( 
                  command => [ $^X, "-e", 1 ],
                  on_finish => "hello"
               ) },
         'on_finish not CODE ref fails' );

dies_ok( sub { $loop->run_child(
                  command => [ $^X, "-e", 1 ],
                  on_finish => sub {},
                  on_exit => sub {},
               ) },
          'on_exit parameter fails' );

dies_ok( sub { $loop->run_child(
                  command => [ $^X, "-e", 1 ],
                  on_finish => sub {},
                  some_key_you_fail => 1
               ) },
         'unrecognised key fails' );
