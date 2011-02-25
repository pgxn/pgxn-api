#!/usr/bin/env perl -w

use strict;
use warnings;
use File::Spec::Functions qw(catdir catfile);
use File::Path qw(remove_tree);
use Test::File;
use Test::More tests => 39;
#use Test::More 'no_plan';
use File::Copy::Recursive qw(fcopy);
use JSON;
use Cwd;

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    instance
    config
    uri_templates
    source_dir
    read_json_from
);

isa_ok my $pgxn = $CLASS->instance, $CLASS;
is +$CLASS->instance, $pgxn, 'instance() should return a singleton';
is +$CLASS->instance, $pgxn, 'new() should return a singleton';

open my $fh, '<:raw', 'conf/test.json' or die "Cannot open conf/test.json: $!\n";
my $conf = do {
    local $/;
    decode_json <$fh>;
};
close $fh;
is_deeply $pgxn->config, $conf, 'The configuration should be loaded';

ok my $conn = $pgxn->conn, 'Get connection';
isa_ok $conn, 'DBIx::Connector';
ok my $dbh = $conn->dbh, 'Make sure we can connect';
isa_ok $dbh, 'DBI::db', 'The handle';

# What are we connected to, and how?
is $dbh->{Username}, 'pgxn', 'Should be connected as "postgres"';
is $dbh->{Name}, 'dbname=pgxn_api_test',
    'Should be connected to "pgxn_api_test"';
ok !$dbh->{PrintError}, 'PrintError should be disabled';
ok !$dbh->{RaiseError}, 'RaiseError should be disabled';
ok $dbh->{AutoCommit}, 'AutoCommit should be enabled';
ok !$dbh->{pg_server_prepare}, 'pg_server_prepare should be disabled';
isa_ok $dbh->{HandleError}, 'CODE', 'There should be an error handler';

is $dbh->selectrow_arrayref('SELECT 1')->[0], 1,
    'We should be able to execute a query';

##############################################################################
# read_json_from()
is_deeply $pgxn->read_json_from('conf/test.json'), $conf,
    'read_json_from() should work';

# Test doc_root().
file_not_exists_ok 'www', 'Doc root should not yet exist';
END { remove_tree 'www' }
is $pgxn->doc_root, catdir(cwd, 'www'),
    'Should have default doc root';
file_exists_ok 'www', 'Doc root should now exist';

# Test source_dir().
my $src_dir = catdir $pgxn->doc_root, 'src';
file_not_exists_ok $src_dir, 'Source dir should not yet exist';
is $pgxn->source_dir, $src_dir, 'Should have expected source directory';
file_exists_ok $src_dir, 'Source dir should now exist';
ok -d $src_dir, 'Source dir should be a directory';

# Test mirror_root().
my $mirror_root = catdir $pgxn->doc_root, 'pgxn';
file_not_exists_ok $mirror_root, 'Mirror dir should not yet exist';
is $pgxn->mirror_root, $mirror_root, 'Should have expected source directory';
file_exists_ok $mirror_root, 'Mirror dir should now exist';
ok -d $mirror_root, 'Mirror dir should be a directory';

# Make sure the URI templates are created.
fcopy catfile(qw(t root index.json)), $mirror_root;
ok my $tmpl = $pgxn->uri_templates, 'Get URI templates';
isa_ok $tmpl, 'HASH', 'Their storage';
isa_ok $tmpl->{$_}, 'URI::Template', "Template $_" for keys %{ $tmpl };
