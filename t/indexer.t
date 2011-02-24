#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 6;
#use Test::More 'no_plan';
use File::Path qw(remove_tree);
use Cwd;
use File::Spec::Functions qw(catdir);

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API::Indexer';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    new
    doc_root
    add_distribution
    merge_distmeta
    file_for
);

END { remove_tree +PGXN::API->instance->config->{index_path} }

# Test doc_root.
my $indexer = new_ok $CLASS;
PGXN::API->instance->config->{doc_root} = 'foo/bar';
is $indexer->doc_root, 'foo/bar', 'Should have configured doc root';

# Make sure the default works.
$indexer = new_ok $CLASS;
delete +PGXN::API->instance->config->{doc_root};
is $indexer->doc_root, catdir(cwd, 'www'),
    'Should have default doc root';

