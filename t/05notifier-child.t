#!/usr/bin/perl -w

use strict;

use Test::More tests => 31;
use Test::Fatal;
use Test::Refcount;

use IO::Async::Notifier;

use IO::Async::Loop;

my $parent = TestNotifier->new( varref => \my $parent_in_loop );
my $child = TestNotifier->new( varref => \my $child_in_loop );

is_oneref( $parent, '$parent has refcount 1 initially' );
is_oneref( $child, '$child has refcount 1 initially' );

$parent->add_child( $child );

is( $child->parent, $parent, '$child->parent is $parent' );

ok( !$parent_in_loop, '$parent not yet in loop' );
ok( !$child_in_loop,  '$child not yet in loop' );

my @children;

@children = $parent->children;
is( scalar @children, 1, '@children after add_child()' );
is( $children[0], $child, '$children[0] after add_child()' );
undef @children; # for refcount

is_oneref( $parent, '$parent has refcount 1 after add_child()' );
is_refcount( $child, 2, '$child has refcount 2 after add_child()' );

ok( exception { $parent->add_child( $child ) }, 'Adding child again fails' );

$parent->remove_child( $child );

is_oneref( $child, '$child has refcount 1 after remove_child()' );

@children = $parent->children;
is( scalar @children, 0, '@children after remove_child()' );
undef @children; # for refcount

my $loop = IO::Async::Loop->new();

$loop->add( $parent );

$parent->add_child( $child );

is_refcount( $child, 3, '$child has refcount 3 after add_child() within loop' );

is( $parent->get_loop, $loop, '$parent->get_loop is $loop' );
is( $child->get_loop,  $loop, '$child->get_loop is $loop' );

ok( $parent_in_loop, '$parent now in loop' );
ok( $child_in_loop,  '$child now in loop' );

ok( exception { $loop->remove( $child ) }, 'Directly removing a child from the loop fails' );

$loop->remove( $parent );

@children = $parent->children;
is( scalar @children, 1, '@children after removal from loop' );
undef @children; # for refcount

is_oneref( $parent, '$parent has refcount 1 after removal from loop' );
is_refcount( $child, 2, '$child has refcount 2 after removal of parent from loop' );

is( $parent->get_loop, undef, '$parent->get_loop is undef' );
is( $child->get_loop,  undef, '$child->get_loop is undef' );

ok( !$parent_in_loop, '$parent no longer in loop' );
ok( !$child_in_loop,  '$child no longer in loop' );

ok( exception { $loop->add( $child ) }, 'Directly adding a child to the loop fails' );

$loop->add( $parent );

is( $child->get_loop, $loop, '$child->get_loop is $loop after remove/add parent' );

ok( $parent_in_loop, '$parent now in loop' );
ok( $child_in_loop,  '$child now in loop' );

$loop->remove( $parent );

$parent->remove_child( $child );

is_oneref( $parent, '$parent has refcount 1 finally' );
is_oneref( $child,  '$child has refcount 1 finally' );

package TestNotifier;
use base qw( IO::Async::Notifier );

sub new
{
   my $self = shift->SUPER::new;
   my %params = @_;

   $self->{varref} = $params{varref};

   return $self;
}

sub _add_to_loop
{
   my $self = shift;
   ${ $self->{varref} } = 1;
}

sub _remove_from_loop
{
   my $self = shift;
   ${ $self->{varref} } = 0;
}
