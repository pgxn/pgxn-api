package PGXN::API::Indexer v0.12.3;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path);
use File::Copy::Recursive qw(fcopy dircopy);
use File::Basename;
use Text::Markup;
use XML::LibXML;
use List::Util qw(first);
use List::MoreUtils qw(uniq);
use KinoSearch::Plan::Schema;
use KinoSearch::Analysis::PolyAnalyzer;
use KinoSearch::Analysis::Tokenizer;
use KinoSearch::Index::Indexer;
use namespace::autoclean;

has verbose  => (is => 'rw', isa => 'Int', default => 0);
has to_index => (is => 'ro', isa => 'HashRef', default => sub { +{
    map { $_ => [] } qw(docs dists extensions users tags)
} });

has _user_names => (is => 'ro', isa => 'HashRef', default => sub { +{ } });

has libxml   => (is => 'ro', isa => 'XML::LibXML', lazy => 1, default => sub {
    XML::LibXML->new(
        recover    => 2,
        no_network => 1,
        no_blanks  => 1,
        no_cdata   => 1,
    );
});

has index_dir => (is => 'ro', isa => 'Str', lazy => 1, default => sub {
    my $dir = catdir +PGXN::API->instance->doc_root, '_index';
    if (!-e $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }
    $dir;
});

has schemas => ( is => 'ro', isa => 'HashRef', lazy => 1, default => sub {
    my $polyanalyzer = KinoSearch::Analysis::PolyAnalyzer->new(
        language => 'en',
    );

    my $fti = KinoSearch::Plan::FullTextType->new(
        analyzer      => $polyanalyzer,
        highlightable => 0,
    );

    my $ftih = KinoSearch::Plan::FullTextType->new(
        analyzer      => $polyanalyzer,
        highlightable => 1,
    );

    my $string = KinoSearch::Plan::StringType->new(
        indexed => 1,
        stored  => 1,
    );

    my $indexed = KinoSearch::Plan::StringType->new(
        indexed => 1,
        stored  => 0,
    );

    my $stored = KinoSearch::Plan::StringType->new(
        indexed => 0,
        stored  => 1,
    );

    my $list = KinoSearch::Plan::FullTextType->new(
        indexed       => 1,
        stored        => 1,
        highlightable => 1,
        analyzer      => KinoSearch::Analysis::Tokenizer->new(
            pattern => '[^\003]+'
        ),
    );

    my %schemas;
    for my $spec (
        [ docs => [
            [ key         => $indexed ],
            [ title       => $fti     ],
            [ abstract    => $fti     ],
            [ body        => $ftih    ],
            [ dist        => $fti     ],
            [ version     => $stored  ],
            [ docpath     => $stored  ],
            [ date        => $stored  ],
            [ user        => $stored  ],
            [ user_name   => $stored  ],
        ]],
        [ dists => [
            [ key         => $indexed ],
            [ dist        => $fti     ],
            [ abstract    => $fti     ],
            [ description => $fti     ],
            [ readme      => $ftih    ],
            [ tags        => $list    ],
            [ version     => $stored  ],
            [ date        => $stored  ],
            [ user_name   => $stored  ],
            [ user        => $stored  ],
        ]],
        [ extensions => [
            [ key         => $indexed ],
            [ extension   => $fti     ],
            [ abstract    => $ftih    ],
            [ docpath     => $stored  ],
            [ dist        => $stored  ],
            [ version     => $stored  ],
            [ date        => $stored  ],
            [ user_name   => $stored  ],
            [ user        => $stored  ],
        ]],
        [ users => [
            [ key         => $indexed ],
            [ user        => $fti     ],
            [ name        => $fti     ],
            [ email       => $string  ],
            [ uri         => $string  ],
            [ details     => $ftih    ],
        ]],
        [ tags => [
            [ key         => $indexed ],
            [ tag         => $fti     ],
        ]],
    ) {
        my ($name, $fields) = @{ $spec };
        my $schema = KinoSearch::Plan::Schema->new;
        $schema->spec_field(name => $_->[0], type => $_->[1] )
            for @{ $fields };
        $schemas{$name} = $schema;
    }
    return \%schemas;
});

sub indexer_for {
    my ($self, $iname) = @_;
    KinoSearch::Index::Indexer->new(
        index  => catdir($self->index_dir, $iname),
        schema => $self->schemas->{$iname},
        create => 1,
    );
}

sub update_root_json {
    my $self = shift;
    my $api  = PGXN::API->instance;
    say "Updating mirror root JSON" if $self->verbose;

    # Augment and write index.json.
    my $src = catfile $api->mirror_root, 'index.json';
    my $dst = catfile $api->doc_root, 'index.json';
    my $tmpl = $api->read_json_from($src);
    $tmpl->{source}    = "/src/{dist}/{dist}-{version}/";
    $tmpl->{search}    = '/search/{in}/';
    $tmpl->{userlist}  = '/users/{char}.json';
    ($tmpl->{htmldoc}  = $tmpl->{meta}) =~ s{/META[.]json$}{/{+docpath}.html};
    $api->write_json_to($dst, $tmpl);

    return $self;
}

sub copy_from_mirror {
    my $self = shift;
    my @path = split qr{/} => shift;
    my $api  = PGXN::API->instance;
    my $src  = catfile $api->mirror_root, @path;
    my $dst  = catfile $api->doc_root, @path;
    say "Copying $src to $dst" if $self->verbose > 1;
    fcopy $src, $dst or die "Cannot copy $src to $dst: $!\n";
}

sub parse_from_mirror {
    my ($self, $path, $format) = @_;
    my @path = split qr{/} => $path;
    my $api  = PGXN::API->instance;
    my $src  = catfile $api->mirror_root, @path;
    my $dst  = catfile $api->doc_root, @path;
    my $mark = Text::Markup->new(default_encoding => 'UTF-8');
    $dst =~ s/[.][^.]+$/.html/;

    say "Parsing $src to $dst" if $self->verbose > 1;
    make_path dirname $dst;

    my $doc = $self->_parse_html_string($mark->parse(
        file   => $src,
        format => $format,
    ));

    open my $fh, '>:utf8', $dst or die "Cannot open $dst: $!\n";
    $doc = _clean_html_body($doc->findnodes('/html/body'));
    print $fh $doc->toString, "\n";
    close $fh or die "Cannot close $dst: $!\n";

    return $self;
}

sub add_distribution {
    my ($self, $params) = @_;

    $self->copy_files($params)        or return $self->_rollback;
    $self->merge_distmeta($params)    or return $self->_rollback;
    $self->update_user($params)       or return $self->_rollback;
    $self->update_tags($params)       or return $self->_rollback;
    $self->update_extensions($params) or return $self->_rollback;
    return $self->_commit;
}

sub copy_files {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    say "  Copying $meta->{name}-$meta->{version} files" if $self->verbose;

    # Need to copy the README, zip file, and dist meta file.
    for my $file (qw(download readme)) {
        my $src = $self->mirror_file_for($file => $meta);
        my $dst = $self->doc_root_file_for($file => $meta);
        next if $file eq 'readme' && !-e $src;
        say "    $meta->{name}-$meta->{version}.$file" if $self->verbose > 1;
        fcopy $src, $dst or die "Cannot copy $src to $dst: $!\n";
    }
    return $self;
}

sub merge_distmeta {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    say "  Merging $meta->{name}-$meta->{version} META.json" if $self->verbose;

    # Merge the list of versions into the meta file.
    my $api = PGXN::API->instance;
    my $dist_file = $self->mirror_file_for(dist => $meta);
    my $dist_meta = $api->read_json_from($dist_file);
    $meta->{releases} = $dist_meta->{releases};

    # Add a list of special files and docs.
    $meta->{special_files} = $self->_source_files($p);
    $meta->{docs}          = $self->parse_docs($p);

    # Add doc paths to provided extensions where possible.
    while (my ($ext, $data) = each %{ $meta->{provides} }) {
        $data->{docpath} = first {
            my ($basename) = m{([^/]+)$};
            $basename eq $ext;
        } keys %{ $meta->{docs} };
    }

    # Write the merge metadata to the file.
    my $fn = $self->doc_root_file_for(meta => $meta);
    make_path dirname $fn;
    $api->write_json_to($fn, $meta);

    $dist_file = $self->doc_root_file_for(dist => $meta );
    if ($meta->{release_status} eq 'stable') {
        # Copy it to its dist home.
        fcopy $fn, $dist_file or die "Cannot copy $fn to $dist_file: $!\n";
    } else {
        # Determine latest stable release or fall back on testing, unstable.
        for my $status (qw(stable testing unstable)) {
            my $rels = $meta->{releases}{$status} or next;
            $meta->{version} = $rels->[0]{version};
            last;
        }

        # Now write out the dist version.
        $api->write_json_to($dist_file => $meta);
    }

    # Index it if it's a new stable release.
    $self->_index(dists => {
        key         => $meta->{name},
        dist        => $meta->{name},
        abstract    => $meta->{abstract},
        description => $meta->{description} || '',
        readme      => $self->_readme($p),
        tags        => join("\003" => @{ $meta->{tags} || [] }),
        version     => $meta->{version},
        date        => $meta->{date},
        user_name   => $self->_get_user_name($meta),
        user        => $meta->{user},
    }) if $meta->{release_status} eq 'stable';

    # Now update all older versions with the complete list of releases.
    for my $releases ( values %{ $meta->{releases} }) {
        for my $release (@{ $releases}) {
            next if $release->{version} eq $meta->{version};
            local $meta->{version} = $release->{version};

            my $vmeta_file = $self->doc_root_file_for(meta => $meta);
            next unless -e $vmeta_file;
            my $vmeta = $api->read_json_from($vmeta_file);
            $vmeta->{releases} = $meta->{releases};
            $api->write_json_to($vmeta_file => $vmeta);
        }
    }

    return $self;
}

sub merge_user {
    my ($self, $nick) = @_;
    return $self if $self->_user_names->{$nick};

    say "  Merging user $nick" if $self->verbose;
    my $api      = PGXN::API->instance;
    my $mir_file = $self->mirror_file_for('user', undef, user => $nick);
    my $mir_data = $api->read_json_from($mir_file);
    my $doc_file = $self->doc_root_file_for('user', undef, user => $nick);
    my $doc_data = -e $doc_file ? $api->read_json_from($doc_file) : {};

    # Merge in the releases and rewrite.
    $mir_data->{releases} = $doc_data->{releases} || {};
    $api->write_json_to($doc_file, $mir_data);

    # Update the full name lookup & the search index and return.
    $self->_user_names->{lc $nick} = $mir_data->{name};
    $self->_index_user($mir_data);
    return $self;
}

sub update_user {
    my ($self, $p) = @_;
    say "  Updating user $p->{meta}{user}" if $self->verbose;
    my $user = $self->_update_releases(user => $p->{meta});
    $self->_index_user($user) if $p->{meta}->{release_status} eq 'stable';
    return $self;
}

sub update_tags {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    say "  Updating $meta->{name}-$meta->{version} tags" if $self->verbose;

    my $tags = $meta->{tags} or return $self;

    for my $tag (@{ $tags }) {
        say "    $tag" if $self->verbose > 1;
        my $data = $self->_update_releases(tag => $meta, tag => lc $tag);
        $self->_index(tags => {
            key => lc $tag,
            tag => $tag,
        }) if $p->{meta}->{release_status} eq 'stable';
    }
    return $self;
}

sub update_extensions {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    my $api = PGXN::API->instance;
    say "  Updating $meta->{name}-$meta->{version} extensions"
        if $self->verbose;

    while (my ($ext, $data) = each %{ $meta->{provides} }) {
        say "    $ext" if $self->verbose > 1;
        # Read in extension metadata from the mirror.
        my $mir_file = $self->mirror_file_for(
            extension => $meta,
            extension => $ext,
        );
        my $mir_meta = $api->read_json_from($mir_file);

        # Read in extension metadata from the doc root.
        my $doc_file = $self->doc_root_file_for(
            extension => $meta,
            extension => $ext,
        );
        my $doc_meta = -e $doc_file ? $api->read_json_from($doc_file) : {};

        # Add the abstract and doc path to the mirror data.
        my $status = $meta->{release_status};
        $mir_meta->{$status}{abstract} = $data->{abstract};
        $mir_meta->{$status}{docpath} = $data->{docpath} if $data->{docpath};

        # Copy the other release status data from the doc data.
        $mir_meta->{$_} = $doc_meta->{$_} for grep {
            $doc_meta->{$_} && $_ ne $status
        } qw(stable testing unstable);

        # Copy the version info from the doc to the mirror and add the date.
        my $version   = $data->{version};
        my $mir_dists = $mir_meta->{versions}{$version};
        my $doc_dists = $doc_meta->{versions}{$version} ||= [];

        # Copy the doc root versions.
        $mir_meta->{versions} = $doc_meta->{versions};

        # Find the current release distribution in the versions.
        for my $i (0..$#$mir_dists) {
            my $dist = $mir_dists->[$i];
            # Make sure the doc dists are in sync.
            if (!$doc_dists->[$i]
                || $dist->{dist} ne $doc_dists->[$i]{dist}
                || $dist->{version} ne $doc_dists->[$i]{version}
            ) {
                splice @{ $doc_dists }, $i, 0, $dist;
            }

            # Is this the distribution we're currently updating?
            if ($dist->{dist} eq $meta->{name}
                && $dist->{version} eq $meta->{version}
            ) {
                # Got it. Add the release date.
                $dist->{date} = $meta->{date};
            }
        }

        # Write it back out and index it.
        $api->write_json_to($doc_file => $mir_meta);
        $self->_index(extensions => {
            key         => $mir_meta->{extension},
            extension   => $mir_meta->{extension},
            abstract    => $mir_meta->{stable}{abstract},
            docpath     => $data->{docpath} || '',
            dist        => $meta->{name},
            version     => $mir_meta->{stable}{version},
            date        => $meta->{date},
            user_name   => $self->_get_user_name($meta),
            user        => $meta->{user},
        }) if $meta->{release_status} eq 'stable';
    }

    return $self;
}

sub find_docs {
    my ($self, $p) = @_;
    my $meta   = $p->{meta};
    my $dir    = $self->doc_root_file_for(source => $meta);
    my $prefix = quotemeta "$meta->{name}-$meta->{version}";
    my $skip   = { directory => [], file => [], %{ $meta->{no_index} || {} } };
    my $markup = Text::Markup->new;
    my @files  = grep { $_ && -e catfile $dir, $_ } map { $_->{docfile} }
        values %{ $meta->{provides} };

    for my $member ($p->{zip}->members) {
        next if $member->isDirectory;

        # Skip files that should not be indexed.
        (my $fn = $member->fileName) =~ s{^$prefix/}{};
        next if first { $fn eq $_ } @{ $skip->{file} };
        next if first { $fn =~ /^\Q$_/ } @{ $skip->{directory} };
        push @files => $fn if $markup->guess_format($fn)
            || $fn =~ /^README(?:[.][^.]+)?$/i;
    }
    return uniq @files;
}

sub parse_docs {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    say "  Parsing $meta->{name}-$meta->{version} docs" if $self->verbose;

    my $markup = Text::Markup->new(default_encoding => 'UTF-8');
    my $dir    = $self->doc_root_file_for(source => $meta);

    # Find all doc files and write them out.
    my (%docs, %seen);
    for my $fn ($self->find_docs($p)) {
        next if $seen{$fn}++;
        my $src = catfile $dir, $fn;
        next unless -e $src;
        my $doc = $self->_parse_html_string($markup->parse(file => $src));

        (my $noext = $fn) =~ s{[.][^.]+$}{};
        # XXX Nasty hack until we get + operator in URI Template v4.
        local $URI::Escape::escapes{'/'} = '/';
        my $dst  = $self->doc_root_file_for(
            htmldoc    => $meta,
            docpath    => $noext,
            '+docpath' => $noext, # XXX Part of above-mentioned hack.
        );
        make_path dirname $dst;

        # Determine the title before we mangle the HTML.
        my $basename = basename $noext;
        my $title = $doc->findvalue('/html/head/title')
                 || $doc->findvalue('//h1[1]')
                 || $basename;

        # Grab abstract if this looks like extension documentation.
        my $abstract = $meta->{provides}{$basename}
            ? $meta->{provides}{$basename}{abstract}
            : undef;

        # Clean up the HTML and write it out.
        open my $fh, '>:utf8', $dst or die "Cannot open $dst: $!\n";
        $doc = _clean_html_body($doc->findnodes('/html/body'));
        print $fh $doc->toString, "\n";
        close $fh or die "Cannot close $dst: $!\n";

        $docs{$noext} = {
            title => $title,
            ($abstract) ? (abstract => $abstract) : ()
        };

        # Add it to the search index.
        $self->_index(docs => {
            key       => "$meta->{name}/$noext",
            docpath   => $noext,
            title     => $title,
            abstract  => $abstract,
            body      => _strip_html( $doc->findnodes('.//div[@id="pgxnbod"]')->shift),
            dist      => $meta->{name},
            version   => $meta->{version},
            date      => $meta->{date},
            user_name => $self->_get_user_name($meta),
            user      => $meta->{user},
        }) if $meta->{release_status} eq 'stable'
            && $fn !~ qr{^(?i:README(?:[.][^.]+)?)$};
    }
    return \%docs;
}

sub _parse_html_string {
    shift->libxml->parse_html_string(shift, {
        suppress_warnings => 1,
        suppress_errors   => 1,
        recover           => 2,
    });

}

sub mirror_file_for {
    my $self = shift;
    return catfile +PGXN::API->instance->mirror_root,
        $self->_uri_for(@_)->path_segments;
}

sub doc_root_file_for {
    my $self = shift;
    return catfile +PGXN::API->instance->doc_root,
        $self->_uri_for(@_)->path_segments;
}

sub finalize {
    my $self = shift;
    $self->update_user_lists;
    $self->_commit;
    return $self;
}

sub update_user_lists {
    my $self  = shift;
    my $api   = PGXN::API->instance;
    my $names = $self->_user_names;
    my %users_for;

    say "Updating user lists" if $self->verbose;
    while (my ($nick, $name) = each %{ $names }) {
        my $char = lc substr $nick, 0, 1;
        push @{ $users_for{$char} ||= [] } => { user => $nick, name => $name };
    }


    while (my ($char, $users) = each %users_for ) {
        say "  Updating $char.json" if $self->verbose > 1;
        my $fn = $self->doc_root_file_for('userlist', undef, char => $char);
        my $list = -e $fn ? $api->read_json_from($fn) : do {
            make_path dirname $fn;
            [];
        };

        # Load the users into a hash to eliminate dupes.
        my %updated = map { lc $_->{user} => $_ } @{ $list }, @{ $users };

        # Write them out in order by nickname.
        $api->write_json_to($fn, [
            map  { $updated{ $_ } }
            sort { $a cmp $b } keys %updated
        ]);
    }
    return $self;
}

sub _idx_distmeta {
    my $meta = shift;
    my @lines = (
        "$meta->{license} license",
        (ref $meta->{maintainer} ? @{ $meta->{maintainer} } : ($meta->{maintainer})),
    );

    while (my ($k, $v) = each %{ $meta->{provides}} ) {
        push @lines => $v->{abstract} ? "$k: $v->{abstract}" : $k;
    }
    push @lines, $meta->{description} if $meta->{description};
    return join $/ => @lines;
}

sub _get_user_name {
    my ($self, $meta) = @_;
    return $self->_user_names->{ lc $meta->{user} } ||= do {
        my $user = PGXN::API->instance->read_json_from(
            $self->mirror_file_for(user => $meta)
        );
        $user->{name};
    };
}

sub _strip_html {
    my $ret = '';
    for my $elem (@_) {
        $ret .= $elem->nodeType == XML_TEXT_NODE ? $elem->data
              : $elem->nodeType == XML_ELEMENT_NODE && $elem->nodeName eq 'br' ? ' '
              : _strip_html($elem->childNodes);
    }

    # Normalize whitespace.
    $ret =~ s/^\s+//;
    $ret =~ s/\s+$//;
    $ret =~ s/[\t\n\r]+|\s{2,}/ /gms;
    return $ret;
}

sub _update_releases {
    my $self = shift;
    my $meta = $_[1];
    my $api = PGXN::API->instance;

    # Read in metadata from the mirror.
    my $mir_file = $self->mirror_file_for(@_);
    my $mir_meta = $api->read_json_from($mir_file);

    # Read in metadata from the doc root.
    my $doc_file = $self->doc_root_file_for(@_);
    my $doc_meta = -e $doc_file ? $api->read_json_from($doc_file) : $mir_meta;

    # Update with latest release info and abstract.
    my $rels = $doc_meta->{releases}{$meta->{name}}
        = $mir_meta->{releases}{$meta->{name}};
    $rels->{abstract} = $meta->{abstract};

    # Write out the data to the doc root.
    $api->write_json_to($doc_file => $doc_meta);
    return $doc_meta;
}

sub _index_user {
    my ($self, $user) = @_;
    my $data = {
        key      => lc $user->{nickname},
        user     => $user->{nickname},
        name     => $user->{name},
        email    => $user->{email},
        uri      => $user->{uri},
    };

    # Gather up any other details.
    $data->{details} = join(
        "\n",
        grep { $_ }
        map { $user->{$_} }
        sort grep { !$data->{$_} && !ref $user->{$_} && $_ ne 'nickname' }
        keys %{ $user }
    );
    $self->_index(users => $data);
}

sub _index {
    my ($self, $index, $data) = @_;
    push @{ $self->to_index->{ $index } } => $data;
}

sub _rollback {
    my $self = shift;
    @{ $self->to_index->{$_} } = () for keys %{ $self->to_index };
    return;
}

sub _commit {
    my $self = shift;
    my $to_index = $self->to_index;

    for my $iname (keys %{ $to_index }) {
        my $indexer = $self->indexer_for($iname);
        for my $doc (@{ $to_index->{$iname} }) {
            $indexer->delete_by_term( field => 'key', term => $doc->{key} );
            $indexer->add_doc($doc);
        }
        $indexer->commit;
        @{ $to_index->{$iname} } = ();
    }

    return $self;
}

sub _uri_for {
    my ($self, $name, $meta, @params) = @_;
    PGXN::API->instance->uri_templates->{$name}->process(
        dist    => lc($meta->{name}    || ''),
        version => lc($meta->{version} || ''),
        user    => lc($meta->{user}    || ''),
        @params,
    );
}

sub _source_files {
    my ($self, $p) = @_;
    my $zip = $p->{zip};
    my $prefix  = quotemeta "$p->{meta}{name}-$p->{meta}{version}";
    my @files;
    for my $regex (
        qr{Change(?:s|Log)(?:[.][^.]+)?}i,
        qr{README(?:[.][^.]+)?}i,
        qr{LICENSE(?:[.][^.]+)?}i,
        qr{META[.]json},
        qr{Makefile},
        qr{MANIFEST},
        qr{\Q$p->{meta}{name}\E[.]control},
    ) {
        my ($member) = $zip->membersMatching(qr{^$prefix/$regex$});
        unless ($member) {
            ($member) = $zip->membersMatching(qr{^$prefix/$regex[.]in$});
            next unless $member;
        }
        (my $fn = $member->fileName) =~ s{^$prefix/}{};
        push @files => $fn;
    }
    return \@files;
}

sub _readme {
    my ($self, $p) = @_;
     my $zip = $p->{zip};
    my $prefix  = quotemeta "$p->{meta}{name}-$p->{meta}{version}";
    my ($member) = $zip->membersMatching(
        qr{^$prefix/(?i:README(?:[.][^.]+)?)$}
    );
    return '' unless $member;
    my $contents = $member->contents || '';
    utf8::decode $contents;
    # Normalize whitespace.
    $contents =~ s/^\s+//;
    $contents =~ s/\s+$//;
    $contents =~ s/[\t\n\r]+|\s{2,}/ /gms;
    return $contents;
}

# List of allowed elements and attributes.
# http://www.w3schools.com/tags/default.asp
# http://www.w3schools.com/html5/html5_reference.asp
my %allowed = do {
    my $attrs = { title => 1, dir => 1, lang => 1 };
    map { $_ => $attrs } qw(
        a
        abbr
        acronym
        address
        area
        article
        aside
        audio
        b
        bdo
        big
        blockquote
        br
        canvas
        caption
        cite
        code
        col
        colgroup
        dd
        del
        details
        dfn
        dir
        div
        dl
        dt
        em
        figcaption
        figure
        footer
        h1
        h2
        h3
        h4
        h5
        h6
        header
        hgroup
        hr
        i
        img
        ins
        kbd
        li
        map
        mark
        meter
        ol
        output
        p
        pre
        q
        rp
        rt
        ruby
        s
        samp
        section
        small
        source
        span
        strike
        strong
        sub
        summary
        sup
        table
        tbody
        td
        tfoot
        th
        thead
        time
        tr
        tt
        u
        ul
        var
        video
        wbr
        xmp
    );
};

# A few elements may retain other attributes.
$allowed{a}        = { %{ $allowed{a} }, map { $_  => 1 } qw(href hreflang media rel target type) };
$allowed{area}     = { %{ $allowed{area} }, map { $_  => 1 } qw(alt coords href hreflang media rel shape target tytpe) };
$allowed{article}  = { %{ $allowed{article} }, cite  => 1, pubdate   => 1 };
$allowed{audio}    = { %{ $allowed{audio} }, map { $_  => 1 } qw(src) };
$allowed{canvas}   = { %{ $allowed{canvas} }, map { $_  => 1 } qw(height width) };
$allowed{col}      = { %{ $allowed{col} }, map { $_  => 1 } qw(span align valign width) };
$allowed{colgroup} = $allowed{col};
$allowed{del}      = { %{ $allowed{del} },     cite  => 1, datetime  => 1 };
$allowed{details}  = { %{ $allowed{details} }, open  => 1 };
$allowed{img}      = { %{ $allowed{img} }, map { $_  => 1 } qw(alt src height ismap usemap width) };
$allowed{ins}      = $allowed{del};
$allowed{li}       = { %{ $allowed{li} }, value  => 1 };
$allowed{map}      = { %{ $allowed{map} }, name  => 1 };
$allowed{meter}    = { %{ $allowed{meter} }, map { $_  => 1 } qw(high low min max optimum value) };
$allowed{source}   = { %{ $allowed{source} }, map { $_  => 1 } qw(media src type) };
$allowed{ol}       = { %{ $allowed{ol} }, revese  => 1, start  => 1 };
$allowed{q}        = { %{ $allowed{q} }, cite  => 1 };
$allowed{section}  = $allowed{q};
$allowed{table}    = { %{ $allowed{table} }, map { $_  => 1 } qw(sumary width) };
$allowed{tbody}    = { %{ $allowed{tbody} }, map { $_  => 1 } qw(align valign) };
$allowed{td}       = { %{ $allowed{td} }, map { $_  => 1 } qw(align colspan headers height nowrap rowspan scope valign width) };
$allowed{tfoot}    = $allowed{tbody};
$allowed{th}       = $allowed{td};
$allowed{tfoot}    = $allowed{tbody};
$allowed{tr}       = $allowed{tbody};
$allowed{time}     = { %{ $allowed{time} }, datetime  => 1, pubdate => 1 };
$allowed{video}    = { %{ $allowed{video} }, map { $_  => 1 } qw(audio height poster src width) };

# We delete all other elements except for these, for which we keep text.
my %keep_children = map { $_ => 1 } qw(
    blink
    center
    font
);

sub _clean_html_body {
    my $top = my $elem = shift;

    # Create an element for the table of contents.
    my $toc = XML::LibXML::Element->new('div');
    $toc->setAttribute(id => 'pgxntoc');
    $toc->appendText("\n    ");
    my $contents = XML::LibXML::Element->new('h3');
    $contents->appendText('Contents');
    $toc->appendChild($contents);
    $toc->appendText("\n    ");

    my $topul = my $ul = XML::LibXML::Element->new('ul');
    $ul->setAttribute(class => 'pgxntocroot');
    $toc->addChild($ul);

    my %gen_ids;
    my $level = 1;

    while ($elem) {
        if ($elem->nodeType == XML_ELEMENT_NODE) {
            my $name = $elem->nodeName;
            if ($name eq 'body') {
                # Remove all attributes and rewrite it as a div.
                $elem->removeAttribute($_) for map {
                    $_->nodeName
                } $elem->attributes;
                $elem->setNodeName('div');
                $elem->setAttribute(id => 'pgxnbod');
                $elem = $elem->firstChild || last;
                next;
            }

            if (my $attrs = $allowed{$name}) {
                # Keep only allowed attributes.
                $elem->removeAttribute($_) for grep { !$attrs->{$_} }
                    map { $_->nodeName } $elem->attributes;

                if ($name =~ /^h([123])$/) {
                    my $header = $1;
                    # Create an ID.
                    # http://www.w3schools.com/tags/att_standard_id.aps
                    (my $id = $elem->textContent) =~ s{^([^a-zA-Z])}{L$1};
                    $id =~ s{[^a-zA-Z0-9_:.-]+}{.}g;
                    $id .= $gen_ids{$id}++ || '';
                    $elem->setAttribute(id => $id);
                    if ($header != $level) {
                        # Add and remove unordered lists as needed.
                        while ($header < $level) {
                            $ul->appendText("\n    " . '  ' x (2 * $level - 2));
                            my $li = $ul->parentNode;
                            $li->appendText("\n    " . '  ' x (2 * $level - 3));
                            $ul = $li->parentNode;
                            $level--;
                        }
                        while ($header > $level) {
                            my $newul = XML::LibXML::Element->new('ul');
                            my $li = $ul->find('./li[last()]')->shift || do {
                                XML::LibXML::Element->new('li');
                            };
                            $li->appendText("\n    " . '  ' x (2 * $level));
                            $li->addChild($newul);
                            $ul = $newul;
                            $level++;
                        }
                    }

                    # Add the item to the TOC.
                    my $li = XML::LibXML::Element->new('li');
                    my $a = XML::LibXML::Element->new('a');
                    $a->setAttribute(href => "#$id");
                    $a->appendText($elem->textContent);
                    $li->addChild($a);
                    $ul->appendText("\n    " . '  ' x (2 * $level - 1));
                    $ul->addChild($li);
                }

                # Descend into children.
                if (my $next = $elem->firstChild) {
                    $elem = $next;
                    next;
                }
            } else {
                # You are not wanted.
                my $parent = $elem->parentNode;
                if ($keep_children{$name}) {
                    # Keep the children.
                    $parent->insertAfter($_, $elem) for reverse $elem->childNodes;
                }

                # Take it out and jump to the next sibling.
                my $next = $elem;
                NEXT: {
                    if (my $sib = $next->nextSibling) {
                        $next = $sib;
                        last;
                    }

                    # No sibling, try parent's sibling
                    $next = $next->parentNode;
                    redo if $next && $next ne $top;
                }
                $parent->removeChild($elem);
                $elem = $next;
                next;
            }
        }

        # Find the next node.
        NEXT: {
            if (my $sib = $elem->nextSibling) {
                $elem = $sib;
                last;
            }

            # No sibling, try parent's sibling
            $elem = $elem->parentNode;
            redo if $elem;
        }
    }

    # Add the documentation to the overall document and stringify.
    my $doc = XML::LibXML::Element->new('div');
    $doc->setAttribute(id => 'pgxndoc');
    $doc->appendText("\n  ");
    $doc->addChild($toc);
    $topul->appendText("\n    ");
    $toc->appendText("\n  ");
    $doc->appendText("\n  ");
    $doc->addChild($top);
    $top->appendText("");
    $doc->appendText("\n");
    return $doc;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 Name

PGXN::API::Index - PGXN API distribution indexer

=head1 Synopsis

  use PGXN::API::Indexer;
  my $indexer = PGXN::API::Indexer->new(verbose => $verbosity);
  $indexer->add_distribution({ meta => $dist_meta, zip => $zip });

=head1 Description

This module does the heavy lifting of indexing a PGXN distribution for the API
server. Simply hand off the metadata loaded from a distribution F<META.json>
file and an L<Archive::Zip> object loaded with the distribution download file
and it will:

=over

=item 1

Copy the distribution files from the local mirror to the API document root.

=item 2

Merge the distribution metadata between the metadata files matching the
C<meta> and C<dist> URI templates. The templates are themselves loaded from
the F</index.json> file from the mirror root. The two metadata documents each
get additional data useful for API calls and become identical, as well.

=item 3

Searches for any and all C<README> files and documentation files and parses
them into HTML. The format of all documentation files may be any recognized by
L<Text::Markup>. The parsed HTML is then cleaned up and an table of contents
added before being saved to its new home as a partial HTML document. See the
pgTAP documentation L<on the PGXN API
server|http://api.pgxn.org/dist/pgTAP/doc/pgtap.html> for a nice example of
the resulting format (generated from a L<Markdown document in the pgTAP
distribution|http://github.org/theory/pgtap/doc/pgtap.md>) and the same
document used L<on the PGXN
site|http://www.pgxn.org/dist/pgTAP/doc/pgtap.html> for how it can be used.

=item 4

Merges the user, tag, and extension metadata for the distribution, adding
extra data points useful for the API.

=item 5

Adds all documentation as well as, distribution, extension, user, and tag
metadata, to full text indexes. These may be queried via the API server
(provided by F<bin/pgxn_api.psgi> or locally with L<PGXN::API::Searcher>.

=back

The result is a robust API with much more information than is provided by the
spare metadata JSON files on a normal PGXN mirror. The interface offered via
the F<pgxn_api.psgi> server is then a superset of that offered by a normal
mirror. It's a PGXN mirror + more!

=head1 Class Interface

=head2 Constructor

=head3 C<new>

  my $indexer = PGXN::API::Indexer->new(verbose => $verbosity);

Constructs and returns a new PGXN::API::Indexer object. There is only one
parameter, C<verbose>, an incremental integer specifying the level of
verbosity to use while indexing. Defaults to 0, which is as quiet as possible.

=head1 Instance Interface

=head2 Instance Methods

=head3 C<update_root_json>

Updates the F<index.json> file at the root of the document root, copying the
mirror's F</index.json> to the API's F</index.json> and adding three
additional templates:

=over

=item C<source>

URI for browsing the source of a distribution. Its value is

  /src/{dist}/{dist}-{version}/

=item C<search>

The URI for search/ Its value is

  /search/{in}/

=item C<doc>

The URI for a documentation file. It's format is copied form the "meta"
template, with the trailing C<META.json> replaced with `{+doc}.html}`.
`{+doc}` is the path to a documentation file (without a file extension) and
may include slashes.

=back

=head3 C<copy_from_mirror>

  $indexer->copy_from_mirror($path);

Copies a file from the mirror to the document root. The path argument must be
specified using Unix semantics (that is, using slashes for directory
separators). Used by L<PGXN::API::Sync> to sync metadata files and stats.

=head3 C<parse_from_mirror>

  $indexer->parse_from_mirror($path, $format);

Uses Text::Markup to parse a file at C<$path> on the mirror, sanitizes it and
generates a table of contents, and saves it to the document root with its
suffix changed to F<.html>. Pass an optional C<format> argument to force
Text::Markup to parse the document in that format.

=head3 C<add_distribution>

  $indexer->add_distribution({ meta => $meta, zip => $zip });

Adds a distribution to the index. This is the main method called to do all the
work of indexing a distribution. The two required parameters are:

=over

=item C<meta>

The metadata file loaded from a distribution F<META.json> file.

=item c<zip>

An L<Archive::Zip> object loaded up with the distribution download file.

=back

=head3 C<copy_files>

  $indexer->copy_files($params);

Copies a distribution download and C<README> files from the mirror to the API
document root. The supported parameters are the same as those for
C<add_distribution()>, by which this method is called internally.

=head3 C<merge_distmeta>

  $indexer->copy_files($params);

Merges the distribution metadata between the C<meta> file and the C<dist>
file. These are the names of URI templates in the F</index.json> file. The
supported parameters are the same as those for C<add_distribution()>, by which
this method is called internally.

Once the merge is complete, the two files will be identical, although the
C<dist> file will only be updated if the new distribution's release status is
"stable" (or if there are no stable distributions). In addition to the data
they provided via the mirror server, they will also have the following new
keys:

=over

=item C<special_files>

An array of the names of special files in the distribution. These include any
files which match the following regular expressions:

=over

=item C<qr{Change(?:s|Log)(?:[.][^.]+)?}i>

=item C<qr{README(?:[.][^.]+)?}i>

=item C<qr{LICENSE(?:[.][^.]+)?}i>

=item C<qr{META[.]json}>

=item C<qr{Makefile}>

=item C<qr{MANIFEST}>

=back

=item C<docs>

A hash (dictionary) listing the documentation files found in the distribution.
These include a C<README> file and any files found under the F<doc> or F<docs>
directory. The keys are paths to each document (without the file name
extension) and the values are document titles.

=item C<provides/$extension/doc>

Each extension listed under C<provides> will get a new key, C<doc>, if there
is a document in the C<docs> hash with the same base name as the extension.
This is on the assumption that an included extension will have for its
documentation a file with the same name (minus the file name extension) as the
extension itself. The value will be the path to the document, the same as the
key for the same document in the C<docs> hash.

=back

Getting all of this documentation information is handled via a call to
C<parse_docs()>, which of course also parses any docs it finds.

And finally, this method updates all other "dist" files for previous versions
of the distribution with the latest C<releases> information, so that they all
have a complete list of all releases of the distribution.

=head3 C<find_docs>

  my @docs = $indexer->find_docs($params);

Finds all the likely documentation files in the zip archive. A file is
considered to contain documentation if one of the following is true:

=over

=item *

It is identified under the C<doc> key in the C<provides> hash of the metadata
and exists in the zip archive.

=item *

It has an extension recognized by L<Text::Markup> and is not excluded by the
C<no_index> key in the metadata.

=back

The list of files returned are relative to an unzipped archive root -- that
is, they do not include the top-level directory prefix.

Used internally by C<parse_docs()> to determine what files to parse.

=head3 C<parse_docs>

  $indexer->parse_docs($params);

Searches the distribution download file fora C<README> and for documentation
files in a F<doc> or F<docs> directory, parses them into HTML (using
L<Text::Markup>), and the runs them through L<XML::LibXML> to remove all
unsafe HTML, to generate a table of contents, and to save them as partial HTML
files. Their contents are also added to the "doc" full text index. Files
matching the rules under the C<no_index> key in the metadata (if any) will be
ignored.

Returns a hash reference with information about the documentation, with the
keys being paths to the documentation (without file name extensions) and the
values being the titles of the documents. The supported parameters are the
same as those for C<add_distribution()>; this method is called internally by
C<merge_distmeta()>.

=head3 C<update_extensions>

  $indexer->update_extensions($params);

Iterates over the list of extensions under the C<provides> key in the metadata
and updates their respective metadata files (as specified by the "extension"
URI template) and updates them with additional information.The supported
parameters are the same as those for C<add_distribution()>, by which this
method is called internally.

The additional metadata added to the extension files is:

=over

=item C<$release_status/doc>

The path to the documentation (without the file name extension) for the
extension for the given release status.


=item C<$release_status/abstract>

The abstract for the latest release of the given release status.

=item C<versions/$version/date>

The date of a given release.

=back

The contents of the extension, including is name, abstract, distribution,
distribution version, and doc path are added to the "extension" full text
index.

=head3 C<update_tags>

  $indexer->update_tags($params);

Iterates over the list of tags under the C<tags> key in the metadata and
updates their respective metadata files (as specified by the "tag" URI
template). The supported parameters are the same as those for
C<add_distribution()>, by which this method is called internally.

The data added to each tag metadata file is the list of releases copied from
the distribution metadata. A tag metadata file thus ends up with a complete
list of all distribution releases associated with the tag. The tag is then
added to the "tag" full text index.

=head3 C<update_user>

  $indexer->update_user($params);

Updates the metadata for the user specified under the C<user> key in the
distribution metadata. The updated file is specified by the "user" URI
template. The supported parameters are the same as those for
C<add_distribution()>, by which this method is called internally.

The data added to each user metadata file is the list of releases copied from
the distribution metadata. A user metadata file thus ends up with a complete
list of all distribution releases made by the user. The user is then added to
the "user" full text index, where the name, nickname, email address, URI, and
other metadata are indexed.

=head3 C<merge_user>

  $indexer->merge_user($nickname);

Pass in the nickname of a user file and JSON file for that user on the mirror
will be merged with the document index copy. If no document index copy exists,
one will be created with an empty hash under the C<releases> key. Called by
L<PGXN::API::Sync> for each user file seen during the sync.

=head3 C<finalize>

  $indexer->finalize;

Method to call when a sync completes. At the moment, all it does is call
C<update_user_lists()> and commit any remaining index data to the full text
index.

=head3 C<update_user_lists>

  $indexer->update_user_lists;

Updates the user list files for any users seen in the distribution metadata
processed by C<merge_distmeta()>.

=head3 C<doc_root_file_for>

  my $doc_root_file = $indexer->doc_root_file_for($tmpl_name, $meta);

Returns the full path to a file in the API document root for the specified URI
template, and using the specified distribution metadata to populate the
variable values in the template. Used internally to figure out what files
to write to.

=head3 C<mirror_file_for>

  my $mirror_file = $indexer->mirror_file_for($tmpl_name, $meta);

Returns the full path to a file in local PGXN mirror directory for the
specified URI template, and using the specified distribution metadata to
populate the variable values in the template. Used internally to figure out
what files to read from.

=head3 C<indexer_for>

  my $ksi = $indexer->indexer_for($index_name);

Returns a L<KinoSearch::Index::Indexer> object for updating named full text
index. Used internally for updating the appropriate full text index when a
distribution has been fully updated.

=head2 Instance Accessors

=head3 C<verbose>

  my $verbose = $indexer->verbose;
  $indexer->verbose($verbose);

Get or set an incremental verbosity. The higher the integer specified, the
more verbose the indexing.

=head3 C<to_index>

  push @{ $indexer->to_index->{ $index } } => $data;

Stores a hash reference of array references of data to be added to full text
indexes. As a distribution is merged and updated, data for adding to the full
text index is added to this hash. Once the updating and merging has completed
successfully, the data is read from this attribute and written to the
appropriate full text indexes.

=head3 C<libxml>

  my $libxml = $indexer->libxml;

Returns the L<XML::LibXML> object used for parsing and cleaning HTML documents.

=head3 C<index_dir>

  my $index_dir = $indexer->index_dir;

Returns the path to the parent directory of all of the full-text indexes.

=head3 C<schemas>

  my $schema = $indexer->schemas->{$index_name};

Returns a hash reference of L<KinoSearch::Plan::Schema> objects used to define
the structure of the full text indexes. The keys identify the indexes and the
values are the corresponding L<KinoSearch::Plan::Schema> objects. The supported
indexes are:

=over

=item doc

=item dist

=item extension

=item tag

=item user

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
