#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 19;
#use Test::More 'no_plan';
use JSON::XS;

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    instance
    config
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
