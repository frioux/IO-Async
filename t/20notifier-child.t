#!/usr/bin/perl -w

use strict;

use Test::More tests => 8;
use Test::Exception;

use IO::Poll;

use IO::Async::Notifier;

use IO::Async::Loop;

my $loop = IO::Async::Loop->new();

my $parent = IO::Async::Notifier->new();

my $child = IO::Async::Notifier->new();

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

$loop->add( $parent );

$parent->add_child( $child );

dies_ok( sub { $loop->remove( $child ) },
         'Directly removing a child from the loop fails' );

$loop->remove( $parent );

@children = $parent->children;
is( scalar @children, 1, '@children after removal from loop' );

dies_ok( sub { $loop->add( $child ) },
        'Directly adding a child to the loop fails' );
