#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More 0.88;
use PGXN::API::Indexer;
use Test::File::Contents;
use File::Basename;
use File::Spec::Functions qw(catfile catdir tmpdir);
use utf8;

my $indexer = new_ok 'PGXN::API::Indexer';
my $libxml = XML::LibXML->new(
    recover    => 2,
    no_network => 1,
    no_blanks  => 1,
    no_cdata   => 1,
);

# Unfortunately, we have to write to a file, because file_contents_eq_or_diff
# doesn't seem to work on Windows.
my $tmpfile = catfile tmpdir, 'pgxnapi-doctest$$.html';

END { unlink $tmpfile }

for my $in (glob catfile qw(t htmlin *)) {
    my $doc = $libxml->parse_html_file($in, {
        suppress_warnings => 1,
        suppress_errors   => 1,
        recover           => 2,
    });

    my $html = PGXN::API::Indexer::_clean_html_body($doc->findnodes('/html/body')) . "\n";
    open my $fh, '>:raw', $tmpfile or die "Cannot open $tmpfile: $!\n";
    print $fh $html;
    close $fh;
    # last if $in =~ /shift/; next;
    # diag $html if $in =~ /head/; next;
    files_eq_or_diff(
        $tmpfile,
        catfile(qw(t htmlout), basename $in),
        "Test HTML from $in",
        { encoding => 'UTF-8' }
    );
}

done_testing;

