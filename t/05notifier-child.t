#!/usr/bin/perl -w

use strict;

use Test::More tests => 18;
use Test::Exception;
use Test::Refcount;

use IO::Async::Notifier;

use IO::Async::Loop;

my $parent = IO::Async::Notifier->new();
my $child = IO::Async::Notifier->new();

is_oneref( $parent, '$parent has refcount 1 initially' );
is_oneref( $child, '$child has refcount 1 initially' );

$parent->add_child( $child );

is( $child->parent, $parent, '$child->parent is $parent' );

my @children;

@children = $parent->children;
is( scalar @children, 1, '@children after add_child()' );
is( $children[0], $child, '$children[0] after add_child()' );
undef @children; # for refcount

is_oneref( $parent, '$parent has refcount 1 after add_child()' );
is_refcount( $child, 2, '$child has refcount 2 after add_child()' );

dies_ok( sub { $parent->add_child( $child ) },
         'Adding child again fails' );

$parent->remove_child( $child );

is_oneref( $child, '$child has refcount 1 after remove_child()' );

@children = $parent->children;
is( scalar @children, 0, '@children after remove_child()' );
undef @children; # for refcount

my $loop = IO::Async::Loop->new();

$loop->add( $parent );

$parent->add_child( $child );

is_refcount( $child, 3, '$child has refcount 3 after add_child() within loop' );

dies_ok( sub { $loop->remove( $child ) },
         'Directly removing a child from the loop fails' );

$loop->remove( $parent );

@children = $parent->children;
is( scalar @children, 1, '@children after removal from loop' );
undef @children; # for refcount

is_oneref( $parent, '$parent has refcount 1 after removal from loop' );
is_refcount( $child, 2, '$child has refcount 2 after removal of parent from loop' );

dies_ok( sub { $loop->add( $child ) },
        'Directly adding a child to the loop fails' );

$parent->remove_child( $child );

is_oneref( $parent, '$parent has refcount 1 finally' );
is_oneref( $child,  '$child has refcount 1 finally' );
