#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 2;
#use Test::More 'no_plan';
use File::Path qw(remove_tree);

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API::Indexer';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    new
    add_distribution
    merge_distmeta
    mirror_file_for
    doc_root_file_for
    _uri_for
);

END { remove_tree +PGXN::API->instance->config->{index_path} }
