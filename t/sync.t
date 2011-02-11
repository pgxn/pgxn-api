#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 43;
#use Test::More 'no_plan';
use File::Spec::Functions qw(catfile catdir);
use Test::MockModule;
use Test::Output;
use File::Path qw(remove_tree);
use Test::File;

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API::Sync';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    new
    run
    run_rsync
    rsync_output
    uri_templates
    update_index
    process_meta
    dist_for
    digest_for
    unzip
    _pipe
);

# Set up for Win32.
my $config = PGXN::API->config;
$config->{rsync_path} .= '.bat' if PGXN::API::Sync::WIN32;

##############################################################################
# Test rsync.
ok my $sync = $CLASS->new, "Construct $CLASS object";
ok $sync->run_rsync, 'Run rsync';
ok my $fh = $sync->rsync_output, 'Grab the output';
is join('', <$fh>), "--archive
--compress
--delete
--out-format
%i %n
$config->{rsync_source}
$config->{mirror_root}
", 'Rsync should have been properly called';

# Test reading the URI templates.
is_deeply $sync->uri_templates, {
   "by-dist" => "/by/dist/{dist}.json",
   "by-extension" => "/by/extension/{extension}.json",
   "by-owner" => "/by/owner/{owner}.json",
   "by-tag" => "/by/tag/{tag}.json",
   "dist" => "/dist/{dist}/{dist}-{version}.pgz",
   "meta" => "/dist/{dist}/{dist}-{version}.json",
   "readme" => "/dist/{dist}/{dist}-{version}.readme"
}, 'The templates should be there';

##############################################################################
# Test the regular expression for finding distributions.
my $rsync_out = catfile qw(t data rsync.out);
my @rsync_out = do {
    open $fh, '<', $rsync_out or die "Cannot open $rsync_out: $!\n";
    <$fh>;
};

# Test the dist template regex.
ok my $regex = $sync->regex_for_uri_template('dist'),
    'Get distribution regex';
my @found;
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [qw(
    dist/pair/pair-0.1.0.pgz
    dist/pair/pair-0.1.1.pgz
    dist/pg_french_datatypes/pg_french_datatypes-0.1.0.pgz
    dist/pg_french_datatypes/pg_french_datatypes-0.1.1.pgz
    dist/tinyint/tinyint-0.1.0.pgz
)], 'It should recognize the distribution files.';

# Test the meta template regex.
ok $regex = $sync->regex_for_uri_template('meta'),
    'Get meta regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [qw(
    dist/pair/pair-0.1.0.json
    dist/pair/pair-0.1.1.json
    dist/pg_french_datatypes/pg_french_datatypes-0.1.0.json
    dist/pg_french_datatypes/pg_french_datatypes-0.1.1.json
    dist/tinyint/tinyint-0.1.0.json
)], 'It should recognize the meta files.';

# Test the owner template regex.
ok $regex = $sync->regex_for_uri_template('by-owner'),
    'Get by-owner regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [qw(
    by/owner/daamien.json
    by/owner/theory.json
    by/owner/umitanuki.json
)], 'It should recognize the owner files.';

# Test the extension template regex.
ok $regex = $sync->regex_for_uri_template('by-extension'),
    'Get by-extension regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [qw(
    by/extension/pair.json
    by/extension/pg_french_datatypes.json
    by/extension/tinyint.json
)], 'It should recognize the extension files.';

# Test the tag template regex.
ok $regex = $sync->regex_for_uri_template('by-tag'),
    'Get by-tag regex';
@found = ();
for (@rsync_out) {
    push @found => $1 if $_ =~ $regex;
}

is_deeply \@found, [
   "by/tag/data types.json",
   "by/tag/france.json",
   "by/tag/key value pair.json",
   "by/tag/key value.json",
   "by/tag/ordered pair.json",
   "by/tag/pair.json",
   "by/tag/variadic function.json",
], 'It should recognize the tag files.';

##############################################################################
# Reset the rsync output and have it do its thing.
open $fh, '<', $rsync_out or die "Cannot open $rsync_out: $!\n";
$sync->rsync_output($fh);
my $mock = Test::MockModule->new($CLASS);
$mock->mock(process_meta => sub { push @found => $_[1] });
@found = ();

ok $sync->update_index, 'Update the index';
is_deeply \@found, [qw(
    dist/pair/pair-0.1.0.json
    dist/pair/pair-0.1.1.json
    dist/pg_french_datatypes/pg_french_datatypes-0.1.0.json
    dist/pg_french_datatypes/pg_french_datatypes-0.1.1.json
    dist/tinyint/tinyint-0.1.0.json
)], 'It should have processed the meta files';

##############################################################################
# digest_for()
my $pgz = catfile qw(t root dist pair pair-0.1.1.pgz);
is $sync->digest_for($pgz), 'c552c961400253e852250c5d2f3def183c81adb3',
    'Should get expected digest from digest_for()';

##############################################################################
# Test process_meta().
$mock->unmock('process_meta');

my $json = catfile qw(t root dist pair pair-0.1.1.json);
$mock->mock(unzip => sub {
    is $_[1], $pgz, "unzip should be passed $pgz";
});
ok $sync->process_meta($json), "Process $json";

# It should fail for an invalid checksum.
CHECKSUM: {
    $mock->mock(unzip => sub {
        fail 'unzip should not be called when checksum fails'
    });
    my $json = catfile qw(t root dist pair pair-0.1.0.json);
    my $pgz = catfile qw(t root dist pair pair-0.1.0.json);
    stderr_is { $sync->process_meta($json ) }
        "Checksum verification failed for $pgz\n",
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
), catfile(qw(doc pair.txt)),
    catfile(qw(sql pair.sql)),
    catfile(qw(sql uninstall_pair.sql)),
    catfile(qw(test sql base.sql)),
    catfile(qw(test expected base.out)),
);

my $base = catdir $config->{mirror_root}, 'src', 'pair-0.1.1';
file_not_exists_ok catfile($base, $_), "$_ should not exist" for @files;

# Unzip it.
END { remove_tree $sync->source_dir }
ok $sync->unzip($pgz), "Unzip $pgz";
file_exists_ok catfile($base, $_), "$_ should now exist" for @files;

# Now try a brokenated zip file.
stderr_like { $sync->unzip($json) }
    qr/format error: can't find EOCD signature/,
    'Should get a warning for an invalid zip file';
