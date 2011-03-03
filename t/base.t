#!/usr/bin/env perl -w

use strict;
use warnings;
use File::Spec::Functions qw(catdir catfile);
use File::Path qw(remove_tree);
use Test::File;
use Test::More tests => 34;
#use Test::More 'no_plan';
use Test::File::Contents;
use File::Copy::Recursive qw(fcopy);
use File::Temp;
use JSON;
use Cwd;

my $CLASS;
BEGIN {
    $CLASS = 'PGXN::API';
    use_ok $CLASS or die;
}

can_ok $CLASS => qw(
    instance
    uri_templates
    source_dir
    read_json_from
);

isa_ok my $pgxn = $CLASS->instance, $CLASS;
is +$CLASS->instance, $pgxn, 'instance() should return a singleton';
is +$CLASS->instance, $pgxn, 'new() should return a singleton';

##############################################################################
# Test read_json_from()
my $file = catfile qw(t root by tag pair.json);
open my $fh, '<:raw', $file or die "Cannot open $file: $!\n";
my $data = do {
    local $/;
    decode_json <$fh>;
};
close $fh;
is_deeply $pgxn->read_json_from($file), $data,
    'read_json_from() should work';

##############################################################################
# Test write_json_to()
my $tmpfile = 'tmp.json';
END { unlink $tmpfile }
ok $pgxn->write_json_to($tmpfile => $data), 'Write JSON';
is_deeply $pgxn->read_json_from($tmpfile), $data,
    'It should read back in properly';

# Test doc_root().
my $doc_root = catdir 't', 'test_doc_root';
file_not_exists_ok $doc_root, 'Doc root should not yet exist';
$pgxn->doc_root($doc_root);
END { remove_tree $doc_root }
is $pgxn->doc_root, $doc_root,  'Should have doc root';
file_exists_ok $doc_root, 'Doc root should now exist';
file_exists_ok(
    catdir($doc_root, 'by', $_),
    "Subdiretory by/$_ should have been created"
) for qw(owner tag dist extension);

# Make sure index.html was created.
file_exists_ok catfile($doc_root, 'index.html'), 'index.html should exist';
files_eq_or_diff(
    catfile($doc_root, 'index.html'),
    catfile('var', 'index.html'),
    'And it should be the var copy'
);

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
