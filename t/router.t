#!/usr/bin/env perl -w

use 5.12.0;
use utf8;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use Test::More tests => 176;
#use Test::More 'no_plan';
use Plack::Test;
use Test::MockModule;
use HTTP::Request::Common;
use File::Spec::Functions qw(catdir catfile);
use File::Copy::Recursive qw(dircopy fcopy);
use File::Path qw(remove_tree);

BEGIN {
    $File::Copy::Recursive::KeepMode = 0;
    use_ok 'PGXN::API::Router' or die;
}

# Set up the document root.
my $doc_root = catdir 't', 'test_doc_root';
my $api = PGXN::API->instance;
$api->doc_root($doc_root);
END { remove_tree $doc_root }
dircopy catdir(qw(t root)), $doc_root;
$api->mirror_root(catdir 't', 'root');

my $search_mock = Test::MockModule->new('PGXN::API::Searcher');
my @params;
$search_mock->mock(new => sub { bless {} => shift });

local $@;
eval { PGXN::API::Router->app };
is $@, "Missing required parameters errors_to and errors_from\n",
    'Should get proper error for missing parameters';

my $app = PGXN::API::Router->app(
    errors_to   => 'alerts@pgxn.org',
    errors_from => 'api@pgxn.org',
);

# Test the root index.json.
test_psgi $app => sub {
    my $cb = shift;
    ok my $res = $cb->(GET '/index.json'), 'Fetch /index.json';
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'application/json', 'Should be application/json';
};

# Try a subdirectory JSON file.
test_psgi $app => sub {
    my $cb = shift;
    my $uri = '/dist/pair/0.1.1/META.json';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'application/json', 'Should be application/json';
};

# Try a readme file.
test_psgi $app => sub {
    my $cb = shift;
    my $uri = '/dist/pair/0.1.1/README.txt';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'text/plain', 'Should be text/plain';
    is $res->content_charset, 'UTF-8', 'Should be UTF-8';
};

# Try a distribution file.
test_psgi $app => sub {
    my $cb = shift;
    my $uri = '/dist/pair/0.1.1/pair-0.1.1.pgz';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'application/zip', 'Should be application/zip';
};

# Try an HTML file.
my $html = catfile qw(var index.html);
test_psgi $app => sub {
    my $cb = shift;
    fcopy $html, $doc_root or die "Cannot copy $html to $doc_root: $!\n";
    my $uri = '/index.html';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'text/html', 'Should be text/html';
};

# Try the root directory.
test_psgi $app => sub {
    my $cb = shift;
    local $ENV{FOO} = 1;
    fcopy $html, $doc_root or die "Cannot copy $html to $doc_root: $!\n";
    ok my $res = $cb->(GET '/'), "Fetch /";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'text/html', 'Should be text/html';
};

# Create a src directory.
my $src = catdir $doc_root, qw(dist/pair);
my $dst = catdir $doc_root, qw(src pair);
dircopy $src, $dst or die "Cannot copy dir $src to $dst: $!\n";
fcopy $html, $dst or die "Cannot copy $html to $dst: $!\n";

# Try a src/json file.
test_psgi $app => sub {
    my $cb = shift;
    my $uri = 'src/pair/0.1.0/META.json';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'text/plain', 'Should be text/plain';
};

# Try a src/readme file
test_psgi $app => sub {
    my $cb = shift;
    my $uri = 'src/pair/0.1.1/README.txt';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'text/plain', 'Should be text/plain';
};

# Try a src/html file.
test_psgi $app => sub {
    my $cb = shift;
    my $uri = 'src/pair/index.html';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'text/plain', 'Should be text/plain';
};

# Try a src directory..
test_psgi $app => sub {
    my $cb = shift;
    my $uri = 'src/pair/';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, 'It should be a success';
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content_type, 'text/html', 'Should be text/html';
    like $res->content, qr/Parent Directory/,
        'Should look like a directory listing';
};

# Make sure /_index always 404s.
test_psgi $app => sub {
    my $cb = shift;
    for my $uri (qw( _index _index/ _index/foo _index/index.html)) {
        ok my $res = $cb->(GET $uri), "Fetch $uri";
        ok $res->is_error, "$uri should respond with an error";
        is $res->code, 404, "$uri should 404";
        is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
            'Should have API version in the header';
    }
};

# Give the search engine a spin.
test_psgi $app => sub {
    my $cb = shift;
    $search_mock->mock(search => sub {
        shift; @params = @_; return { foo => 1 }
    });
    my $q = 'q=whü&o=2&l=10';
    my @exp = ( query  => 'whü', offset => 2, limit  => 10 );
    for my $in (qw(docs dists extensions users tags)) {
        for my $slash ('', '/') {
            my $uri = "/search/$in$slash?$q";
            ok my $res = $cb->(GET $uri), "Fetch $uri";
            ok $res->is_success, "$uri should return success";
            is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
                'Should have API version in the header';
            is $res->content, '{"foo":1}', 'Content should be JSON of results';
            is_deeply \@params, [in => $in, @exp],
                "$uri should properly dispatch to the searcher";
        }
    }

    # Now make sure we get the proper 404s.
    for my $uri (qw(
        /search
        /search/foo
        /search/foo/
        /search/tag/foo
        /search/tag/foo/
    )) {
        ok my $res = $cb->(GET $uri), "Fetch $uri";
        ok $res->is_error, "$uri should respond with an error";
        is $res->code, 404, "$uri should 404";
        is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
            'Should have API version in the header';
    }

    # And that we get a 400 when there's no q param.
    my $uri = '/search/docs';
    ok my $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_error, "$uri should respond with an error";
    is $res->code, 400, "$uri should 400";
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content, 'Bad request: Invalid or missing "q" query param.',
        'Should get proper error message';

    # And that we get a 400 for an invalid q param.
    for my $q ('', '*', '?') {
        my $uri = "/search/docs?q=$q";
        ok my $res = $cb->(GET $uri), "Fetch $uri";
        ok $res->is_error, "$uri should respond with an error";
        is $res->code, 400, "$uri should 400";
        is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
            'Should have API version in the header';
        is $res->content, 'Bad request: Invalid or missing "q" query param.',
            'Should get proper error message';
    }

    # And that we get a 400 for invalid params.
    for my $spec (
        ['l=foo' => 'Bad request: invalid "l" query param.'],
        ['o=foo' => 'Bad request: invalid "o" query param.'],
    ) {
        my $uri = "/search/docs?q=whu&$spec->[0]";
        ok my $res = $cb->(GET $uri), "Fetch $uri";
        ok $res->is_error, "$uri should respond with an error";
        is $res->code, 400, "$uri should 400";
        is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
            'Should have API version in the header';
        is $res->content, $spec->[1], 'Should get proper error message';
    }

    # Make sure it works with a query and nothing else.
    $uri .= '?q=hi';
    ok $res = $cb->(GET $uri), "Fetch $uri";
    ok $res->is_success, "$uri should return success";
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content, '{"foo":1}', 'Content should be JSON of results';
    is_deeply \@params,
        [in => 'docs', query => 'hi', offset => undef, limit => undef ],
        "$uri should properly dispatch to the searcher";
};

# Test /error basics.
my $err_app = sub {
    my $env = shift;
    $env->{'psgix.errordocument.PATH_INFO'} = '/what';
    $env->{'psgix.errordocument.SCRIPT_NAME'} = '';
    $env->{'psgix.errordocument.SCRIPT_NAME'} = '';
    $env->{'psgix.errordocument.HTTP_HOST'} = 'localhost';
    $env->{'plack.stacktrace.text'} = 'This is the trace';
    $app->($env);
};

test_psgi $err_app => sub {
    my $cb = shift;
    ok my $res = $cb->(GET '/error'), "GET /error";
    ok $res->is_success, q{Should be success (because it's only served as a subrequest)};
    is $res->header('X-PGXN-API-Version'), PGXN::API->VERSION,
        'Should have API version in the header';
    is $res->content, 'internal server error', 'body should be error message';

    # Check the alert email.
    ok my $deliveries = Email::Sender::Simple->default_transport->deliveries,
        'Should have email deliveries.';
    is @{ $deliveries }, 1, 'Should have one message';
    is @{ $deliveries->[0]{successes} }, 1, 'Should have been successfully delivered';

    my $email = $deliveries->[0]{email};
    is $email->get_header('Subject'), 'PGXN API Internal Server Error',
        'The subject should be set';
    is $email->get_header('From'), 'api@pgxn.org',
        'From header should be set';
    is $email->get_header('To'), 'alerts@pgxn.org',
        'To header should be set';
    is $email->get_body, 'An error occurred during a request to http://localhost/what.

Environment:

{ HTTP_HOST => "localhost", PATH_INFO => "/what", SCRIPT_NAME => "" }

Trace:

This is the trace
',
    'The body should be correct';
    Email::Sender::Simple->default_transport->clear_deliveries;
};

