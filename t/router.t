#!/usr/bin/env perl -w

use 5.12.0;
use utf8;
use Test::More tests => 85;
#use Test::More 'no_plan';
use Plack::Test;
use Test::MockModule;
use HTTP::Request::Common;
use File::Spec::Functions qw(catdir catfile);
use File::Copy::Recursive qw(dircopy fcopy);
use File::Path qw(remove_tree);

BEGIN {
    use_ok 'PGXN::API::Router' or die;
}

# Set up the document root.
my $doc_root = catdir 't', 'test_doc_root';
my $api = PGXN::API->instance;
$api->doc_root($doc_root);
END { remove_tree $doc_root }
dircopy catdir(qw(t root)), $doc_root;
$api->mirror_root(catdir 't', 'root');

# Test the root index.json.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    ok my $res = $cb->(GET '/index.json'), 'Fetch /index.json';
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'application/json', 'Should be application/json';
};

# Try a subdirectory JSON file.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    my $uri = '/dist/pair/0.1.1/META.json';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'application/json', 'Should be application/json';
};

# Try a readme file.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    my $uri = '/dist/pair/0.1.1/README.txt';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'text/plain', 'Should be text/plain';
    is $res->content_charset, 'UTF-8', 'Should be UTF-8';
};

# Try a distribution file.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    my $uri = '/dist/pair/0.1.1/pair-0.1.1.pgz';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'application/zip', 'Should be application/zip';
};

# Try an HTML file.
my $html = catfile qw(var index.html);
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    fcopy $html, $doc_root or die "Cannot copy $html to $doc_root: $!\n";
    my $uri = '/index.html';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'text/html', 'Should be text/html';
};

# Try the root directory.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    local $ENV{FOO} = 1;
    fcopy $html, $doc_root or die "Cannot copy $html to $doc_root: $!\n";
    ok my $res = $cb->(GET '/'), "Fetch /";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'text/html', 'Should be text/html';
};

# Create a src directory.
my $src = catdir $doc_root, qw(dist/pair);
my $dst = catdir $doc_root, qw(src pair);
dircopy $src, $dst or die "Cannot copy dir $src to $dst: $!\n";
fcopy $html, $dst or die "Cannot copy $html to $dst: $!\n";

# Try a src/json file.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    my $uri = 'src/pair/0.1.0/META.json';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'application/json', 'Should be application/json';
};

# Try a src/readme file
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    my $uri = 'src/pair/0.1.1/README.txt';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'text/plain', 'Should be text/plain';
};

# Try a src/html file.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    my $uri = 'src/pair/index.html';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'text/plain', 'Should be text/plain';
};

# Try a src directory..
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    my $uri = 'src/pair/';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->content_type, 'text/html', 'Should be text/html';
    like $res->content, qr/Parent Directory/,
        'Should look like a directory listing';
};

# Make sure /_index always 404s.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    for my $uri (qw( _index _index/ _index/foo _index/index.html)) {
        ok my $res = $cb->(GET $uri), "Fetch $uri";
        ok $res->is_error, "$uri should respond with an error";
        is $res->code, 404, "$uri should 404";
    }
};

# Give the search engine a spin.
test_psgi +PGXN::API::Router->app => sub {
    my $cb = shift;
    my $mocker = Test::MockModule->new('PGXN::API::Searcher');
    my @params;
    $mocker->mock(new => sub { bless {} => shift });
    $mocker->mock(search => sub { shift; @params = @_; return { foo => 1 } });
    my $q = 'q=whü&o=2&l=10';
    my $uri = '/search';
    my $exp = { query  => 'whü', offset => 2, limit  => 10 };
    for my $in ('', qw(doc dist extension user tag)) {
        ok my $res = $cb->(GET "$uri?$q&in=$in"), "Fetch $in $uri";
        ok $res->is_success, "$in $uri should return success";
        is $res->content, '{"foo":1}', 'Content should be JSON of results';
        $exp->{index} = $in;
        is_deeply \@params, [$exp],
            "$in $uri should properly dispatch to the searcher";
    }

    # Now make sure we get the proper 404s.
    for my $uri (qw(/search/foo /search/foo/ /search/tag/foo /search/tag/foo/)) {
        ok my $res = $cb->(GET $uri), "Fetch $uri";
        ok $res->is_error, "$uri should respond with an error";
        is $res->code, 404, "$uri should 404";
    }

    # And that we get a 400 when there's no q param.
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_error, "$uri should respond with an error";
    is $res->code, 400, "$uri should 400";
    is $res->content, 'Bad request: q query param required.',
        'Should get proper error message';
};
