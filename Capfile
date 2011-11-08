# Steps to doing an initial deployment:
#
# Create system user "pgxn"
# cap deploy:setup
# cap deploy:cold -s branch=$tag
# cap deploy -s branch=$tag

load 'deploy'

default_run_options[:pty] = true  # Must be set for the password prompt from git to work

set :application, "api"
set :domain,      "pgxn.org"
set :repository,  "https://github.com/pgxn/pgxn-api.git"
set :scm,         :git
set :deploy_via,  :remote_cache
set :use_sudo,    false
set :branch,      "master"
set :deploy_to,   "~/pgxn-api"
set :run_from,    "/var/www/#{application}.#{domain}"

# We just have one shared directory.
set :shared_children, %(www)

role :app, 'xanthan.postgresql.org'

namespace :deploy do
  desc 'Confirm attempts to deploy master'
  task :check_branch do
    if self[:branch] == 'master'
      unless Capistrano::CLI.ui.agree("\n    Are you sure you want to deploy master? ")
        puts "\n", 'Specify a branch via "-s branch=vX.X.X"', "\n"
        exit
      end
    end
  end

  task :finalize_update, :except => { :no_release => true } do
    # Build it!
    run <<-CMD
      cd #{ latest_release };
      perl Build.PL || exit $?;
      ./Build installdeps || exit $?;
      ./Build || exit $?;
      ln -s #{shared_path}/www #{latest_release}/www;
    CMD
  end

  task :start_script do
    top.upload 'eg/debian_init', '/tmp/pgxn-api', :mode => 0755
    run 'sudo mv /tmp/pgxn-api /etc/init.d/ && sudo /usr/sbin/update-rc.d pgxn-api defaults'
    top.upload 'eg/sync_pgxn', '/tmp/sync_pgxn', :mode => 0755
    run 'sudo mv /tmp/sync_pgxn /etc/cron.hourly/'
  end

  task :symlink_production do
    run "sudo ln -fs #{ latest_release } #{ run_from }"
  end

  task :migrate do
    # Do nothing.
  end

  task :start do
    run 'sudo /etc/init.d/pgxn-api start'
  end

  task :restart do
    run 'sudo /etc/init.d/pgxn-api restart'
  end

  task :stop do
    run 'sudo /etc/init.d/pgxn-api stop'
  end

  task :sync do
    run 'sudo /etc/cron.hourly/sync_pgxn'
  end

end

before 'deploy:start',   'deploy:sync'
before 'deploy:update',  'deploy:check_branch'
after  'deploy:update',  'deploy:start_script'
after  'deploy:symlink', 'deploy:symlink_production'
