use strict;
use warnings;
use Module::Build::DB;

my $class = Module::Build::DB->subclass(
    class => 'PGXN::Build',
    code => q{
        sub valid_licenses { { postgresql => 'PostgreSQL' } }
    },
);

$class->new(
    module_name        => 'PGXN::API',
    license            => 'postgresql',
    # script_files       => 'bin',
    test_file_exts     => [qw(.t .pg)],
    db_config_key      => 'dbi',
    replace_config     => 'conf/test.json',
    db_client          => 'psql',
    configure_requires => { 'Module::Build::DB' => '0.10', },
    build_requires     => {
        'Module::Build' => '0.30',
        'Test::File'    => '1.29',
        'Test::More'    => '0.70',
    },
    requires => {
        'DBD::Pg'                      => '2.15.1',
        'DBI'                          => '1.608',
        'DBIx::Connector'              => '0.42',
        'Exception::Class::DBI'        => '1.00',
        'File::Spec'                   => '3.33',
        'JSON::XS'                     => '2.3',
        'Moose'                        => '1.15',
        'MooseX::Singleton'            => '0.25',
        'namespace::autoclean'         => '0.11',
        'perl'                         => 5.012,
        'URI::Template'                => '0.15',
    },
    recommends => {
        'Test::Pod'           => '1.20',
        'Test::Pod::Coverage' => '1.06',
    },
    tap_harness_args => {
        sources => {
            Perl  => undef,
            pgTAP => {
                dbname   => 'pgxn_api_test',
                username => 'postgres',
                suffix   => '.pg',
            },
        },
    },
    meta_merge => {
        resources => {
            homepage   => 'http://api.pgxn.org/',
            bugtracker => 'http://github.com/theory/pgxn-api/issues/',
            repository => 'http://github.com/theory/pgxn-api/tree/',
        },
    },
)->create_build_script;
