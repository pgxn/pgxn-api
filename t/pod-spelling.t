#!/usr/bin/env perl -w

use strict;
use Test::More;
eval "use Test::Spelling";
plan skip_all => "Test::Spelling required for testing POD spelling" if $@;

add_stopwords(<DATA>);
all_pod_files_spelling_ok();

__DATA__
API
API's
APIs
browsable
CPAN
CPAN
crontab
GitHub
JSON
merchantability
metadata
middleware
pgTAP
PGXN
Plack
PostgreSQL
PSGI
RDBMS
SHA
subdirectory
superset
TCP
