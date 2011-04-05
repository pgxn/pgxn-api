#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 15;
#use Test::More 'no_plan';
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(remove_tree);
use File::Copy::Recursive qw(dircopy fcopy);
use Test::File;

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API::Stats';
    use_ok $CLASS or die;
}

my $pgxn   = PGXN::API->instance;
$pgxn->doc_root(catdir 't', 'test_doc_root');
END { remove_tree $pgxn->doc_root }

dircopy catdir(qw(t root)), $pgxn->mirror_root;

my $stats = new_ok $CLASS;

# Test the database connection.
my $db = catfile $pgxn->doc_root, qw(_index stats.db);
file_not_exists_ok $db, 'stats.db should not exist';
isa_ok my $conn = $stats->conn, 'DBIx::Connector', 'Get database connection';
file_not_exists_ok $db, 'stats.db should still not exist';
is $conn->mode, 'fixup', 'Should be fixup mode';

isa_ok my $dbh = $conn->dbh, 'DBI::db', 'The DBH';
ok $conn->connected, 'We should be connected to the database';
file_exists_ok $db, 'stats.db should now exist';

# What are we connected to, and how?
is $dbh->{Name}, "dbname=$db", qq{Should be connected to "$db"};
ok !$dbh->{PrintError}, 'PrintError should be disabled';
ok $dbh->{RaiseError}, 'RaiseError should be enabled';
ok $dbh->{AutoCommit}, 'AutoCommit should be enabled';
ok $dbh->{sqlite_unicode}, 'sqlite_unicode should be enabled';

is $conn->run(sub { shift->selectrow_array('PRAGMA schema_version') }),
    1, 'Should be at schema version 1';
