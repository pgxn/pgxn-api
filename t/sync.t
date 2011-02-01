#!/usr/bin/env perl -w

use strict;
use warnings;
#use Test::More tests => 2;
use Test::More 'no_plan';

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
    _pipe
);

ok my $sync = $CLASS->new, "Construct $CLASS object";
ok $sync->run_rsync, 'Run rsync';
ok my $fh = $sync->rsync_output, 'Grab the output';
is join('', <$fh>), '--archive
--compress
--itemize-changes
--delete
rsync://master.pgxn.org/pgxn
/tmp/pgxn-root-test
', 'Rsync should have been properly called';
