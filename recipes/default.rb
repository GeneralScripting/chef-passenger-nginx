#
# Cookbook Name:: passenger-nginx
# Recipe:: default
#
# Copyright (C) 2014 Ballistiq Digital, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.


execute "apt-get update" do
  command "apt-get update"
  user "root"
end

# Install basic packages
%w(git build-essential curl libcurl4-openssl-dev libpcre3 libpcre3-dev).each do |pkg|
  apt_package pkg
end

# Check for if we are installing Passenger Enterprise
passenger_enterprise = !!node['passenger-nginx']['passenger']['enterprise_download_token']

if passenger_enterprise
  bash "Installing Passenger Enterprise Edition" do
    code <<-EOF
    gem install --source https://download:#{node['passenger-nginx']['passenger']['enterprise_download_token']}@www.phusionpassenger.com/enterprise_gems/ passenger-enterprise-server -v #{node['passenger-nginx']['passenger']['version']}
    EOF
    user "root"

    regex = Regexp.escape("passenger-enterprise-server (#{node['passenger-nginx']['passenger']['version']})")
    not_if { `bash -c "gem list"`.lines.grep(/^#{regex}/).count > 0 }
  end
else
  # Install Passenger open source
  bash "Installing Passenger Open Source Edition" do
    code <<-EOF
    gem install passenger -v #{node['passenger-nginx']['passenger']['version']}
    EOF
    user "root"

    regex = Regexp.escape("passenger (#{node['passenger-nginx']['passenger']['version']})")
    not_if { `bash -c "gem list"`.lines.grep(/^#{regex}/).count > 0 }
  end
end

bash "Installing passenger nginx module and nginx from source" do
  code <<-EOF
  passenger-install-nginx-module --auto --prefix=/opt/nginx --auto-download --extra-configure-flags="\"--with-http_gzip_static_module #{node['passenger-nginx']['nginx']['extra_configure_flags']}\""
  EOF
  user "root"
  not_if { File.exists? "/opt/nginx/sbin/nginx" }
end

passenger_root = nil

ruby_block "store passenger root" do
  block do
    Chef::Resource::RubyBlock.send(:include, Chef::Mixin::ShellOut)
    command = 'passenger-config --root'
    command_out = shell_out(command)
    node.default['passenger-nginx']['passenger-root'] = passenger_root = command_out.stdout
    node.set['passenger-nginx']['passenger-root'] = passenger_root
    node.save
  end
  action :create
end

template "/opt/nginx/conf/nginx.conf" do
  source "nginx.conf.erb"
  variables({
    :ruby_version => node['passenger-nginx']['ruby_version'],
    :rvm => node['rvm'],
    :passenger_root => node['passenger-nginx']['passenger-root'],
    :passenger_ruby => node[:languages][:ruby][:ruby_bin],
    :passenger => node['passenger-nginx']['passenger'],
    :nginx => node['passenger-nginx']['nginx']
  })
end

# Install the nginx control script
cookbook_file "/etc/init.d/nginx" do
  source "nginx.initd"
  action :create
  mode 0755
end

# Add log rotation
cookbook_file "/etc/logrotate.d/nginx" do
  source "nginx.logrotate"
  action :create
end

directory "/opt/nginx/conf/sites-enabled" do
  mode 0755
  action :create
end

directory "/opt/nginx/conf/sites-available" do
  mode 0755
  action :create
end

directory "/var/www" do
  mode 0755
  user node['passenger-nginx']['deploy_user']
  group 'www-data'
end

#directory "/var/www/.ssh" do
#  mode 0700
#  user node['passenger-nginx']['nginx']['user']
#  group 'root'
#end

#key_user = data_bag_item('ssh_keys', 'www-data')
#if key_user
#  key_user["keys"].each do |ssh_key|
#    ssh_authorize_key ssh_key["name"] do
#      key ssh_key['key']
#      user 'www-data'
#    end
#  end
#end

# Set up service to run by default
service 'nginx' do
  supports :status => true, :restart => true, :reload => true
  action [ :enable ]
end

# Add any applications that we need
node['passenger-nginx']['apps'].each do |app|

  template "/opt/nginx/conf/sites-available/#{app[:name]}" do
    mode 0744
    action :create

    # Create the conf
    if app[:config_source]
      source app[:config_source]
    else
      source "nginx_app.conf.erb"
    end

    # If we are completely overriding the cookbook, use this:
    if app[:config_cookbook]
      cookbook app[:config_cookbook]
    end

    # Read custom config
    custom_config = if app['custom_config'] && app['custom_config'].kind_of?(Array)
      app['custom_config'].join "\n"
    else
      app['custom_config']
    end

    variables(
      listen: app['listen'] || 80,
      listen_redirect: app['listen_redirect'] || 80,
      server_name: app['server_name'] || nil,
      root: app['root'] || "/opt/nginx/html",
      ssl_certificate: app['ssl_certificate'] || nil,
      ssl_certificate_key: app['ssl_certificate_key'] || nil,
      redirect_http_https: app['redirect_http_https'] || false,
      ruby_version: node['passenger-nginx']['ruby_version'] || nil,
      ruby_gemset: app['ruby_gemset'] || nil,
      app_env: app['app_env'] || nil,
      passenger_min_instances: app['passenger_min_instances'] || nil,
      passenger_max_instances: app['passenger_max_instances'] || nil,
      passenger_concurrency_model: app['passenger_concurrency_model'] || nil,
      passenger_thread_count: app['passenger_thread_count'] || nil,
      access_log: app['access_log'] || nil,
      error_log: app['error_log'] || nil,
      custom_config: custom_config || nil,
      client_max_body_size: app['client_max_body_size'] || nil,
      client_body_buffer_size: app['client_body_buffer_size'] || nil
    )

    notifies :restart, resources(:service => "nginx"), :delayed

    only_if { File.directory? app['root'] }
  end

  # Symlink the conf
  link "/opt/nginx/conf/sites-enabled/#{app[:name]}" do
    to "/opt/nginx/conf/sites-available/#{app[:name]}"
  end

  # Create the ruby gemset
  #if node['passenger-nginx']['ruby_version'] && app['ruby_gemset']
  #  bash "Create Ruby Gemset" do
  #    code <<-EOF
  #    source #{node['passenger-nginx']['rvm']['rvm_shell']}
  #    rvm ruby-#{node['passenger-nginx']['ruby_version']} do rvm gemset create #{app['ruby_gemset']}
  #    EOF
  #    user "root"
  #    not_if { File.directory? "/usr/local/rvm/gems/ruby-#{node['passenger-nginx']['ruby_version']}@#{app['ruby_gemset']}" }
  #  end
  #end
end

service "nginx" do
  action :start
  not_if { File.exists? "/opt/nginx/logs/nginx.pid" }
end
