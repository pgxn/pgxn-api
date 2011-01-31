#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 1;
#use Test::More 'no_plan';

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API';
    use_ok $CLASS or die;
}
