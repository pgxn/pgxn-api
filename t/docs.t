#!/usr/bin/env perl -w

use strict;
use warnings;
#use Test::More tests => 98;
use Test::More 'no_plan';
use PGXN::API::Indexer;
use Test::File::Contents;
use File::Basename;
use File::Spec::Functions qw(catfile catdir);
use utf8;

my $indexer = new_ok 'PGXN::API::Indexer';
my $libxml = XML::LibXML->new(
    recover    => 2,
    no_network => 1,
    no_blanks  => 1,
    no_cdata   => 1,
);

for my $in (glob catfile qw(t htmlin *)) {
    my $doc  = $libxml->parse_html_file($in, {
        suppress_warnings => 1,
        suppress_errors   => 1,
        recover           => 2,
    });

    # my $html = PGXN::API::Indexer::_clean_html_body($doc->findnodes('/html/body'));
    # open my $fh, '>:raw', 'tmp.html';
    # print $fh $html;
    file_contents_eq_or_diff(
        catfile(qw(t htmlout), basename $in),
        PGXN::API::Indexer::_clean_html_body($doc->findnodes('/html/body')),
        "Test HTML from $in"
    );

}

