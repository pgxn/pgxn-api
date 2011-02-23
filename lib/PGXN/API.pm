package PGXN::API v0.1.0;

use 5.12.0;
use utf8;
use MooseX::Singleton;
use DBIx::Connector;
use File::Spec::Functions qw(catfile);
use URI::Template;
use namespace::autoclean;
use DBD::Pg '2.15.1';
use Exception::Class::DBI;
use JSON::XS ();

=head1 Interface

=head2 Constructor

=head3 C<instance>

  my $app = PGXN::Manager->instance;

Returns the singleton instance of PGXN::Manager. This is the recommended way
to get the PGXN::Manager object.

=head2 Attributes

=head3 C<config>

  my $config = $pgxn->config;

Returns a hash reference of configuration information. This information is
parsed from the configuration file F<conf/test.json>, which is determined by
the C<--context> option to C<perl Build.PL> at build time.

=cut

has config => (is => 'ro', isa => 'HashRef', default => sub {
    # XXX Verify presence of required keys.
    shift->read_json_from('conf/test.json');
});

=head3 C<uri_templates>

  my $templates = $pgxn->uri_templates;

Returns a hash reference of the URI templates for the various files stored in
the mirror root. The keys are the names of the templates, and the values are
L<URI::Template> objects.

=cut

has uri_templates => (is => 'rw', isa => 'HashRef', lazy => 1, default => sub {
    my $self = shift;
    my $tmpl = $self->read_json_from(
        catfile $self->config->{mirror_root}, 'index.json'
    );
    return { map { $_ => URI::Template->new($tmpl->{$_}) } keys %{ $tmpl } };
});

=head3 C<conn>

  my $conn = $pgxn->conn;

Returns the database connection for the app. It's a L<DBIx::Connection>, safe
to use pretty much anywhere.

=cut

has conn => (is => 'ro', lazy => 1, isa => 'DBIx::Connector', default => sub {
    DBIx::Connector->new( @{ shift->config->{dbi} }{qw(dsn username password)}, {
        PrintError        => 0,
        RaiseError        => 0,
        HandleError       => Exception::Class::DBI->handler,
        AutoCommit        => 1,
        pg_enable_utf8    => 1,
        pg_server_prepare => 0,
    });
});

=head3 C<read_json_from>

  my $data = $pgxn->read_json_from($filename);

Loads the contents of C<$filename>, parses them as JSON, and returns the
resulting data structure.

=cut

sub read_json_from {
    my ($self, $fn) = @_;
    open my $fh, '<:raw', $fn or die "Cannot open $fn: $!\n";
    local $/;
    return JSON::XS->new->utf8->decode(<$fh>);
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 Name

PGXN::API - Maintain and serve a REST API to search PGXN mirrors

=head1 Synopsis

  use PGXN::API;
  my $api = PGXN::API->instance;

=head1 Description

More to come.

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
