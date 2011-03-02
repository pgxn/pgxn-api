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
    script_files       => 'bin',
    configure_requires => { 'Module::Build' => '0.30', },
    build_requires     => {
        'Module::Build'        => '0.30',
        'Test::Exception'      => '0.31',
        'Test::File'           => '1.29',
        'Test::File::Contents' => '0.20',
        'Test::MockModule'     => '0.05',
        'Test::More'           => '0.70',
        'Test::Output'         => '0.16',
    },
    requires => {
        'Archive::Zip'                 => '1.30',
        'Cwd'                          => '3.33',
        'Digest::SHA1'                 => '2.13',
        'File::Path'                   => '2.08',
        'File::Copy::Recursive'        => '0.38',
        'File::Spec'                   => '3.33',
        'JSON'                         => '2.27',
        'JSON::XS'                     => '2.3',
        'List::Util'                   => '1.23',
        'Moose'                        => '1.15',
        'Moose::Util::TypeConstraints' => '1.15',
        'MooseX::Singleton'            => '0.25',
        'namespace::autoclean'         => '0.11',
        'perl'                         => 5.012,
        'Plack'                        => '0.9956',
        'Plack::Builder'               => 0,
        'Plack::App::Directory'        => 0,
        'URI::Template'                => '0.15',
    },
    recommends => {
        'Test::Pod'           => '1.41',
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
