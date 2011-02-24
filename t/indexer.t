#!/usr/bin/env perl -w

use strict;
use warnings;
#use Test::More tests => 2;
use Test::More 'no_plan';
use File::Copy::Recursive qw(dircopy);
use File::Path qw(remove_tree);
use File::Spec::Functions qw(catfile catdir);
use PGXN::API::Sync;
use Test::File;
use Test::Exception;

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API::Indexer';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    new
    add_distribution
    copy_files
    merge_distmeta
    mirror_file_for
    doc_root_file_for
    _uri_for
);

my $api = PGXN::API->instance;
END {
    remove_tree +PGXN::API->instance->config->{index_path};
    remove_tree $api->doc_root;
}

# "Sync" from a "mirror."
dircopy catdir(qw(t root)), $api->mirror_root;

# Unzip pair-0.1.0.
my $sync = new_ok 'PGXN::API::Sync';
my $pgz = catfile $api->mirror_root, qw(dist pair pair-0.1.0.pgz);
ok $sync->unzip($pgz), 'Unzip pair-0.1.0.pgz';

# Read its metadata file.
my $meta = $api->read_json_from(
    catfile $api->mirror_root, qw(dist pair pair-0.1.0.json)
);

# Let's index pair-0.1.0.
file_not_exists_ok(
    catfile($api->doc_root, qw(dist pair), "pair-0.1.0.$_"),
    "pair-0.1.0.$_ should not yet exist"
) for qw(json pgz readme);

my $indexer = new_ok $CLASS;
ok $indexer->copy_files($meta), 'Copy files';

file_exists_ok(
    catfile($api->doc_root, qw(dist pair), "pair-0.1.0.$_"),
    "pair-0.1.0.$_ should now exist"
) for qw(json pgz readme);

# Make sure we get an error when we try to copy a file that does't exist.
$meta->{name} = 'nonexistent';
my $src = catfile $api->mirror_root, qw(dist nonexistent nonexistent-0.1.0.pgz);
my $dst = catfile $api->doc_root,    qw(dist nonexistent nonexistent-0.1.0.pgz);
throws_ok { $indexer->copy_files($meta ) }
    qr{Cannot copy \E$src\Q to \E$dst\Q: No such file or directory},
    'Should get exception with file names for bad copy';
