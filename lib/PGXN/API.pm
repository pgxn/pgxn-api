package PGXN::API v0.12.7;

use 5.12.0;
use utf8;
use MooseX::Singleton;
use File::Spec::Functions qw(catfile catdir);
use URI::Template;
use JSON;
use namespace::autoclean;

=head1 Name

PGXN::API - Maintain and serve a REST API to search PGXN mirrors

=head1 Synopsis

In a cron job:

  * * * * 42 pgxn_api_sync --root /var/www/api rsync://master.pgxn.org/pgxn/

In a system start script:

  plackup pgxn_api.psgi doc_root    /var/www/api \
                        errors_from oops@example.com \
                        errors_to   alerts@example.com

=head1 Description

PGXN::API creates a REST API for PGXN networks. Of course, any PGXN mirror
provides a simple REST interface all on its own. PGXN::API is a superset of
that interface, adding additional metadata to all of the usual PGXN mirror
JSON files, as well as a search interface and browsable access to all packages
on the mirror. Hit the L<PGXN API server|http://api.pgxn.org/> for the
canonical deployment of this module.

There are two simple steps to setting up your own API server using this
module:

=over

=item * F<pgxn_api_sync>

This script syncs to a PGXN mirror via rsync and processes newly-synced data
to provide the additional data and APIs. Any PGXN mirror will do. If you need
to create your own network of mirrors first, see L<PGXN::Manager>. Consult the
L<pgxn_api_sync> documentation for details on its (minimal) options.

=item * F<pgxn_api.psgi>

A L<Plack> server for the API. In addition to the usual L<plackup> options, it
has a few of this own, specified as simple strings with no leading dashes:

=over

=item C<doc_root>

The path to use for the API document root. This is the same directory as you
manage via L<pgxn_api_sync> in a cron job. Optional. If not specified, it will
default to a directory named F<www> in the parent directory above the F<PGXN>
directory in which this module is installed. If you're running the API from a
Git checkout, that should be fine. Otherwise you should probably specify a
document root you're you'll never be able to find it.

=item C<errors_to>

An email address to which error emails should be sent. In the event of an
internal server error, the server will send an email to this address with
diagnostic information.

=item C<errors_from>

An email address from which alert emails should be sent.

=back

=back

And that's it. If you're interested in the internals of PGXN::API or in
hacking on it, read on. Otherwise, just enjoy your own API server!

=head1 Interface

=head2 Constructor

=head3 C<instance>

  my $app = PGXN::Manager->instance;

Returns the singleton instance of PGXN::Manager. This is the recommended way
to get the PGXN::API object.

=head2 Attributes

=head3 C<uri_templates>

  my $templates = $pgxn->uri_templates;

Returns a hash reference of the URI templates for the various files stored in
the API document root. The keys are the names of the templates, and the values
are L<URI::Template> objects. Includes the additional URI templates added by
L<PGXN::API::Indexer/update_mirror_meta>.

=cut

has uri_templates => (is => 'ro', isa => 'HashRef', lazy => 1, default => sub {
    my $self = shift;
    my $tmpl = $self->read_json_from(
        catfile $self->doc_root, 'index.json'
    );
    return { map { $_ => URI::Template->new($tmpl->{$_}) } keys %{ $tmpl } };
});

=head3 C<doc_root>

  my $doc_root = $pgxn->doc_root;

Returns the document root for the API server. The default is the F<www>
directory in the root directory of this distribution.

=cut

my $trig = sub {
    my ($self, $dir) = @_;
     if (!-e $dir) {
         require File::Path;
         File::Path::make_path($dir);

         # Copy over the index.html.
         require File::Copy::Recursive;

         my $file = quotemeta catfile qw(lib PGXN API.pm);
         my $blib = quotemeta catfile 'blib', '';
         (my $var = __FILE__) =~ s{(?:$blib)?$file$}{var};
         my $idx  = catfile $var, 'index.html';
         File::Copy::Recursive::fcopy($idx, $dir)
             or die "Cannot copy $idx to $dir: $!\n";

         # Pre-generate the metadata directories.
         File::Path::make_path(catdir $dir, $_)
             for qw(user tag dist extension);
     } elsif (!-d $dir) {
         die qq{Location for document root "$dir" is not a directory\n};
     }
};

has doc_root => (is => 'rw', isa => 'Str', lazy => 1, trigger => $trig, default => sub {
     my $file = quotemeta catfile qw(lib PGXN API.pm);
     my $blib = quotemeta catfile 'blib', '';
     (my $dir = __FILE__) =~ s{(?:$blib)?$file$}{www};
     $trig->(shift, $dir);
     $dir;
});

=head3 C<source_dir>

  my $source_dir = $pgxn->source_dir;

Returns the directory on the file system where sources should be unzipped,
which is just the F<src> subdirectory of C<doc_root>.

=cut

has source_dir => (is => 'ro', 'isa' => 'Str', lazy => 1, default => sub {
    my $dir = catdir shift->doc_root, 'src';
    if (!-e $dir) {
        require File::Path;
        File::Path::make_path($dir);
    } elsif (!-d $dir) {
        die qq{Location for source files "$dir" is not a directory\n};
    }
    $dir;
});

=head3 C<mirror_root>

  my $mirror_root = $pgxn->mirror_root;

Returns the directory on the file system where the PGXN mirror lives, which is
just the F<mirror> subdirectory of C<doc_root>.

=cut

has mirror_root => (is => 'rw', 'isa' => 'Str', lazy => 1, default => sub {
    my $dir = catdir shift->doc_root, 'mirror';
    if (!-e $dir) {
        require File::Path;
        File::Path::make_path($dir);
    } elsif (!-d $dir) {
        die qq{Location for source files "$dir" is not a directory\n};
    }
    $dir;
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
    return JSON->new->utf8->decode(<$fh>);
}

=head3 C<write_json_to>

  my $data = $pgxn->write_json_to($filename, $data);

Writes C<$data> to C<$filename> as JSON.

=cut

sub write_json_to {
    my ($self, $fn, $data) = @_;
    my $encoder = JSON->new->space_after->allow_nonref->indent->canonical;
    open my $fh, '>:utf8', $fn or die "Cannot open $fn: $!\n";
    print $fh $encoder->encode($data);
    close $fh or die "Cannot close $fn: $!\n";
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 Support

This module is stored in an open L<GitHub
repository|http://github.com/theory/pgxn-api/>. Feel free to fork and
contribute!

Please file bug reports via L<GitHub
Issues|http://github.com/theory/pgxn-api/issues/> or by sending mail to
L<bug-PGXN-API@rt.cpan.org|mailto:bug-PGXN-API@rt.cpan.org>.

=head1 See Also

=over

=item L<PGXN::Manager>

The heart of any PGXN network, PGXN::Manager manages distribution uploads and
mirror maintenance. You'll want to look at it if you plan to build your own
network.

=item L<WWW::PGXN>

A Perl interface over a PGXN mirror or API. Able to read the mirror or API via
HTTP or from the local file system.

=item L<PGXN::Site>

A layer over the PGXN API providing a nicely-formatted Web site for folks to
perform full text searches, read documentation, or browse information about
users, distributions, tags, and extensions.

=item L<PGXN::API::Sync>

The implementation for L<pgxn_api_sync>.

=item L<PGXN::API::Indexer>

Does the heavy lifting of processing distributions and indexing them for the
API.

=item L<PGXN::API::Searcher>

Interface for accessing the PGXN::API full text indexes. Used to do the work
of the C</search> API.

=back

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
