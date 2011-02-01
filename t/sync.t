#!/usr/bin/env perl -w

use strict;
use warnings;
#use Test::More tests => 2;
use Test::More 'no_plan';
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
    _pipe
);

# Set up for Win32.
my $config = PGXN::API->config;
$config->{rsync_path} .= '.bat' if PGXN::API::Sync::WIN32;

# Test rsync.
ok my $sync = $CLASS->new, "Construct $CLASS object";
ok $sync->run_rsync, 'Run rsync';
ok my $fh = $sync->rsync_output, 'Grab the output';
is join('', <$fh>), "--archive
--compress
--itemize-changes
--delete
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
