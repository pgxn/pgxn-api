#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 66;
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
fcopy catfile(qw(t root index.json)), $pgxn->doc_root;

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
ok !$stats->dists_updated, 'dists_updated should start out false';
my $dist_path = catfile $pgxn->mirror_root, qw(dist pair.json);
ok $stats->update_dist($dist_path), 'Update dist "pair"';
ok $stats->dists_updated, 'dists_updated should now be true';
is_deeply $dbh->selectrow_arrayref(
    q{SELECT rel_count, version, date, user, abstract FROM dists WHERE name = 'pair'}
), [1, '0.1.0', '2010-10-18T15:24:21Z', 'theory', 'A key/value pair data type'],
    'DB should have release count, version, and date for dist "pair"';

# Try updating.
$dist_path = catfile qw(t data pair-updated.json);
ok $stats->update_dist($dist_path), 'Update dist "pair" again';
ok $stats->dists_updated, 'dists_updated should still be true';
is_deeply $dbh->selectrow_arrayref(
    q{SELECT rel_count, version, date, user, abstract FROM dists WHERE name = 'pair'}
), [3, '0.1.1', '2010-10-29T22:46:45Z', 'theory', 'A key/value pair dåtå type'],
    'DB should have new release count, version, and date for dist "pair"';

##############################################################################
# Great, now update a extension.
ok !$stats->extensions_updated, 'extensions_updated should start out false';
my $extension_path = catfile $pgxn->mirror_root, qw(extension pair.json);
ok $stats->update_extension($extension_path), 'Update extension "pair"';
ok $stats->extensions_updated, 'extensions_updated should now be true';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM extensions WHERE name = 'pair'}
)->[0], 1, 'DB should have release count for extension "pair"';

# Try updating.
$extension_path = catfile qw(t data pair-ext-updated3.json);
ok $stats->update_extension($extension_path), 'Update extension "pair" again';
ok $stats->extensions_updated, 'extensions_updated should still be true';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM extensions WHERE name = 'pair'}
)->[0], 3, 'DB should have new release count for extension "pair"';

##############################################################################
# Great, now update a user.
ok !$stats->users_updated, 'users_updated should start out false';
my $user_path = catfile $pgxn->mirror_root, qw(user theory.json);
ok $stats->update_user($user_path), 'Update user "theory"';
ok $stats->users_updated, 'users_updated should now be true';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM users WHERE name = 'theory'}
)->[0], 3, 'DB should have release count for user "theory"';

# Try updating.
$user_path = catfile qw(t data theory-updated2.json);
ok $stats->update_user($user_path), 'Update user "theory" again';
ok $stats->users_updated, 'users_updated should still be true';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM users WHERE name = 'theory'}
)->[0], 4, 'DB should have new release count for user "theory"';

##############################################################################
# Great, now update a tag.
ok !$stats->tags_updated, 'tags_updated should start out false';
my $tag_path = catfile $pgxn->mirror_root, qw(tag pair.json);
ok $stats->update_tag($tag_path), 'Update tag "pair"';
ok $stats->tags_updated, 'tags_updated should now be true';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM tags WHERE name = 'pair'}
)->[0], 2, 'DB should have release count for tag "pair"';

# Make sure updating works.
$dbh->do('UPDATE tags SET rel_count = 1');
ok $stats->update_tag($tag_path), 'Update tag "pair" again';
ok $stats->tags_updated, 'tags_updated should still be true';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM tags WHERE name = 'pair'}
)->[0], 2, 'DB should have updated release count for tag "pair"';

# Try a different tag.
$tag_path = catfile $pgxn->mirror_root, 'tag', 'key value.json';
ok $stats->update_tag($tag_path), 'Update tag "key value"';
ok $stats->tags_updated, 'tags_updated should _still_ be true';
is $dbh->selectrow_arrayref(
    q{SELECT rel_count FROM tags WHERE name = 'key value'}
)->[0], 1, 'DB should have updated release count for tag "key value"';

##############################################################################
# Great, now write all of the stats files.
my $dists_file = catfile($pgxn->doc_root, qw(stats dists.json));
file_not_exists_ok $dists_file, 'Dists stats file should not exist';
ok $stats->write_dist_stats, 'Write dist stats';
file_exists_ok $dists_file, 'Dists stats file should now exist';
is_deeply $pgxn->read_json_from($dists_file), { count => 1, recent => [
    {
        dist     => 'pair',
        version  => '0.1.1',
        date     => '2010-10-29T22:46:45Z',
        user     => 'theory',
        abstract => 'A key/value pair dåtå type',
    },
] }, 'Its contents should be correct';

my $tags_file = catfile($pgxn->doc_root, qw(stats tags.json));
file_not_exists_ok $tags_file, 'Tags stats file should not exist';
ok $stats->write_tag_stats, 'Write tag stats';
file_exists_ok $tags_file, 'Tags stats file should now exist';
is_deeply $pgxn->read_json_from($tags_file), {
   count => 2,
   popular => {
      'key value' => 1,
      pair => 2
   }
}, 'Its contents should be correct';

my $users_file = catfile($pgxn->doc_root, qw(stats users.json));
file_not_exists_ok $users_file, 'Users stats file should not exist';
ok $stats->write_user_stats, 'Write user stats';
file_exists_ok $users_file, 'Users stats file should now exist';
is_deeply $pgxn->read_json_from($users_file), {
   count => 1, prolific => { theory => 4 }
}, 'Its contents should be correct';

my $extensions_file = catfile($pgxn->doc_root, qw(stats extensions.json));
file_not_exists_ok $extensions_file, 'Extensions stats file should not exist';
ok $stats->write_extension_stats, 'Write extension stats';
file_exists_ok $extensions_file, 'Extensions stats file should now exist';
is_deeply $pgxn->read_json_from($extensions_file), {
   count => 1, prolific => { pair => 3 }
}, 'Its contents should be correct';
