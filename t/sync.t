#!/usr/bin/env perl -w

use strict;
use warnings;
#use Test::More tests => 58;
use Test::More 'no_plan';
use File::Spec::Functions qw(catfile catdir tmpdir);
use Test::MockModule;
use Test::Output;
use File::Path qw(remove_tree);
use File::Copy::Recursive qw(dircopy fcopy);
use Test::File;
use Fcntl qw(:mode);

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API::Sync';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    new
    run
    rsync_path
    log_file
    run_rsync
    update_index
    validate_distribution
    download_for
    digest_for
    unzip
);

my $pgxn   = PGXN::API->instance;
$pgxn->doc_root(catdir 't', 'test_doc_root');
END { remove_tree $pgxn->doc_root }

##############################################################################
# Test rsync.
my $attr = $CLASS->meta->get_attribute('rsync_path');
is $attr->default, 'rsync', 'Default rsync_path should be "rsync"';

my $rsync = catfile qw(t bin), 'testrsync' . (PGXN::API::Sync::WIN32 ? '.bat' : '');
ok my $sync = $CLASS->new(
    source     => 'rsync://localhost/pgxn',
    rsync_path => $rsync,
), "Construct $CLASS object";

my $rsync_out   = catfile qw(t data rsync.out);
my $mirror_root = $pgxn->mirror_root;
my $log_file    = $sync->log_file;
is $log_file, catfile(tmpdir, "pgxn-api-sync-$$.txt"),
    'Log file name should include PID';
$sync->log_file($rsync_out);
is $sync->log_file, $rsync_out, 'Should have updated log_file';

END {
    unlink 'test.tmp';   # written by testrsync
    $sync->log_file(''); # Prevent deleting fixtures
}

ok $sync->run_rsync, 'Run rsync';
is do {
    open my $fh, '<', 'test.tmp';
    local $/;
    <$fh>
}, "--archive
--compress
--delete
--quiet
--log-file-format
%i %n
--log-file
$rsync_out
rsync://localhost/pgxn
$mirror_root
", 'Rsync should have been properly called';

# Rsync our "mirror" to the mirror root.
remove_tree $mirror_root;
dircopy catdir(qw(t root)), $mirror_root;
fcopy catfile(qw(t root index.json)), $pgxn->doc_root;

##############################################################################
# Test the regular expression for finding distributions.
my @rsync_out = do {
    open my $fh, '<', $rsync_out or die "Cannot open $rsync_out: $!\n";
    <$fh>;
};

# Test the dist template regex.
ok my $regex = $sync->regex_for_uri_template('download'),
    'Get distribution regex';
my @found;
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}
is_deeply \@found, [qw(
    dist/pair/0.1.0/pair-0.1.0.zip
    dist/pair/0.1.1/pair-0.1.1.zip
    dist/pg_french_datatypes/0.1.0/pg_french_datatypes-0.1.0.zip
    dist/pg_french_datatypes/0.1.1/pg_french_datatypes-0.1.1.zip
    dist/tinyint/0.1.0/tinyint-0.1.0.zip
)], 'It should recognize the distribution files.';

# Test the meta template regex.
ok $regex = $sync->regex_for_uri_template('meta'),
    'Get meta regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [qw(
    dist/pair/0.1.0/META.json
    dist/pair/0.1.1/META.json
    dist/pg_french_datatypes/0.1.0/META.json
    dist/pg_french_datatypes/0.1.1/META.json
    dist/tinyint/0.1.0/META.json
)], 'It should recognize the meta files.';

# Test the user template regex.
ok $regex = $sync->regex_for_uri_template('user'),
    'Get user regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [qw(
    user/daamien.json
    user/theory.json
    user/umitanuki.json
)], 'It should recognize the user files.';

# Test the extension template regex.
ok $regex = $sync->regex_for_uri_template('extension'),
    'Get extension regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [qw(
    extension/pair.json
    extension/pg_french_datatypes.json
    extension/tinyint.json
)], 'It should recognize the extension files.';

# Test the tag template regex.
ok $regex = $sync->regex_for_uri_template('tag'),
    'Get tag regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [
   "tag/data types.json",
   "tag/france.json",
   "tag/key value pair.json",
   "tag/key value.json",
   "tag/ordered pair.json",
   "tag/pair.json",
   "tag/variadic function.json",
], 'It should recognize the tag files.';

# Test the mirrors template regex.
ok $regex = $sync->regex_for_uri_template('mirrors'),
    'Get mirrors regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}
is_deeply \@found, ['meta/mirrors.json'], 'Should find mirrors.json';

# Test the stats template regex.
ok $regex = $sync->regex_for_uri_template('stats'),
    'Get stats regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}
is_deeply \@found, [qw(
    stats/dist.json
    stats/extension.json
    stats/user.json
    stats/tag.json
    stats/summary.json
)], 'Should find stats JSON files';

# Test the spec template regex.
ok $regex = $sync->regex_for_uri_template('spec'),
    'Get spec regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}
is_deeply \@found, ['meta/spec.txt'], 'Should find spec.txt';

##############################################################################
# Reset the rsync output and have it do its thing.
my $mock = Test::MockModule->new($CLASS);
$mock->mock(validate_distribution => sub { push @found => $_[1]; $_[1] });
@found = ();

my $api_mock = Test::MockModule->new('PGXN::API');
$api_mock->mock(uri_templates => sub {
    fail 'Should not get URI templates before updating the mirror meta';
});

my $idx_mock = Test::MockModule->new('PGXN::API::Indexer');
my @dists;
$idx_mock->mock(add_distribution => sub { push @dists => $_[1] });
my (@paths, @meths, @parsed, @users);
$idx_mock->mock(update_root_json => sub { push @meths => 'update_root_json' });
$idx_mock->mock(finalize => sub { push @meths => 'finalize' });
$idx_mock->mock(copy_from_mirror => sub { push @paths => $_[1] });
$idx_mock->mock(parse_from_mirror => sub { shift; push @parsed => \@_ });
$idx_mock->mock(merge_user => sub { push @users => $_[1] });
$idx_mock->mock(update_mirror_meta => sub {
    $api_mock->unmock_all;
    pass 'Should update mirror meta';
});

ok $sync->update_index, 'Update the index';
is_deeply \@meths, [qw(update_root_json finalize)],
    'The root index.json should have been updated and the update finalized';
is_deeply \@found, [qw(
    dist/pair/0.1.0/META.json
    dist/pair/0.1.1/META.json
    dist/pg_french_datatypes/0.1.0/META.json
    dist/pg_french_datatypes/0.1.1/META.json
    dist/tinyint/0.1.0/META.json
)], 'It should have processed the meta files';
is_deeply \@dists, \@found, 'And it should have passed them to the indexer';
is_deeply \@paths, [qw(
    meta/mirrors.json
    meta/spec.txt
    stats/dist.json
    stats/extension.json
    stats/user.json
    stats/tag.json
    stats/summary.json
)], 'And it should have found and copied mirrors, spec, and stats';
is_deeply \@parsed, [['meta/spec.txt', 'Multimarkdown']],
    'And it should have parsed spec.txt';
is_deeply \@users, [qw(
    daamien
    theory
    umitanuki
)], 'And it should have merged all user.json files';

##############################################################################
# digest_for()
my $pgz = catfile qw(dist pair 0.1.1 pair-0.1.1.zip);
is $sync->digest_for($pgz), '703c0c485166636317c3d4bc8a1a36d512761af7',
    'Should get expected digest from digest_for()';

##############################################################################
# Test validate_distribution().
$mock->unmock('validate_distribution');

my $json = catfile qw(dist pair 0.1.1 META.json);
$mock->mock(unzip => sub {
    is $_[1], $pgz, "unzip should be passed $pgz";
});
ok $sync->validate_distribution($json), "Process $json";

# It should fail for an invalid checksum.
CHECKSUM: {
    $mock->mock(unzip => sub {
        fail 'unzip should not be called when checksum fails'
    });
    my $json = catfile qw( dist pair/0.1.0/META.json);
    my $pgz  = catfile qw( dist pair/0.1.0/META.json);
    my $pgzp = catfile $pgxn->mirror_root, $pgz;
    stderr_is { $sync->validate_distribution($json ) }
        "Checksum verification failed for $pgzp\n",
        'Should get warning when checksum fails.';
    $mock->unmock('unzip');
}

##############################################################################
# Test unzip.
my @files = (qw(
    Changes
    META.json
    Makefile
    README.md
),  catfile(qw(doc pair.md)),
    catfile(qw(sql pair.sql)),
    catfile(qw(sql uninstall_pair.sql)),
    catfile(qw(test sql base.sql)),
    catfile(qw(test expected base.out)),
);

my $src_dir = PGXN::API->instance->source_dir;
my $base = catdir $src_dir, 'pair', 'pair-0.1.1';

file_not_exists_ok catfile($base, $_), "$_ should not exist" for @files;

# Unzip it.
ok my $zip = $sync->unzip($pgz, {name => 'pair'}), "Unzip $pgz";
isa_ok $zip, 'Archive::Zip';
file_exists_ok catfile($base, $_), "$_ should now exist" for @files;
my $readall = S_IRUSR | S_IRGRP | S_IROTH;
ok(
    ((stat catfile $base, $_)[2] & $readall) == $readall,
    "$_ should be readable by all",
) for @files;

# Now try a brokenated zip file.
stderr_like { $sync->unzip($json) }
    qr/format error: can't find EOCD signature/,
    'Should get a warning for an invalid zip file';

##############################################################################
# Make sure each distribution is indexed.
my @distros;
$idx_mock->mock(add_distribution => sub { push @distros => $_[1] });

my @valids = qw(foo bar baz);
$mock->mock(validate_distribution => sub { shift @valids });

ok $sync->update_index, 'Update the index';

is_deeply \@distros, [qw(foo bar baz)],
    'The distributions should have been passed to an indexer';
