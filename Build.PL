use strict;
use warnings;
use Module::Build;

my $class = Module::Build->subclass(
    class => 'PGXN::Build',
    code => q{
        sub valid_licenses { { postgresql => 'PostgreSQL' } }
    },
);

$class->new(
    module_name        => 'PGXN::API',
    license            => 'postgresql',
    # script_files       => 'bin',
    # test_file_exts     => [qw(.t .pg)],
    # db_config_key      => 'dbi',
    # replace_config     => 'conf/test.json',
    # db_client          => 'psql',
    configure_requires => { 'Module::Build' => '0.30', },
    build_requires     => {
        'Module::Build' => '0.30',
        'Test::More'    => '0.70',
    },
    requires => {
        'perl'          => 5.012,
    },
    recommends => {
        'Test::Pod'           => '1.20',
        'Test::Pod::Coverage' => '1.06',
    },
    meta_merge => {
        resources => {
            homepage   => 'http://api.pgxn.org/',
            bugtracker => 'http://github.com/theory/pgxn-api/issues/',
            repository => 'http://github.com/theory/pgxn-api/tree/',
        },
    },
)->create_build_script;
