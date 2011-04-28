package PGXN::API::Router v0.12.8;

use 5.12.0;
use utf8;
use PGXN::API;
use Plack::Builder;
use Plack::App::File;
use Plack::App::Directory;
use PGXN::API::Searcher;
use JSON;
use Plack::Request;
use Encode;
use File::Spec::Functions qw(catdir);
use namespace::autoclean;

sub app {
    my ($class, %params) = @_;

    unless ($params{errors_to} && $params{errors_from}) {
        die "Missing required parameters errors_to and errors_from\n";
    }

    PGXN::API->instance->doc_root(delete $params{doc_root})
        if $params{doc_root};
    my $root = PGXN::API->instance->doc_root;

    # Identify distribution files as zip files.
    my ($zip_ext) = PGXN::API->instance->uri_templates->{download} =~ /([.][^.]+)$/;
    $Plack::MIME::MIME_TYPES->{$zip_ext} = $Plack::MIME::MIME_TYPES->{'.zip'};
    my %bys = map { $_ => undef } qw(dist extension user tag);

    builder {
        enable 'ErrorDocument', 500, '/error', subrequest => 1;
        enable 'HTTPExceptions';
        enable 'StackTrace', no_print_errors => 1;
        enable 'JSONP', callback_key => 'jsonp';
        enable sub {
            my $app = shift;
            sub {
                my $res = $app->(@_);
                Plack::Util::response_cb($res, sub {
                    my $res = shift;
                    push @{ $res->[1] },
                        'X-PGXN-API-Version' => __PACKAGE__->VERSION;
                });
            };
        };

        # Sever most stuff as plain files.
        my $files = Plack::App::File->new(root => $root)->to_app;
        mount '/' => sub {
            my $env = shift;
            $env->{PATH_INFO} = '/index.html' if $env->{PATH_INFO} eq '/';
            $files->($env);
        };

        # Handle searches.
        my $searcher = PGXN::API::Searcher->new($root);
        mount '/search' => sub {
            my $req = Plack::Request->new(shift);

            # Make sure we have a valid request.
            local $1;
            return [
                404,
                ['Content-Type' => 'text/plain', 'Content-Length' => 9],
                ['not found']
            ] if $req->path_info !~ m{^/((?:d(?:oc|ist)|extension|user|tag)s)/?$};
            my $in = $1;

            my $params = $req->query_parameters;
            my $q = $params->{q};
            return [
                400,
                ['Content-Type' => 'text/plain', 'Content-Length' => 38],
                ['Bad request: Invalid or missing "q" query param.']
            ] if $q ~~ [undef, '', '*', '?'];

            # Make sure "o" and "l" params are valid.
            for my $param (qw(o l)) {
                my $val = $params->{$param};
                return [
                    400,
                    ['Content-Type' => 'text/plain', 'Content-Length' => 37],
                    [qq{Bad request: invalid "$param" query param.}]
                ] if $val && $val !~ /^\d+$/;
            }

            # Give 'em the results.
            my $json = encode_json $searcher->search(
                in     => $in,
                query  => decode_utf8($q),
                offset => scalar $params->{o},
                limit  => scalar $params->{l},
            );
            return [
                200,
                ['Content-Type' => 'application/json', 'Content-Length' => length $json ],
                [$json],
            ]
        };

        # For source browsing, some things should be text/plain.
        my $mimes = { %{ $Plack::MIME::MIME_TYPES } };
        for my $ext (keys %{ $mimes }) {
            $mimes->{$ext} = 'text/plain'
                if $mimes->{$ext} =~ /html|x-c|xml|calendar|vcard/
                || $ext ~~ [qw(.bat .css .eml .js .json .mime .swf)];
        }
        my $src_dir = Plack::App::Directory->new(
            root => catdir $root, 'src'
        )->to_app;

        mount '/src' => sub {
            local $Plack::MIME::MIME_TYPES = $mimes;
            $src_dir->(shift)
        };

        mount '/_index' => sub {
            # Never allow access here.
            return [
                404,
                ['Content-Type' => 'text/plain', 'Content-Length' => 9],
                ['not found']
            ];
        };

        mount '/error' => sub {
            my $env = shift;

            # Pull together the original request environment.
            my $err_env = { map {
                my $k = $_;
                s/^psgix[.]errordocument[.]//
                    ? /plack[.]stacktrace[.]/ ? () : ($_ => $env->{$k} )
                    : ();
            } keys %{ $env } };
            my $uri = Plack::Request->new($err_env)->uri;

            if (%{ $err_env }) {
                # Send an email to the administrator.
                # XXX Need configuration.
                require Email::MIME;
                require Email::Sender::Simple;
                require Data::Dump;
                my $email = Email::MIME->create(
                    header     => [
                        From    => $params{errors_from},
                        To      => $params{errors_to},
                        Subject => 'PGXN API Internal Server Error',
                    ],
                    attributes => {
                        content_type => 'text/plain',
                        charset      => 'UTF-8',
                    },
                    body    => "An error occurred during a request to $uri.\n\n"
                             . "Environment:\n\n" . Data::Dump::pp($err_env)
                             . "\n\nTrace:\n\n"
                             . ($env->{'plack.stacktrace.text'} || 'None found. :-(')
                             . "\n",
                );
                Email::Sender::Simple->send($email);
            }

            return [
                200, # Only handled by ErrorDocument, which keeps 500.
                ['Content-Type' => 'text/plain', 'Content-Length' => 21],
                ['internal server error']
            ];
        };

    };
}

1;

=head1 Name

PGXN::API::Router - The PGXN::API request router.

=head1 Synopsis

  # In app.pgsi
  use PGXN::API::Router;
  PGXN::API::Router->app;

=head1 Description

This class defines the HTTP request routing table used by PGXN::API. Unless
you're modifying the PGXN::API routes, you won't have to worry about it. Just
know that this is the class that Plack uses to fire up the app.

=head1 Interface

=head2 Class Methods

=head3 C<app>

  PGXN::API->app(%params);

Returns the PGXN::API Plack app. The supported parameters are:

=over

=item C<doc_root>

The path to use for the API document root.

=item C<errors_to>

An email address to which error emails should be sent.

=item C<errors_from>

An email address from which alert emails should be sent.

=back

See F<bin/pgxn_api.pgsgi> for an example usage.

=head1 Author

David E. Wheeler <david.wheeler@pgexperts.com>

=head1 Copyright and License

Copyright (c) 2011 David E. Wheeler.

This module is free software; you can redistribute it and/or modify it under
the L<PostgreSQL License|http://www.opensource.org/licenses/postgresql>.

Permission to use, copy, modify, and distribute this software and its
documentation for any purpose, without fee, and without a written agreement is
hereby granted, provided that the above copyright notice and this paragraph
and the following two paragraphs appear in all copies.

In no event shall David E. Wheeler be liable to any party for direct,
indirect, special, incidental, or consequential damages, including lost
profits, arising out of the use of this software and its documentation, even
if David E. Wheeler has been advised of the possibility of such damage.

David E. Wheeler specifically disclaims any warranties, including, but not
limited to, the implied warranties of merchantability and fitness for a
particular purpose. The software provided hereunder is on an "as is" basis,
and David E. Wheeler has no obligations to provide maintenance, support,
updates, enhancements, or modifications.

=cut
