#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 232;
#use Test::More 'no_plan';
use File::Copy::Recursive qw(dircopy fcopy);
use File::Path qw(remove_tree);
use File::Spec::Functions qw(catfile catdir rel2abs);
use PGXN::API::Sync;
use PGXN::API::Searcher;
use Test::File;
use Test::Exception;
use Test::File::Contents;
use Test::MockModule;
use Archive::Zip;
use utf8;

my $CLASS;
BEGIN {
    $File::Copy::Recursive::KeepMode = 0;
    $CLASS = 'PGXN::API::Indexer';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    new
    verbose
    to_index
    libxml
    index_dir
    schemas
    indexer_for
    update_root_json
    copy_from_mirror
    parse_from_mirror
    add_distribution
    copy_files
    merge_distmeta
    update_user
    merge_user
    update_tags
    update_extensions
    finalize
    update_user_lists
    parse_docs
    mirror_file_for
    doc_root_file_for
    _idx_distmeta
    _get_user_name
    _strip_html
    _update_releases
    _index_user
    _index
    _rollback
    _commit
    _uri_for
    _source_files
    _readme
    _clean_html_body
);

my $api = PGXN::API->instance;
my $doc_root = catdir 't', 'test_doc_root';
$api->doc_root($doc_root);
END { remove_tree $doc_root }

# "Sync" from a "mirror."
dircopy catdir(qw(t root)), $api->mirror_root;

# Mock indexing stuff.
my $mock = Test::MockModule->new($CLASS);
$mock->mock(_commit => sub { shift });

##############################################################################
# Test update_root_json().
my $indexer = new_ok $CLASS;
file_not_exists_ok catfile($doc_root, qw(index.json)), 'index.json should not exist';
ok $indexer->update_root_json, 'Update from the mirror';
file_exists_ok catfile($doc_root, qw(index.json)), 'index.json should now exist';

# Make sure it has all the templates we need.
my $tmpl = $api->read_json_from(catfile qw(t root index.json));
$tmpl->{source} = "/src/{dist}/{dist}-{version}/";
$tmpl->{doc} = "/dist/{dist}/{version}/{+doc}.html";
$tmpl->{search} = '/search/{in}/';
$tmpl->{userlist} = '/users/{char}.json';
is_deeply $api->read_json_from(catfile($doc_root, qw(index.json))), $tmpl,
    'index.json should have additional templates';

# Make sure that PGXN::API is aware of them.
is_deeply [sort keys %{ $api->uri_templates } ],
    [qw(dist doc download extension meta mirrors readme search source
        spec stats tag user userlist)],
    'PGXN::API should see the additional templates';

# Do it again, just for good measure.
ok $indexer->update_root_json, 'Update from the mirror';
file_exists_ok catfile($doc_root, qw(index.json)), 'index.json should now exist';

##############################################################################
# Test copy_from_mirror().
my $spec = catfile $api->doc_root, qw(meta spec.txt);
file_not_exists_ok $spec, 'Doc root spec.txt should not exist';
ok $indexer->copy_from_mirror('meta/spec.txt'), 'Copy spec.txt';
file_exists_ok $spec, 'Doc root spec.txt should now exist';
files_eq $spec, catfile($api->mirror_root, qw(meta spec.txt)),
    'And it should be a copy from the mirror';

##############################################################################
# Test parse_from_mirror().
my $htmlspec = catfile $api->doc_root, qw(meta spec.html);
file_not_exists_ok $htmlspec, 'Doc root spec.html should not exist';
ok $indexer->parse_from_mirror('meta/spec.txt'), 'Parse spec.txt';
file_exists_ok $htmlspec, 'Doc root spec.html should now exist';
file_contents_like $htmlspec, qr{<pre>Name}, 'And it should look like HTML';

# Try it with a format.
ok $indexer->parse_from_mirror('meta/spec.txt', 'Multimarkdown'),
    'Parse spec.txt as MultiMarkdown';
file_contents_like $htmlspec, qr{<h1 id="Name">Name</h1>},
    'And it should look like Multimarkdown-generated HTML';

##############################################################################
# Let's index pair-0.1.0.
my $meta = $api->read_json_from(
    catfile $api->mirror_root, qw(dist pair 0.1.0 META.json)
);

file_not_exists_ok(
    catfile($api->doc_root, qw(dist pair 0.1.0), 'pair-0.1.0.pgz'),
    'pair-0.1.0.pgz should not yet exist'
);

file_not_exists_ok(
    catfile($api->doc_root, qw(dist pair 0.1.0), 'README.txt'),
    'README.txt should not yet exist'
);

my $params  = { meta => $meta };
ok $indexer->copy_files($params), 'Copy files';

file_exists_ok(
    catfile($api->doc_root, qw(dist pair 0.1.0), "pair-0.1.0.pgz"),
    "pair-0.1.0.pgz should now exist"
);
file_not_exists_ok(
    catfile($api->doc_root, qw(dist pair 0.1.0), "README.txt"),
    "pair/0.1.0/README.txt still should not exist"
);

# Make sure we get an error when we try to copy a file that does't exist.
$meta->{name} = 'nonexistent';
my $src = catfile $api->mirror_root, qw(dist nonexistent 0.1.0 nonexistent-0.1.0.pgz);
my $dst = catfile $api->doc_root,    qw(dist nonexistent 0.1.0 nonexistent-0.1.0.pgz);
throws_ok { $indexer->copy_files($params ) }
    qr{Cannot copy \Q$src\E to \Q$dst\E: No such file or directory},
    'Should get exception with file names for bad copy';
$meta->{name} = 'pair';

##############################################################################
# Now merge the distribution metadata files.
my $dist_file = catfile $api->doc_root, qw(dist pair 0.1.0 META.json);
my $dist   = catfile $api->doc_root, qw(dist pair.json);
my $docs = { 'docs/pair' => {
    title => 'pair',
    abstract => 'Key value pair',
}};
$mock->mock(parse_docs => $docs);

# Set up zip archive.
my $zip       = Archive::Zip->new;
$zip->read(rel2abs catfile qw(t root dist pair 0.1.0 pair-0.1.0.pgz));
$params->{zip} = $zip;

file_not_exists_ok $dist_file, 'pair-0.1.0.json should not yet exist';
file_not_exists_ok $dist,   'pair.json should not yet exist';

ok $indexer->merge_distmeta($params), 'Merge the distmeta';

file_exists_ok $dist_file, 'pair-0.1.0.json should now exist';
file_exists_ok $dist,      'pair.json should now exist';

my $readme = $zip->memberNamed('pair-0.1.0/README.md')->contents;
utf8::decode $readme;
$readme =~ s/^\s+//;
$readme =~ s/\s+$//;
$readme =~ s/[\t\n\r]+|\s{2,}/ /gms;

is_deeply shift @{ $indexer->to_index->{dists} }, {
    abstract    => 'A key/value pair data type',
    date        => '2010-10-18T15:24:21Z',
    description => "This library contains a single PostgreSQL extension, a key/value pair data type called `pair`, along with a convenience function for constructing key/value pairs.",
    dist        => 'pair',
    key         => 'pair',
    user        => 'theory',
    readme      => $readme,
    tags        => "ordered pair\003pair",
    user_name   => 'David E. Wheeler',
    version     => '0.1.0',
}, 'Should have pair 0.1.0 queued for indexing';

# The two files should be identical.
files_eq_or_diff $dist_file, $dist,
    'pair-0.1.0.json and pair.json should be the same';

# Our metadata should have new info.
is_deeply $meta->{releases},
    { stable => [{version => '0.1.0', date => '2010-10-19T03:59:54Z'}] },
    'Meta should now have release info';
is_deeply $meta->{special_files}, [qw(README.md META.json Makefile)],
    'And it should have special files';
is_deeply $meta->{docs}, $docs, 'Should have docs from parse_docs';
is $meta->{provides}{pair}{doc}, 'docs/pair',
    'Should have extension doc path in provides';

# So have a look at the contents.
ok my $dist_meta = $api->read_json_from($dist_file),
    'Read the merged distmeta';
is_deeply $dist_meta, $meta, 'And it should be the merged metadata';

# Now update with 0.1.1. "Sync" the updated pair.json.
fcopy catfile(qw(t data pair-updated.json)),
      catfile($api->mirror_root, qw(dist pair.json));

# Set up the 0.1.1 metadata and zip archive.
my $meta_011 = $api->read_json_from(
    catfile $api->mirror_root, qw(dist pair 0.1.1 META.json)
);
my $zip_011 = Archive::Zip->new;
$zip_011->read(rel2abs catfile qw(t root dist pair 0.1.1 pair-0.1.1.pgz));

my $dist_011_file = catfile $api->doc_root, qw(dist pair 0.1.1 META.json);
file_not_exists_ok $dist_011_file, 'pair/0.1.1/META.json should not yet exist';
$params->{meta} = $meta_011;
$params->{zip} = $zip_011;
ok $indexer->merge_distmeta($params), 'Merge the distmeta';
file_exists_ok $dist_011_file, 'pair/0.1.1/META.json should now exist';

is_deeply $indexer->to_index->{dists}, [],
    'Testing distribution should not be queued for indexing';

files_eq_or_diff $dist_011_file, $dist,
    'pair/0.1.1/META.json and pair.json should be the same';

is_deeply $meta_011->{releases}, { stable => [
    {version => '0.1.1', date => '2010-10-29T22:44:42Z'},
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'}
], testing => [
    {version => '0.1.2', date => '2010-12-13T23:12:41Z'},
] }, 'We should have the release data';
is_deeply $meta_011->{special_files},
    [qw(Changes README.md META.json Makefile)],
    'And it should have special files';

ok $dist_meta = $api->read_json_from($dist_011_file),
    'Read the 0.1.1 merged distmeta';
# 0.1.2 has been released but we haven't copied it to the doc root yet.
is_deeply $dist_meta, $meta_011,
    'And it should be the merged with all version info';

# Meanwhile, the old file should be the same as before, except that it should
# now also have a list of all releases.
ok $dist_meta = $api->read_json_from($dist_file),
    'Read the older version distmeta';
$meta->{releases} = { stable => [
    {version => '0.1.1', date => '2010-10-29T22:44:42Z'},
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'}
], testing => [
    {version => '0.1.2', date => '2010-12-13T23:12:41Z'},
] };
is_deeply $dist_meta, $meta, 'It should be updated with all versions';
$mock->unmock('parse_docs');

##############################################################################
# Now update the user metadata.
my $user_file = catfile $doc_root, qw(user theory.json);
file_not_exists_ok $user_file, "$user_file should not yet exist";
$params->{meta} = $meta;
ok $indexer->update_user($params), 'Update the user metadata';
file_exists_ok $user_file, "$user_file should now exist";

is_deeply shift @{ $indexer->to_index->{users} }, {
    details  => '',
    email    => 'david@justatheory.com',
    key      => 'theory',
    name     => 'David E. Wheeler',
    uri      => 'http://justatheory.com/',
    user     => 'theory',
}, 'Should have index data';

# Now make sure that it has the updated release metadata.
ok my $mir_data = $api->read_json_from(
    catfile $doc_root, qw(mirror user theory.json)
),'Read the mirror user data file';
ok my $doc_data = $api->read_json_from($user_file),
    'Read the doc root user data file';
$mir_data->{releases}{pair}{abstract} = 'A key/value pair data type';

is_deeply $doc_data, $mir_data,
    'The doc root data should have the metadata for this release';

# Great, now update it.
fcopy catfile(qw(t data theory-updated.json)),
      catfile($api->mirror_root, qw(user theory.json));
$params->{meta} = $meta_011;
ok $indexer->update_user($params),
    'Update the user metadata for pair 0.1.1';
is_deeply $indexer->to_index->{users}, [],
    'Should have no index update for test dist';

$mir_data->{releases}{pair}{stable} = [
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'},
];
$mir_data->{releases}{pair}{testing} = [
    {version => '0.1.1', date => '2010-10-29T22:44:42Z'},
];
$mir_data->{releases}{pair}{abstract} = 'A key/value pair dåtå type';
ok $doc_data = $api->read_json_from($user_file),
    'Read the doc root user data file again';
is_deeply $doc_data, $mir_data,
    'The doc root data should have the metadata for 0.1.1';

# Now do another stable release.
fcopy catfile(qw(t data theory-updated2.json)),
      catfile($api->mirror_root, qw(user theory.json));
my $meta_012 = $api->read_json_from(
    catfile $api->mirror_root, qw(dist pair 0.1.2 META.json)
);
$params->{meta} = $meta_012;
my $zip_012 = Archive::Zip->new;
$zip_012->read(rel2abs catfile qw(t root dist pair 0.1.2 pair-0.1.2.pgz));
$params->{zip} = $zip_012;
ok $indexer->merge_distmeta($params), 'Merge the 0.1.2 distmeta';
ok $indexer->update_user($params),
    'Update the user metadata for pair 0.1.2';
unshift @{ $mir_data->{releases}{pair}{stable} },
    {version => '0.1.2', date => '2010-11-03T06:23:28Z'};
ok $doc_data = $api->read_json_from($user_file),
    'Read the doc root user data file once more';
is_deeply $doc_data, $mir_data,
    'The doc root data should have the metadata for 0.1.2';

my $readme_012 = $zip_012->memberNamed('pair-0.1.2/README.md')->contents;
utf8::decode $readme_012;
$readme_012 =~ s/^\s+//;
$readme_012 =~ s/\s+$//;
$readme_012 =~ s/[\t\n\r]+|\s{2,}/ /gms;

is_deeply shift @{ $indexer->to_index->{dists} }, {
    abstract    => 'A key/value pair dåtå type',
    date        => '2010-11-10T12:18:03Z',
    description => 'This library contains a single PostgreSQL extension, a key/value pair data type called `pair`, along with a convenience function for constructing pairs.',
    dist        => 'pair',
    key         => 'pair',
    user        => 'theory',
    readme      => $readme_012,
    tags        => "ordered pair\003pair\003key value",
    user_name   => 'David E. Wheeler',
    version     => "0.1.2",
}, 'New version should be queued for indexing';

is_deeply shift @{ $indexer->to_index->{users} }, {
    details => '',
    email   => 'david@justatheory.com',
    key     => 'theory',
    name    => 'David E. Wheeler',
    uri     => 'http://justatheory.com/',
    user    => 'theory',
}, 'Should have user index data again';

##############################################################################
# Now update the tag metadata.
my $pairkw_file = catfile $doc_root, qw(tag pair.json);
my $orderedkw_file = catfile $doc_root, qw(tag), 'ordered pair.json';
my $keyvalkw_file = catfile $doc_root, qw(tag), 'key value.json';
file_not_exists_ok $pairkw_file, "$pairkw_file should not yet exist";
file_not_exists_ok $orderedkw_file, "$orderedkw_file should not yet exist";
file_not_exists_ok $keyvalkw_file, "$keyvalkw_file should not yet exist";
$params->{meta} = $meta;
ok $indexer->update_tags($params), 'Update the tags';
file_exists_ok $pairkw_file, "$pairkw_file should now exist";
file_exists_ok $orderedkw_file, "$orderedkw_file should now exist";
file_not_exists_ok $keyvalkw_file, "$keyvalkw_file should still not exist";

is_deeply shift @{ $indexer->to_index->{tags} }, {
    key => 'ordered pair',
    tag => 'ordered pair',
}, 'Should have "ordered pair" index data';

is_deeply shift @{ $indexer->to_index->{tags} }, {
    key => 'pair',
    tag => 'pair',
}, 'Should have "pair" index data';

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
$params->{meta} = $meta_011;
fcopy catfile(qw(t data pair-tag-updated.json)),
      catfile($api->mirror_root, qw(tag pair.json));
ok $indexer->update_tags($params), 'Update the tags to 0.1.1';
file_exists_ok $keyvalkw_file, "$keyvalkw_file should now exist";
is_deeply $indexer->to_index, {
    map { $_ => [] } qw(docs dists extensions users tags)
}, 'Should have no index updates for test dist';

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
delete $exp->{releases}{pair}{testing};
ok $ord_data = $api->read_json_from($orderedkw_file),
    "Read JSON from $orderedkw_file again";
is_deeply $ord_data, $exp, "$orderedkw_file should be updated for 0.1.1";

$exp->{tag} = 'key value';
unshift @{ $exp->{releases}{pair}{stable} } =>
    {"version" => "0.1.1", "date" => "2010-10-29T22:44:42Z"};

ok my $keyval_data = $api->read_json_from($keyvalkw_file),
    "Read JSON from $keyvalkw_file";
is_deeply $keyval_data, $exp, "$keyvalkw_file should have 0.1.1 data";

# And finally, update to 0.1.2.
$params->{meta} = $meta_012;
fcopy catfile(qw(t data pair-tag-updated2.json)),
      catfile($api->mirror_root, qw(tag pair.json));
fcopy catfile(qw(t data ordered-tag-updated.json)),
      catfile($api->mirror_root, qw(tag), 'ordered pair.json');
fcopy catfile(qw(t data kv-tag-updated.json)),
      catfile($api->mirror_root, qw(tag), 'key value.json');
ok $indexer->update_tags($params), 'Update the tags to 0.1.2';

is_deeply shift @{ $indexer->to_index->{tags} }, {
    key => 'ordered pair',
    tag => 'ordered pair',
}, 'Should have "ordered pair" index data';

is_deeply shift @{ $indexer->to_index->{tags} }, {
    key => 'pair',
    tag => 'pair',
}, 'Should have "pair" index data';

is_deeply shift @{ $indexer->to_index->{tags} }, {
    key => 'key value',
    tag => 'key value',
}, 'Should have "key value" index data';

# Make sure all tags are updated.
$exp->{tag} = 'pair';
$exp->{releases}{pair}{stable} = [
    {version => '0.1.2', date => '2010-11-03T06:23:28Z'},
    {version => '0.1.0', date => '2010-10-19T03:59:54Z'},
];
$exp->{releases}{pair}{testing} = [
    {version => '0.1.1', date => '2010-10-29T22:44:42Z'},
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
$mock->mock(_idx_extdoc => sub { "Doc for $_[2]" });
my $ext_file = catfile $doc_root, qw(extension pair.json);
file_not_exists_ok $ext_file, "$ext_file should not yet exist";
$params->{meta} = $meta;
ok $indexer->update_extensions($params), 'Update the extension metadata';
file_exists_ok $ext_file, "$ext_file should now exist";

is_deeply shift @{ $indexer->to_index->{extensions} }, {
    abstract  => 'A key/value pair data type',
    date      => '2010-10-18T15:24:21Z',
    dist      => 'pair',
    doc       => 'docs/pair',
    extension => 'pair',
    key       => 'pair',
    user      => 'theory',
    user_name => 'David E. Wheeler',
    version   => '0.1.0',
}, 'Should have extension index data';

# Now make sure that it has the updated release metadata.
$exp = {
    extension => 'pair',
    latest    => 'stable',
    stable    => {
        abstract => 'A key/value pair data type',
        doc      => 'docs/pair',
        dist     => 'pair',
        version => '0.1.0',
        sha1     => '1234567890abcdef1234567890abcdef12345678',
    },
    versions  => {
        '0.1.0' => [
            {
                dist         => 'pair',
                date => '2010-10-18T15:24:21Z',
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
      catfile($api->mirror_root, qw(extension pair.json));
$params->{meta} = $meta_011;
ok $indexer->update_extensions($params),
    'Update the extension metadata to 0.1.1';
is_deeply $indexer->to_index, {
    map { $_ => [] } qw(docs dists extensions users tags)
}, 'Should have no indexed extensions for testing dist';

$exp->{latest} = 'testing';
$exp->{testing} = {
    abstract => 'A key/value pair dåtå type',
    doc      => 'docs/pair',
    dist     => 'pair',
    version  => '0.1.1',
    sha1     => 'c552c961400253e852250c5d2f3def183c81adb3',
};
$exp->{versions}{'0.1.1'} = [{
    dist         => 'pair',
    date => '2010-10-29T22:46:45Z',
    version      => '0.1.1',
}];

ok $doc_data = $api->read_json_from($ext_file),
    'Read the doc root extension data file again';
is_deeply $doc_data, $exp,
    'The extension metadata should include the testing data';

# Add this version to a different distribution.
$meta_011->{name} = 'otherdist';
$meta_011->{version} = '0.3.0';
$meta_011->{release_status} = 'stable';

fcopy catfile(qw(t data pair-ext-updated2.json)),
      catfile($api->mirror_root, qw(extension pair.json));
ok $indexer->update_extensions($params),
    'Add the extension to another distribution';

is_deeply shift @{ $indexer->to_index->{extensions} }, {
    abstract    => 'A key/value pair dåtå type',
    date        => '2010-10-29T22:46:45Z',
    dist        => 'otherdist',
    doc       => 'docs/pair',
    extension   => 'pair',
    key         => 'pair',
    user        => 'theory',
    user_name   => 'David E. Wheeler',
    version     => '0.1.2',
}, 'Should have otherdidst extension index data';

ok $doc_data = $api->read_json_from($ext_file),
    'Read the doc root extension data file once again';
unshift @{ $exp->{versions}{'0.1.1'} } => {
    dist =>'otherdist',
    date => '2010-10-29T22:46:45Z',
    version => '0.3.0'
};
$exp->{stable} = {
    abstract => 'A key/value pair dåtå type',
    doc      => 'docs/pair',
    dist     => 'pair',
    sha1     => 'cebefd23151b4b797239646f7ae045b03d028fcf',
    version  => '0.1.2',
};
is_deeply $doc_data, $exp,
    "The second distribution's metadata should new be present";

# Great! Now update it to 0.1.2.
fcopy catfile(qw(t data pair-ext-updated3.json)),
      catfile($api->mirror_root, qw(extension pair.json));
$params->{meta} = $meta_012;
ok $indexer->update_extensions($params),
    'Update the extension to 0.1.2.';

is_deeply shift @{ $indexer->to_index->{extensions} }, {
    abstract  => 'A key/value pair dåtå type',
    date      => '2010-11-10T12:18:03Z',
    dist      => 'pair',
    doc       => '',
    extension => 'pair',
    key       => 'pair',
    user      => 'theory',
    user_name => 'David E. Wheeler',
    version   => '0.1.2',
}, 'Should have extension index data again';

delete $exp->{stable}{doc};
$exp->{latest} = 'stable';
$exp->{stable}{version} = '0.1.2';
$exp->{stable}{abstract} = 'A key/value pair dåtå type';
$exp->{stable}{sha1} = 'cebefd23151b4b797239646f7ae045b03d028fcf';
$exp->{versions}{'0.1.2'} =  [{
    dist    => 'pair',
    date    => '2010-11-10T12:18:03Z',
    version => '0.1.2',
}];
ok $doc_data = $api->read_json_from($ext_file),
    'Read the doc root extension data file one more time';
is_deeply $doc_data, $exp, 'Should now have the 0.1.3 metadata';

##############################################################################
# Test parse_docs().
my $sync = PGXN::API::Sync->new(source => 'rsync://localhost/pgxn');
my $pgz = catfile qw(dist pair 0.1.0 pair-0.1.0.pgz);

$params->{meta}   = $meta;
ok $params->{zip} = $sync->unzip($pgz, {name => 'pair'}), "Unzip $pgz";

my $doc_dir = catdir $doc_root, qw(dist pair 0.1.0);
$readme = catfile $doc_dir, 'readme.html';
my $doc = catfile $doc_dir, 'doc', 'pair.html';
file_exists_ok $doc_dir, 'Directory dist/pair/0.1.0 should exist';
file_not_exists_ok $readme, 'dist/pair/0.1.0/README.txt should not exist';
file_not_exists_ok $doc, 'dist/pair/pair/0.1.0/doc/pair.html should not exist';

is_deeply $indexer->to_index, {
    map { $_ => [] } qw(docs dists extensions users tags)
}, 'Should start with no docs to index';

$meta->{docs} = $indexer->parse_docs($params);
is_deeply $meta->{docs}, {
    'README'   => { title => 'pair 0.1.0' },
    'doc/pair' => { title => 'pair 0.1.0', abstract => 'A key/value pair data type' },
}, 'Should get array of docs from parsing';
ok !exists $meta->{provides}{README},
    'Should hot have autovivified README into provides';

ok my $body = delete $indexer->to_index->{docs}[0]{body},
    'Should have document body';

like $body, qr/^pair 0[.]1[.]0\b/ms, 'Should look like plain text';
unlike $body, qr/<[^>]+>/, 'Should have nothing that looks like HTML';
unlike $body, qr/&[^;];/, 'Should have nothing that looks like an entity';
unlike $body, qr/    Contents/ms, 'Should not have contents';

is_deeply shift @{ $indexer->to_index->{docs} }, {
    abstract  => 'A key/value pair data type',
    date      => '2010-10-18T15:24:21Z',
    dist      => 'pair',
    key       => 'pair/doc/pair',
    user      => 'theory',
    doc       => 'doc/pair',
    title     => 'pair 0.1.0',
    user_name => 'David E. Wheeler',
    version   => '0.1.0',
}, 'Should have document data for indexing';

is_deeply $indexer->to_index->{docs}, [], 'Should be no other documents to index';

file_exists_ok $doc_dir, 'Directory dist/pair/pair-0.1.0 should now exist';
file_exists_ok $readme, 'dist/pair/pair/0.1.0/readme.html should now exist';
file_exists_ok $doc, 'dist/pair/pair-0.1.0/doc/pair.html should now exist';
file_contents_like $readme, qr{\Q<h1 id="pair.0.1.0">pair 0.1.0</h1>},
    'readme.html should have HTML';
file_contents_unlike $readme, qr{<html}i, 'readme.html should have no html element';
file_contents_unlike $readme, qr{<body}i, 'readme.html should have no body element';
file_contents_like $doc, qr{\Q<h1 id="pair.0.1.0">pair 0.1.0},
    'Doc should have preformatted HTML';
file_contents_unlike $doc, qr{<html}i, 'Doc should have no html element';
file_contents_unlike $doc, qr{<body}i, 'Doc should have no body element';

# Make sure we skip files that should not be indexed.
$meta->{no_index} = { file => ['doc/pair.md'] };
$docs = $indexer->parse_docs($params);
is_deeply $docs, {
    'README'   => { title => 'pair 0.1.0' },
}, 'Doc parser should ignore no_index-specified doc file';

$meta->{no_index} = { directory => ['doc']};
$docs = $indexer->parse_docs($params);
is_deeply $docs, {
    'README'   => { title => 'pair 0.1.0' },
}, 'Doc parser should ignore no_index-specified doc directory';

delete $meta->{no_index};

##############################################################################
# Make sure that add_document() calls all the necessary methods.
my @called;
my @meths = qw(
    copy_files
    merge_distmeta
    update_user
    update_tags
    update_extensions
);
for my $meth (@meths) {
    $mock->mock($meth => sub {
        push @called => $meth;
        is $_[1], $params, "Params should have been passed to $meth";
    })
}

$params->{meta} = $meta;
ok $indexer->add_distribution($params), 'Call add_distribution()';
is_deeply \@called, \@meths, 'The proper meths should have been called in order';
$mock->unmock_all;

##############################################################################
# Make sure transaction stuff works.
ok !$indexer->_rollback, 'Rollback';
is_deeply $indexer->to_index, {
    map { $_ => [] } qw(docs dists extensions users tags)
}, 'Should start with no docs to index';
$doc = {
    key      => 'foo',
    dist     => 'explain',
    abstract => 'explanation: 0.1.3, 0.2.4',
};

ok $indexer->_index(dists =>$doc), 'Index a doc';
is_deeply $indexer->to_index->{dists}, [$doc], 'Should have it in docs';
ok !$indexer->_rollback, 'Rollback should return false';
is_deeply $indexer->to_index, {
    map { $_ => [] } qw(docs dists extensions users tags)
}, 'Should have no docs to index again';

# Test full text search indexing.
ok $indexer->_index(dists => $doc), 'Index a doc again';
file_not_exists_ok catdir($doc_root, '_index'), 'Should not have index dir yet';

isa_ok $indexer->indexer_for($_), 'KinoSearch::Index::Indexer', "$_ indexer"
    for qw(docs dists extensions users tags);
ok $indexer->_commit, 'Commit that doc';
file_exists_ok catdir($doc_root, '_index'), 'Should now have index dir';
is_deeply $indexer->to_index, {
    map { $_ => [] } qw(docs dists extensions users tags)
}, 'Should once again have no docs to index';

##############################################################################
# Test _get_user_name().
is $indexer->_get_user_name({ user => 'theory'}), 'David E. Wheeler',
    '_get_user_name() should work';
is $indexer->_get_user_name({ user => 'theory'}), 'David E. Wheeler',
    '_get_user_name() should return same name for same nick';
is $indexer->_get_user_name({user => 'fred'}), 'Fred Flintstone',
    '_get_user_name() should return diff name for diff nick';

##############################################################################
# Time to actually add some stuff to the index.
$mock->unmock_all;

$params = { meta => $meta, zip => $zip };
ok $indexer->add_distribution($params), 'Index pair 0.1.0';

ok my $searcher = PGXN::API::Searcher->new($doc_root), 'Instantiate a searcher';

# Let's search it!
ok my $res = $searcher->search(query => 'data', in => 'dists'),
    'Search dists for "data"';
is $res->{count}, 1, 'Should have one result';
is $res->{hits}[0]{abstract}, 'A key/value pair data type',
    'It should have the distribution';
is $res->{hits}[0]{version}, '0.1.0', 'It should be 0.1.0';

# Search the docs.
ok $res = $searcher->search(query => 'composite', in => 'docs'),
    'Search docs for "composite"';
is $res->{count}, 1, 'Should have one result';
is $res->{hits}[0]{abstract}, 'A key/value pair data type',
    'It should have the abstract';
like $res->{hits}[0]{excerpt}, qr{\Qtwo-value <strong>composite</strong> type},
    'It should have the excerpt';
is $res->{hits}[0]{dist}, 'pair', 'It should be in dist "pair"';
is $res->{hits}[0]{version}, '0.1.0', 'It should be in 0.1.0';


##############################################################################
# Now index 0.1.1 (testing).
$meta_011 = $api->read_json_from(
    catfile $api->mirror_root, qw(dist pair 0.1.1 META.json)
);
$pgz = catfile qw(dist pair 0.1.1 pair-0.1.1.pgz);
$params->{meta}   = $meta_011;
ok $params->{zip} = $sync->unzip($pgz, {name => 'pair'}), "Unzip $pgz";
ok $indexer->add_distribution($params), 'Index pair 0.1.1';

# The previous stable release should still be indxed.
ok $searcher = PGXN::API::Searcher->new($doc_root), 'Instantiate another searcher';
ok $res = $searcher->search(query => 'data', in => 'dists'),
    'Search dists for "data" again';
is $res->{count}, 1, 'Should have one result';
is $res->{hits}[0]{abstract}, 'A key/value pair data type',
    'It should have the distribution';
is $res->{hits}[0]{version}, '0.1.0', 'It should still be 0.1.0';

# Search docs.
ok $res = $searcher->search(query => 'composite'),
    'Search docs for "composite" again';
is $res->{count}, 1, 'Should also have one result';
is $res->{hits}[0]{abstract}, 'A key/value pair data type',
    'It should have the same abstract';
like $res->{hits}[0]{excerpt}, qr{\Qtwo-value <strong>composite</strong> type},
    'It should have the same excerpt';
is $res->{hits}[0]{dist}, 'pair', 'It should still be in dist "pair"';
is $res->{hits}[0]{version}, '0.1.0', 'It should still be in 0.1.0';

##############################################################################
# Make 0.1.1 stable and try again.
$meta_011->{release_status} = 'stable';
ok $indexer->add_distribution($params), 'Index pair 0.1.1 stable';

# Now it should be updated.
ok $searcher = PGXN::API::Searcher->new($doc_root), 'Instantiate the searcher';
ok $res = $searcher->search(query => 'dåtå', in => 'dists'),
    'Search dists for "dåtå"';
is $res->{count}, 1, 'Should have one result';
is $res->{hits}[0]{abstract}, 'A key/value pair dåtå type',
    'It should have the distribution';
is $res->{hits}[0]{version}, '0.1.1', 'It should still be 0.1.1';

# The query for "data" should stil return the one record.
ok $res = $searcher->search(query => 'data', in => 'dists'),
    'Search dists for "data" one last time';
is $res->{count}, 1, 'Should have one result';
is $res->{hits}[0]{abstract}, 'A key/value pair dåtå type',
    'It should have the distribution';
is $res->{hits}[0]{version}, '0.1.1', 'It should still be 0.1.1';

# Search docs.
ok $res = $searcher->search(query => 'composite'),
    'Search docs for "composite" once more';
is $res->{count}, 1, 'Should again have one result';
is $res->{hits}[0]{abstract}, 'A key/value pair dåtå type',
    'It should have the updated abstract';
like $res->{hits}[0]{excerpt}, qr{\Qtwo-value <strong>composite</strong> type},
    'It should have the same excerpt';
is $res->{hits}[0]{dist}, 'pair', 'It should still be in dist "pair"';
is $res->{hits}[0]{version}, '0.1.1', 'It should now be in 0.1.1';

##############################################################################
# Test update_user_lists(). Add another user name.
my $unames = $indexer->_user_names;
$unames->{Tom} = 'Tom Lane';

my $f = catfile($doc_root, 'users', 'f.json');
my $t = catfile($doc_root, 'users', 't.json');
file_not_exists_ok $f, 'f.json should not exist';
file_not_exists_ok $t, 't.json should not exist';
ok $indexer->update_user_lists, 'Update user lists';
file_exists_ok $f, 'f.json should now exist';
file_exists_ok $t, 't.json should now exist';
my $tdata = $api->read_json_from($t);
is_deeply $tdata, [
    { user => 'theory', name => 'David E. Wheeler' },
    { user => 'Tom',    name => 'Tom Lane' },
], 't.json should have both users';
my $fdata = $api->read_json_from($f);
is_deeply $fdata, [
    { user => 'fred', name => 'Fred Flintstone' },
], 'f.json should have fred';

# Update tom and David and add a new T name.
delete $unames->{Tom};
$unames->{tom} = 'Tom G. Lane';
$unames->{tony} = 'Tony Vanilla';

ok $indexer->update_user_lists, 'Update user lists again';
$tdata = $api->read_json_from($t);
is_deeply $tdata, [
    { user => 'theory', name => 'David E. Wheeler' },
    { user => 'tom',    name => 'Tom G. Lane' },
    { user => 'tony',   name => 'Tony Vanilla' },
], 't.json should have the updated user info';

##############################################################################
# Now test user merging.
my $fred = catfile $doc_root, qw(user fred.json);
file_not_exists_ok $fred, 'fred.json should not exist';

# Should ignore user in user_names.
ok $indexer->merge_user('fred'), 'Merge fred.json';
file_not_exists_ok $fred, 'fred.json still should not exist';

# Remove and update again.
delete $indexer->_user_names->{fred};
ok $indexer->merge_user('fred'), 'Merge fred.json';
file_exists_ok $fred, 'fred.json should now exist';
is $indexer->_user_names->{fred}, 'Fred Flintstone',
    'And Fred should be back in the user name lookup';
is_deeply $api->read_json_from($fred), {
    email    => 'fred@flintstone.com',
    name     => 'Fred Flintstone',
    nickname => 'fred',
    releases => {},
    twitter  => 'fred',
    uri      => "http://fred.flintstone.com/"
}, 'And it should have all the necessary data';

is_deeply shift @{ $indexer->to_index->{users} }, {
    details  => 'fred',
    name     => 'Fred Flintstone',
    uri      => 'http://fred.flintstone.com/',
    email    => 'fred@flintstone.com',
    key      => 'fred',
    user     => 'fred',
}, 'Should have index data for Fred';

# Update theory on the mirror.
my $theory = catfile $api->mirror_root, qw(user theory.json);
my $data   = $api->read_json_from($theory);
$data->{name} = 'David Wheeler';
$data->{uri} = 'http://www.justatheory.com/';
$api->write_json_to($theory, $data);

# Now merge theory.
delete $indexer->_user_names->{theory};
ok $indexer->merge_user('theory'), 'Merge theory.json';
is $indexer->_user_names->{theory}, 'David Wheeler',
    'And Theory should be back in the user name lookup';
is_deeply $api->read_json_from(catfile $doc_root, qw(user theory.json)), {
    email    => 'david@justatheory.com',
    name     => 'David Wheeler',
    nickname => 'theory',
    releases => {
        pair   => {
            abstract => "A key/value pair d\xE5t\xE5 type",
            stable   => [
                { date => "2010-11-03T06:23:28Z", version => "0.1.2" },
                { date => "2010-10-19T03:59:54Z", version => "0.1.0" },
            ],
            testing  => [{ date => "2010-10-29T22:44:42Z", version => "0.1.1" }],
        },
        pgTAP  => {
            stable => [{ date => "2011-02-02T03:25:17Z", version => "0.25.0" }],
        },
        semver => {
            stable => [{ date => "2011-02-05T19:31:38Z", version => "0.2.0" }],
        },
    },
    uri      => "http://www.justatheory.com/"
}, 'And it should have the updated data';

is_deeply shift @{ $indexer->to_index->{users} }, {
    details  => '',
    email    => 'david@justatheory.com',
    key      => 'theory',
    name     => 'David Wheeler',
    uri      => 'http://www.justatheory.com/',
    user     => 'theory',
}, 'Should have updated index data for Theory';

##############################################################################
# Test finalize().
@called = ();
$mock->mock(update_user_lists => sub { push @called, 'update_user_lists' });
$mock->mock(_commit => sub { push @called, '_commit' });
ok $indexer->finalize, 'Call finalize()';
is_deeply \@called, [qw(update_user_lists _commit)],
    'update_user_lists() and commit() should have been called';
