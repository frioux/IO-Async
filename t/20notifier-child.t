#!/usr/bin/perl -w

use strict;

use Test::More tests => 20;
use Test::Exception;

use IO::Socket::UNIX;
use IO::Poll;

use IO::Async::Notifier;

use IO::Async::Loop::IO_Poll;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $parent = IO::Async::Notifier->new( 
   read_handle => $S1,
   on_read_ready => sub {},
);

my $child = IO::Async::Notifier->new( 
   read_handle => $S2,
   on_read_ready => sub {},
);

$parent->add_child( $child );

is( $child->parent, $parent, '$child->parent is $parent' );

my @children;

@children = $parent->children;
is( scalar @children, 1, '@children after add_child()' );
is( $children[0], $child, '$children[0] after add_child()' );

dies_ok( sub { $parent->add_child( $child ) },
         'Adding child again fails' );

$parent->remove_child( $child );

@children = $parent->children;
is( scalar @children, 0, '@children after remove_child()' );

my $poll = IO::Poll->new();

my $loop = IO::Async::Loop::IO_Poll->new( poll => $poll );

$loop->add( $parent );

my @handles;

@handles = $poll->handles();
is( scalar @handles, 1, '@handles with parent' );

$parent->add_child( $child );

@handles = $poll->handles();
is( scalar @handles, 2, '@handles with child' );

dies_ok( sub { $loop->remove( $child ) },
         'Directly removing a child from the loop fails' );

$loop->remove( $parent );

@handles = $poll->handles();
is( scalar @handles, 0, '@handles after removal' );

@children = $parent->children;
is( scalar @children, 1, '@children after removal from loop' );

dies_ok( sub { $loop->add( $child ) },
        'Directly adding a child to the loop fails' );

$loop->add( $parent );

$parent->remove_child( $child );

@handles = $poll->handles();
is( scalar @handles, 1, '@handles after remove_child' );

@children = $parent->children;
is( scalar @children, 0, '@children after remove_child' );

$loop->remove( $parent );

$parent->add_child( $child );

my $grandchild = IO::Async::Notifier->new( 
   read_handle => \*STDOUT,
   on_read_ready => sub {},
);

$loop->add( $grandchild );

dies_ok( sub { $parent->add_child( $grandchild ) },
         'Adding a child that is already a member of a loop fails' );

$loop->remove( $grandchild );

$loop->add( $parent );

@handles = $poll->handles();
is( scalar @handles, 2, '@handles after addition again' );

$child->add_child( $grandchild );

@children = $child->children;
is( scalar @children, 1, 'child @children after add_child()' );

@children = $parent->children;
is( scalar @children, 1, 'parent @children after add_child()' );

@handles = $poll->handles();
is( scalar @handles, 3, '@handles after child add_child()' );

$loop->remove( $parent );

@handles = $poll->handles();
is( scalar @handles, 0, '@handles after removal' );

$loop->add( $parent );

@handles = $poll->handles();
is( scalar @handles, 3, '@handles after addition again' );
