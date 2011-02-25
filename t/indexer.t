#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 38;
#use Test::More 'no_plan';
use File::Copy::Recursive qw(dircopy fcopy);
use File::Path qw(remove_tree);
use File::Spec::Functions qw(catfile catdir);
use PGXN::API::Sync;
use Test::File;
use Test::Exception;
use Test::File::Contents;
use utf8;

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
    update_owner
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

# Read pair-0.1.0.' metadata file.
my $meta = $api->read_json_from(
    catfile $api->mirror_root, qw(dist pair pair-0.1.0.json)
);

##############################################################################
# Let's index pair-0.1.0.
file_not_exists_ok(
    catfile($api->doc_root, qw(dist pair), "pair-0.1.0.$_"),
    "pair-0.1.0.$_ should not yet exist"
) for qw(pgz readme);

my $indexer = new_ok $CLASS;
ok $indexer->copy_files($meta), 'Copy files';

file_exists_ok(
    catfile($api->doc_root, qw(dist pair), "pair-0.1.0.$_"),
    "pair-0.1.0.$_ should now exist"
) for qw(pgz readme);

# Make sure we get an error when we try to copy a file that does't exist.
$meta->{name} = 'nonexistent';
my $src = catfile $api->mirror_root, qw(dist nonexistent nonexistent-0.1.0.pgz);
my $dst = catfile $api->doc_root,    qw(dist nonexistent nonexistent-0.1.0.pgz);
throws_ok { $indexer->copy_files($meta ) }
    qr{Cannot copy \E$src\Q to \E$dst\Q: No such file or directory},
    'Should get exception with file names for bad copy';
$meta->{name} = 'pair';

##############################################################################
# Now merge the distribution metadata files.
my $dist_file = catfile $api->doc_root, qw(dist pair pair-0.1.0.json);
my $by_dist   = catfile $api->doc_root, qw(by dist pair.json);

file_not_exists_ok $dist_file, 'pair-0.1.0.json should not yet exist';
file_not_exists_ok $by_dist,   'pair.json should not yet exist';

ok $indexer->merge_distmeta($meta), 'Merge the distmeta';

file_exists_ok $dist_file, 'pair-0.1.0.json should now exist';
file_exists_ok $by_dist,   'pair.json should now exist';

# The two files should be identical.
files_eq_or_diff $dist_file, $by_dist,
    'pair-0.1.0.json and pair.json should be the same';

# So have a look at the contents.
ok my $dist_meta = $api->read_json_from($dist_file),
    'Read the merged distmeta';
$meta->{releases} = { stable => ['0.1.0'] };
is_deeply $dist_meta, $meta, 'And it should be the merged metadata';

# Now update with 0.1.1. "Sync" the updated pair.json.
fcopy catfile(qw(t data pair-updated.json)),
      catfile($api->mirror_root, qw(by dist pair.json));

my $meta_011 = $api->read_json_from(
    catfile $api->mirror_root, qw(dist pair pair-0.1.1.json)
);
my $dist_011_file = catfile $api->doc_root, qw(dist pair pair-0.1.1.json);
file_not_exists_ok $dist_011_file, 'pair-0.1.1.json should not yet exist';
ok $indexer->merge_distmeta($meta_011), 'Merge the distmeta';
file_exists_ok $dist_011_file, 'pair-0.1.1.json should now exist';

files_eq_or_diff $dist_011_file, $by_dist,
    'pair-0.1.1.json and pair.json should be the same';

ok $dist_meta = $api->read_json_from($dist_011_file),
    'Read the 0.1.1 merged distmeta';
$meta_011->{releases} = { stable => ['0.1.1', '0.1.0'] };
is_deeply $dist_meta, $meta_011,
    'And it should be the merged with all version info';

# Meanwhile, the old file should be the same as before, except that it should
# now also have a list of all releases.
ok $dist_meta = $api->read_json_from($dist_file),
    'Read the older version distmeta';
$meta->{releases} = { stable => ['0.1.1', '0.1.0'] };
is_deeply $dist_meta, $meta, 'It should be updated with all versions';

##############################################################################
# Now update the owner metadata.
my $owner_file = catfile qw(www by owner theory.json);
file_not_exists_ok $owner_file, "$owner_file should not yet exist";
ok $indexer->update_owner($meta), 'Update the owner metadata';
file_exists_ok $owner_file, "$owner_file should now exist";

# Now make sure that it has the updated release metadata.
ok my $mir_data = $api->read_json_from(
    catfile qw(www pgxn by owner theory.json)
),'Read the mirror owner data file';
ok my $doc_data = $api->read_json_from($owner_file),
    'Read the doc root owner data file';
$mir_data->{releases}{pair}{stable} = ['0.1.0'];
$mir_data->{releases}{pair}{stable_date} = '2010-10-18T15:24:21Z';
$mir_data->{releases}{pair}{abstract} = 'A key/value pair data type';
is_deeply $doc_data, $mir_data,
    'The doc root data should have the the metadata for this release';

# Great, now update it.
fcopy catfile(qw(t data theory-updated.json)),
      catfile($api->mirror_root, qw(by owner theory.json));
ok $indexer->update_owner($meta_011),
    'Update the owner metadata for pair 0.1.1';
$mir_data->{releases}{pair}{stable} = ['0.1.0'];
$mir_data->{releases}{pair}{testing} = ['0.1.1'];
$mir_data->{releases}{pair}{testing_date} = '2010-10-29T22:46:45Z';
$mir_data->{releases}{pair}{abstract} = 'A key/value pair dåtå type';
ok $doc_data = $api->read_json_from($owner_file),
    'Read the doc root owner data file again';
is_deeply $doc_data, $mir_data,
    'The doc root data should have the the metadata for 0.1.1';

# Now do another stable release.
fcopy catfile(qw(t data theory-updated2.json)),
      catfile($api->mirror_root, qw(by owner theory.json));
my $meta_012 = $api->read_json_from(
    catfile $api->mirror_root, qw(dist pair pair-0.1.2.json)
);
ok $indexer->merge_distmeta($meta_012), 'Merge the 0.1.2 distmeta';
ok $indexer->update_owner($meta_012),
    'Update the owner metadata for pair 0.1.2';
$mir_data->{releases}{pair}{stable} = ['0.1.2', '0.1.0'];
$mir_data->{releases}{pair}{stable_date} = '2010-11-10T12:18:03Z';
ok $doc_data = $api->read_json_from($owner_file),
    'Read the doc root owner data file once more';
is_deeply $doc_data, $mir_data,
    'The doc root data should have the the metadata for 0.1.2';
