#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 93;
#use Test::More 'no_plan';
use File::Copy::Recursive qw(dircopy fcopy);
use File::Path qw(remove_tree);
use File::Spec::Functions qw(catfile catdir);
use PGXN::API::Sync;
use Test::File;
use Test::Exception;
use Test::File::Contents;
use Test::MockModule;
use utf8;

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API::Indexer';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    new
    update_mirror_meta
    add_distribution
    copy_files
    merge_distmeta
    update_owner
    update_tags
    mirror_file_for
    doc_root_file_for
    _uri_for
);

my $api = PGXN::API->instance;
my $doc_root = catdir 't', 'test_doc_root';
$api->doc_root($doc_root);
END { remove_tree $doc_root }

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
    catfile($api->doc_root, qw(dist pair), "pair-0.1.0.pgz"),
    "pair-0.1.0.pgz should now exist"
);
file_not_exists_ok(
    catfile($api->doc_root, qw(dist pair), "pair-0.1.0.readme"),
    "pair-0.1.0.readme still should not exist"
);

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
$meta->{releases} = { stable => [{version => '0.1.0', date => '2010-10-19T03:59:54Z'}] };
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
# 0.1.2 has been released but we haven't copied it to the doc root yet.
$meta_011->{releases} = { stable => [
    {version => '0.1.2', date => '2010-12-13T23:12:41Z'},
    {version => '0.1.1', date => '2010-10-29T22:44:42Z'},
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'}
] };
is_deeply $dist_meta, $meta_011,
    'And it should be the merged with all version info';

# Meanwhile, the old file should be the same as before, except that it should
# now also have a list of all releases.
ok $dist_meta = $api->read_json_from($dist_file),
    'Read the older version distmeta';
$meta->{releases} = { stable => [
    {version => '0.1.2', date => '2010-12-13T23:12:41Z'},
    {version => '0.1.1', date => '2010-10-29T22:44:42Z'},
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'}
] };
is_deeply $dist_meta, $meta, 'It should be updated with all versions';

##############################################################################
# Now update the owner metadata.
my $owner_file = catfile $doc_root, qw(by owner theory.json);
file_not_exists_ok $owner_file, "$owner_file should not yet exist";
ok $indexer->update_owner($meta), 'Update the owner metadata';
file_exists_ok $owner_file, "$owner_file should now exist";

# Now make sure that it has the updated release metadata.
ok my $mir_data = $api->read_json_from(
    catfile $doc_root, qw(pgxn by owner theory.json)
),'Read the mirror owner data file';
ok my $doc_data = $api->read_json_from($owner_file),
    'Read the doc root owner data file';
$mir_data->{releases}{pair}{stable} = [
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'},
];
$mir_data->{releases}{pair}{abstract} = 'A key/value pair data type';
is_deeply $doc_data, $mir_data,
    'The doc root data should have the the metadata for this release';

# Great, now update it.
fcopy catfile(qw(t data theory-updated.json)),
      catfile($api->mirror_root, qw(by owner theory.json));
ok $indexer->update_owner($meta_011),
    'Update the owner metadata for pair 0.1.1';
$mir_data->{releases}{pair}{stable} = [
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'},
];
$mir_data->{releases}{pair}{testing} = [
    {version => '0.1.1', date => '2010-10-29T22:44:42Z'},
];
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
unshift @{ $mir_data->{releases}{pair}{stable} },
    {version => '0.1.2', date => '2010-11-03T06:23:28Z'};
ok $doc_data = $api->read_json_from($owner_file),
    'Read the doc root owner data file once more';
is_deeply $doc_data, $mir_data,
    'The doc root data should have the the metadata for 0.1.2';

##############################################################################
# Now update the tag metadata.
my $pairkw_file = catfile $doc_root, qw(by tag pair.json);
my $orderedkw_file = catfile $doc_root, qw(by tag), 'ordered pair.json';
my $keyvalkw_file = catfile $doc_root, qw(by tag), 'key value.json';
file_not_exists_ok $pairkw_file, "$pairkw_file should not yet exist";
file_not_exists_ok $orderedkw_file, "$orderedkw_file should not yet exist";
file_not_exists_ok $keyvalkw_file, "$keyvalkw_file should not yet exist";
ok $indexer->update_tags($meta), 'Update the tags';
file_exists_ok $pairkw_file, "$pairkw_file should now exist";
file_exists_ok $orderedkw_file, "$orderedkw_file should now exist";
file_not_exists_ok $keyvalkw_file, "$keyvalkw_file should still not exist";

my $pgtap = { stable => [{ version => "0.25.0", date => '2011-01-22T08:34:51Z'}] };
my $exp = {
    tag => 'pair',
    releases => {
        pair  => {
            abstract    => "A key/value pair data type",
            stable      => [
                {version => '0.1.0', date => '2010-10-19T03:59:54Z'},
            ],
        },
        pgTAP => $pgtap,
    },
};

# Check the contents of the two keywords on the doc root.
ok my $pair_data = $api->read_json_from($pairkw_file),
    "Read JSON from $pairkw_file";
is_deeply $pair_data, $exp, "$pairkw_file should have the release data";

$exp->{tag} = 'ordered pair';
delete $exp->{releases}{pgTAP};
ok my $ord_data = $api->read_json_from($orderedkw_file),
    "Read JSON from $orderedkw_file";
is_deeply $ord_data, $exp, "$orderedkw_file should have the release data";

# Now update with 0.1.1.
ok $indexer->update_tags($meta_011), 'Update the tags to 0.1.1';
file_exists_ok $keyvalkw_file, "$keyvalkw_file should now exist";

# Check the JSON data.
$exp->{tag} = 'pair';
$exp->{releases}{pair}{stable} = [
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'},
];
$exp->{releases}{pair}{testing} = [
    {version => '0.1.1', date => '2010-10-29T22:44:42Z'},
];
$exp->{releases}{pair}{abstract} = 'A key/value pair dåtå type';
$exp->{releases}{pgTAP} = $pgtap;

ok $pair_data = $api->read_json_from($pairkw_file),
    "Read JSON from $pairkw_file again";
is_deeply $pair_data, $exp, "$pairkw_file should be updated for 0.1.1";

$exp->{tag} = 'ordered pair';
delete $exp->{releases}{pgTAP};
ok $ord_data = $api->read_json_from($orderedkw_file),
    "Read JSON from $orderedkw_file again";
is_deeply $ord_data, $exp, "$orderedkw_file should be updated for 0.1.1";

$exp->{tag} = 'key value';
ok my $keyval_data = $api->read_json_from($keyvalkw_file),
    "Read JSON from $keyvalkw_file";
is_deeply $keyval_data, $exp, "$keyvalkw_file should have 0.1.1 data";

# And finally, update to 0.1.2.
ok $indexer->update_tags($meta_012), 'Update the tags to 0.1.2';

# Make sure all tags are updated.
$exp->{tag} = 'pair';
$exp->{releases}{pair}{stable} = [
    {version => '0.1.2', date => '2010-11-03T06:23:28Z'},
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'},
];
$exp->{releases}{pgTAP} = $pgtap;

ok $pair_data = $api->read_json_from($pairkw_file),
    "Read JSON from $pairkw_file once more";
is_deeply $pair_data, $exp, "$pairkw_file should be updated for 0.1.2";

$exp->{tag} = 'ordered pair';
delete $exp->{releases}{pgTAP};
ok $ord_data = $api->read_json_from($orderedkw_file),
    "Read JSON from $orderedkw_file once more";
is_deeply $ord_data, $exp, "$orderedkw_file should be updated for 0.1.2";

$exp->{tag} = 'key value';
ok $keyval_data = $api->read_json_from($keyvalkw_file),
    "Read JSON from $keyvalkw_file again";
is_deeply $keyval_data, $exp, "$keyvalkw_file should have 0.1.2 data";

##############################################################################
# Now update the extension metadata.
my $ext_file = catfile $doc_root, qw(by extension pair.json);
file_not_exists_ok $ext_file, "$ext_file should not yet exist";
ok $indexer->update_extensions($meta), 'Update the extension metadata';
file_exists_ok $ext_file, "$ext_file should now exist";

# Now make sure that it has the updated release metadata.
$exp = {
    extension => 'pair',
    latest    => 'stable',
    stable    => {
        abstract => 'A key/value pair data type',
        dist     => 'pair',
        version => '0.1.0',
    },
    versions  => {
        '0.1.0' => [
            {
                dist         => 'pair',
                release_date => '2010-10-18T15:24:21Z',
                version      => '0.1.0',
            },
        ],
    },
};
ok $doc_data = $api->read_json_from($ext_file),
    'Read the doc root extension data file';
is_deeply $doc_data, $exp,
    'The extension metadata should include the abstract and release date';

# Okay, update it with the testing release.
fcopy catfile(qw(t data pair-ext-updated.json)),
      catfile($api->mirror_root, qw(by extension pair.json));
ok $indexer->update_extensions($meta_011),
    'Update the extension metadata to 0.1.1';

$exp->{latest} = 'testing';
$exp->{testing} = {
    abstract => 'A key/value pair dåtå type',
    dist     => 'pair',
    version  => '0.1.1',
};
$exp->{versions}{'0.1.1'} = [{
    dist         => 'pair',
    release_date => '2010-10-29T22:46:45Z',
    version      => '0.1.1',
}];

ok $doc_data = $api->read_json_from($ext_file),
    'Read the doc root extension data file again';
is_deeply $doc_data, $exp,
    'The extension metadata should include the testing data';

# Add this version to a different distribution.
$meta_011->{name} = 'otherdist';
$meta_011->{version} = '0.3.0';

fcopy catfile(qw(t data pair-ext-updated2.json)),
      catfile($api->mirror_root, qw(by extension pair.json));
ok $indexer->update_extensions($meta_011),
    'Add the extension to another distribution';

ok $doc_data = $api->read_json_from($ext_file),
    'Read the doc root extension data file once again';
unshift @{ $exp->{versions}{'0.1.1'} } => {
    dist =>'otherdist',
    release_date => '2010-10-29T22:46:45Z',
    version => '0.3.0'
};
is_deeply $doc_data, $exp,
    "The second distribution's metadata should new be present";

# Great! Now update it to 0.1.2.
fcopy catfile(qw(t data pair-ext-updated3.json)),
      catfile($api->mirror_root, qw(by extension pair.json));
ok $indexer->update_extensions($meta_012),
    'Update the extension to 0.1.2.';
$exp->{latest} = 'stable';
$exp->{stable}{version} = '0.1.2';
$exp->{stable}{abstract} = 'A key/value pair dåtå type';
$exp->{versions}{'0.1.2'} =  [{
    dist         => 'pair',
    release_date => '2010-11-10T12:18:03Z',
    version      => '0.1.2',
}];
ok $doc_data = $api->read_json_from($ext_file),
    'Read the doc root extension data file one more time';
is_deeply $doc_data, $exp, 'Should now have the 0.1.3 metadata';

##############################################################################
# Make sure that add_document() calls all the necessary methods.
my $mock = Test::MockModule->new($CLASS);
my @called;
my @meths = qw(
    copy_files
    merge_distmeta
    update_owner
    update_tags
    update_extensions
);
for my $meth (@meths) {
    $mock->mock($meth => sub {
        push @called => $meth;
        is $_[1], $meta, "Meta should have been passed to $meth";
    })
}

ok $indexer->add_distribution($meta), 'Call add_distribution()';
is_deeply \@called, \@meths, 'The proper meths should have been called in order';
$mock->unmock_all;

##############################################################################
# Test update_mirror_meta().
file_not_exists_ok catfile($doc_root, qw(index.json)), 'index.json should not exist';
file_not_exists_ok catfile($doc_root, qw(meta/mirrors.json)), 'mirrors.json should not exist';
ok $indexer->update_mirror_meta, 'Update from the mirror';
file_exists_ok catfile($doc_root, qw(index.json)), 'index.json should now exist';
file_exists_ok catfile($doc_root, qw(meta/mirrors.json)), 'mirrors.json should now exist';

# Do it again, just for good measure.
ok $indexer->update_mirror_meta, 'Update from the mirror';
file_exists_ok catfile($doc_root, qw(index.json)), 'index.json should now exist';
file_exists_ok catfile($doc_root, qw(meta/mirrors.json)), 'mirrors.json should now exist';

