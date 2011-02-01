#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 20;
#use Test::More 'no_plan';
use File::Spec::Functions qw(catfile);
use Test::MockModule;
#use Test::File;

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
    read_templates
    uri_templates
    update_index
    process_meta
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
ok $sync->read_templates, 'Read the templates';
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
