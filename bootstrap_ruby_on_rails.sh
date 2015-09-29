#!/bin/bash --login
# login argument is needed for rvm function if used for root
# set -x or set -v is for debugging this script
set -x
# run with: vagrant provision | tee log/vagrant

update-locale LANG=en_US.UTF-8 LANGUAGE=en_US.UTF-8 LC_ALL=en_US.UTF-8 # needed for docs generation and database default

echo "STEP: update"
apt-get -y update > /dev/null # this is needed to set proper apt sources

if [ "`id -u deployer`" = "" ];then
  echo "STEP: creating user deployer"
  useradd deployer -md /home/deployer --shell /bin/bash # adding user without password
  gpasswd -a deployer sudo # add to sudo group
  echo "deployer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deployer # don't ask for password when using sudo
  if [ ! "`id -u vagrant`" = "" ]; then
    usermod -a -G vagrant deployer # adding to vagrant group
  fi
else
  echo "STEP: user deployer already exists"
fi

# check if rvm is installed
if [ "`sudo -i -u deployer type -t rvm`" != "function" ]; then
#if [ ! -f /usr/local/rvm/scripts/rvm ]; then
  echo "STEP: installing rvm"
  sudo -i -u deployer gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3
  sudo -i -u deployer /bin/bash -c 'curl -sSL https://get.rvm.io | bash' # --rails' user this option for latest rails
  #sudo -i -u deployer echo -e "\n. ~/.rvm/scripts/rvm # source rvm on boot" >> ~/.bashrc
else
  echo "STEP: rvm already installed"
fi

if [ "`which git`" = "" ]; then
  echo "STEP: install development tools"
  apt-get -y install build-essential curl git nodejs
else
  echo "STEP: development tools already installed"
fi

if [ "`which psql`" = "" ]; then
  echo "STEP: installing postgres"
  apt-get -y install postgresql postgresql-contrib libpq-dev
else
  echo STEP: postgres already installed
fi

# Digital ocean image starts from here

if [ ! -f /swapfile ];then
  echo STEP: creating swap
  fallocate -l 256M /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  # you can check with swapon -s
  # make it permanent
  echo '
/swapfile   none    swap    sw    0   0
' >> /etc/fstab
else
  echo "STEP: swap already exists"
fi

if [ ! "$EDITOR" = "vim" ]; then
  echo STEP: some utility config in bashrc
  # bashrc is for interactive shell (it returns at beggining for sudo bash commands)
  sudo -i -u deployer /bin/bash -c "echo -e '\n# Some utility\n\
cd /vagrant\n\
export EDITOR=vim\n\
' >> ~/.bashrc"
  # .profile is for all shells
  sudo -i -u deployer /bin/bash -c "echo -e '\n\
# we will use database user deployer without password\n\
export DATABASE_URL=postgresql://deployer@localhost\n\
# source my secrets (RAILS_ENV, AWS KEYS... overwrite of DATABASE_URL)\n\
. /vagrant/.secrets.env\n\
' >> ~/.profile"
fi

ruby_ver=$(awk '/^ruby/ { print $2 }' /vagrant/Gemfile | tr -d '"')
if [[ ! `ruby --version` == *$ruby_ver"p"* ]];then
  echo STEP: install target ruby $ruby_ver
  sudo -i -u deployer rvm install $ruby_ver
  sudo -i -u deployer rvm use $ruby_ver --default
else
  echo STEP: ruby $ruby_ver already installed
fi

echo STEP: install projects gems with bundle command
sudo -i -u deployer /bin/bash -c 'cd /vagrant && gem install bundler'
sudo -i -u deployer /bin/bash -c 'cd /vagrant && bundle'


# DATABASE STUFF
if [ "`sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='deployer'"`" = "1" ]; then
  echo STEP: database user 'deployer' already exists
else
  echo STEP: create database user deployer
  find /etc/postgresql -name pg_hba.conf -exec sed -i '/^local\s*all\s*all\s*peer/i # allow deployer to access without password - trust method\
host all deployer 127.0.0.1/32 trust' {} \;
  # change md5 with trust, don't use this if you set up password for database user
  /etc/init.d/postgresql restart
  sudo -u postgres createuser --superuser --createdb deployer
fi
echo STEP: create database
sudo -i -u deployer /bin/bash -c 'cd /vagrant && rake db:create'
# extension can be created only on existing database
echo STEP: create postgresql hstore extension if not exists
database_name=`sudo -i -u deployer /bin/bash -c "cd /vagrant && rails runner 'puts ActiveRecord::Base.configurations[\"production\"][\"database\"]'"`
echo database_name is $database_name
sudo -u postgres psql $database_name -c 'CREATE EXTENSION IF NOT EXISTS hstore;'
echo STEP: seed
sudo -i -u deployer /bin/bash -c 'cd /vagrant && rake db:migrate'
sudo -i -u deployer /bin/bash -c 'cd /vagrant && rake db:seed'

echo STEP: precompile assets
sudo -i -u deployer /bin/bash -c 'cd /vagrant && rake assets:precompile'

echo STEP: start puma
mkdir /shared # use outside of /vagrant since it has some problems with permissions on virtualbox
chown deployer:deployer /shared
sudo -u deployer mkdir -p /shared/pids /shared/sockets /shared/log
cp /vagrant/config/puma.conf /vagrant/config/puma-manager.conf /etc/init
echo "/vagrant" > /etc/puma.conf
start puma-manager

#sudo -i -u deployer -c 'cd /vagrant && rails s'

echo STEP: install and configure nginx
apt-get install -y nginx
ln -s /vagrant/config/nginx /etc/nginx/sites-enabled/default -f
service nginx restart

# create password for deployer, as root
# passwd deployer
# add your public key for easier login
# ssh-copy-id deployer@121...
# disable root login
# /etc/ssh/sshd_config
# PermitRootLogin no
# service ssh restart
# https://www.digitalocean.com/community/tutorials/additional-recommended-steps-for-new-ubuntu-14-04-servers
# enable firewall for ssh and 80
# sudo ufw allow ssh
# sudo ufw allow 80/tcp
# sudo ufw allow 443/tcp
# sudo ufw show added
# sudo ufw enable

echo STEP: Done, go end visit the service at: http://`ifconfig eth0 | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}'`
