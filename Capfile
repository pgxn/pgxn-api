# Steps to doing an initial deployment:
#
# Create system user "pgxn"
# cap deploy:setup
# cap deploy:cold -s branch=$tag
# cap deploy -s branch=$tag
#
# -s options:
# * user      - Deployment user; default: "pgxn"
# * pgxn_user - User to run the app; default: "pgxn_api"

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
set :run_from,    "/var/virtuals/pgxn/#{application}.#{domain}"
set :mirror_root, "/var/virtuals/pgxn/master.#{domain}"
set :user,        "pgxn"
set :pgxn_user,   "pgxn_api"
set :host,        "depesz.com"

# Define the shared directories we need.
set :shared_children, %w(log pids www)

role :app, host

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
      ln -fsn #{shared_path}/www || exit $?;
      ln -fsn #{shared_path}/log || exit $?;
      ln -fsn #{shared_path}/pids || exit $?;
    CMD
  end

  task :start_script do
    top.upload 'eg/debian_init', '/tmp/pgxn-api', :mode => 0755
    run 'sudo mv /tmp/pgxn-api /etc/init.d/ && sudo /usr/sbin/update-rc.d pgxn-api defaults'
    top.upload 'eg/sync_pgxn', '/tmp/sync_pgxn', :mode => 0755
    run 'sudo mv /tmp/sync_pgxn /etc/cron.hourly/'
  end

  task :symlink_production do
    run "ln -fsn #{ latest_release } #{ run_from }"
  end

  task :migrate do
    # Do nothing.
  end

  task :start do
#    run 'sudo /etc/init.d/pgxn-api start'
    run "cd #{ run_from } && blib/script/pgxn_api_server -s Starman -E prod --workers 5 --preload-app --max-requests 100 --listen 127.0.0.1:7497 --daemonize --pid pids/pgxn_api.pid --error-log log/pgxn_api.log --errors-to pgxn-admins@googlegroups.com --errors-from pgxn@pgexperts.com", :hosts => "#{ pgxn_user }@#{ host }"
  end

  task :restart do
#    run 'sudo /etc/init.d/pgxn-api restart'
    stop
    start
  end

  task :stop do
#    run 'sudo /etc/init.d/pgxn-api stop'
    run <<-CMD, :hosts => "#{ pgxn_user }@#{ host }"
        if [ -f "#{ run_from }/pids/pgxn_api.pid" ]; then
            kill `cat "#{ run_from }/pids/pgxn_api.pid"`;
        fi
    CMD
  end

  task :sync do
    run "cd #{ run_from } && blib/script/pgxn_api_sync '#{ mirror_root }'"
  end

end

before 'deploy:start',   'deploy:sync'
before 'deploy:update',  'deploy:check_branch'
#after  'deploy:update',  'deploy:start_script'
after  'deploy:symlink', 'deploy:symlink_production'
