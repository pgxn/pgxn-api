#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 37;
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

# Make sure we have the tables.
ok $dbh->selectcol_arrayref(
    q{SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?},
    undef, $_
)->[0], "Should have table $_" for qw(dists extensions users tags);

##############################################################################
# Great, now update a dist.
my $dist_path = catfile $pgxn->mirror_root, qw(dist pair.json);
ok $stats->update_dist($dist_path), 'Update dist "pair"';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM dists WHERE name = 'pair'}
)->[0], 1, 'DB should have release count for dist "pair"';

# Try updating.
$dist_path = catfile qw(t data pair-updated.json);
ok $stats->update_dist($dist_path), 'Update dist "pair" again';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM dists WHERE name = 'pair'}
)->[0], 3, 'DB should have new release count for dist "pair"';

##############################################################################
# Great, now update a extension.
my $extension_path = catfile $pgxn->mirror_root, qw(extension pair.json);
ok $stats->update_extension($extension_path), 'Update extension "pair"';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM extensions WHERE name = 'pair'}
)->[0], 1, 'DB should have release count for extension "pair"';

# Try updating.
$extension_path = catfile qw(t data pair-ext-updated3.json);
ok $stats->update_extension($extension_path), 'Update extension "pair" again';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM extensions WHERE name = 'pair'}
)->[0], 3, 'DB should have new release count for extension "pair"';

##############################################################################
# Great, now update a user.
my $user_path = catfile $pgxn->mirror_root, qw(user theory.json);
ok $stats->update_user($user_path), 'Update user "theory"';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM users WHERE name = 'theory'}
)->[0], 3, 'DB should have release count for user "theory"';

# Try updating.
$user_path = catfile qw(t data theory-updated2.json);
ok $stats->update_user($user_path), 'Update user "theory" again';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM users WHERE name = 'theory'}
)->[0], 4, 'DB should have new release count for user "theory"';

##############################################################################
# Great, now update a tag.
my $tag_path = catfile $pgxn->mirror_root, qw(tag pair.json);
ok $stats->update_tag($tag_path), 'Update tag "pair"';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM tags WHERE name = 'pair'}
)->[0], 2, 'DB should have release count for tag "pair"';

# Make sure updating works.
$dbh->do('UPDATE tags SET rel_count = 1');
ok $stats->update_tag($tag_path), 'Update tag "pair" again';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM tags WHERE name = 'pair'}
)->[0], 2, 'DB should have updated release count for tag "pair"';

# Try a different tag.
$tag_path = catfile $pgxn->mirror_root, 'tag', 'key value.json';
ok $stats->update_tag($tag_path), 'Update tag "key value"';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM tags WHERE name = 'key value'}
)->[0], 1, 'DB should have updated release count for tag "key value"';
