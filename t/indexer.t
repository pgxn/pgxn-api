#!/usr/bin/env perl -w

use strict;
use warnings;
#use Test::More tests => 43;
use File::Path qw(remove_tree);
use Test::More 'no_plan';

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API::Indexer';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    new
    add_distribution
    merge_distmeta
    file_for
);

END { remove_tree +PGXN::API->instance->config->{index_path} }
