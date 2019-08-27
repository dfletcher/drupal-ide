FROM ubuntu:bionic
MAINTAINER Ricardo Amaro <mail_at_ricardoamaro.com>
ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update; \
  dpkg-divert --local --rename --add /sbin/initctl; \
  ln -sf /bin/true /sbin/initctl; \
  apt-get -y install git curl wget supervisor openssh-server locales \
  mysql-client mysql-server apache2 pwgen vim-tiny mc iproute2 python-setuptools \
  unison netcat net-tools memcached nano libapache2-mod-php php php-cli php-common \
  php-gd php-json php-mbstring php-xdebug php-mysql php-opcache php-curl \
  php-readline php-xml php-memcached php-oauth php-bcmath \
  php-uploadprogress jq; \
  apt-get clean; \
  apt-get autoclean; \
  apt-get -y autoremove; \
  rm -rf /var/lib/apt/lists/*

RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd; \
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config; \
  locale-gen en_US.UTF-8; \
  mkdir -p /var/lock/apache2 /var/run/apache2 /var/run/sshd /var/log/supervisor

ENV NOTVISIBLE "in users profile"
RUN echo "export VISIBLE=now" >> /etc/profile; \
  rm -rf /var/lib/mysql/*; /usr/sbin/mysqld --initialize-insecure; \
  sed -i 's/^bind-address/#bind-address/g' /etc/mysql/mysql.conf.d/mysqld.cnf; \
  sed -i "s/^bind-address/#bind-address/" /etc/mysql/my.cnf

# Install Composer, drush and drupal console
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
  && HOME=/ /usr/local/bin/composer global require drush/drush:~8 \
  && ln -s /.composer/vendor/drush/drush/drush /usr/local/bin/drush \
  && curl https://drupalconsole.com/installer -L -o /usr/local/bin/drupal \
  && chmod +x /usr/local/bin/drupal \
  && php --version; composer --version; drupal --version; drush --version

# Install supervisor
COPY ./.devcontainer/files/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY ./.devcontainer/files/foreground.sh /etc/apache2/foreground.sh
COPY ./.devcontainer/files/scripts/composer/ScriptHandler.php /var/www/html/scripts/composer/ScriptHandler.php
COPY ./.devcontainer/files/load.environment.php /var/www/html/load.environment.php
COPY ./.devcontainer/files/xdebug.ini /etc/php/7.2/mods-available/xdebug.ini
COPY ./.devcontainer/files/composer-drupal-core.json /var/www/html/composer-drupal-core.json

# Copy startup script
COPY ./.devcontainer/files/start.sh /start.sh

# Copy scripts
COPY ./.devcontainer/files/bin/drupaldb /usr/local/bin/drupaldb
COPY ./.devcontainer/files/bin/drupaldbdump /usr/local/bin/drupaldbdump
COPY ./.devcontainer/files/bin/startsupervisor.sh /usr/local/bin/startsupervisor.sh

RUN chmod +x /usr/local/bin/drupaldb; \
    chmod +x /usr/local/bin/drupaldbdump; \
    chmod +x /usr/local/bin/startsupervisor.sh

# Apache & Xdebug
RUN rm /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-enabled/*
ADD ./.devcontainer/files/000-default.conf /etc/apache2/sites-available/000-default.conf
ADD ./.devcontainer/files/xdebug.ini /etc/php/7.2/mods-available/xdebug.ini
RUN a2ensite 000-default ; a2enmod rewrite vhost_alias

# Drupal new version, clean cache
ADD https://updates.drupal.org/release-history/drupal/8.x /tmp/latest.xml

# Set some permissions
RUN mkdir -p /var/run/mysqld; \
    chown mysql:mysql /var/run/mysqld; \
    chmod 755 /etc/apache2/foreground.sh; \
    mkdir /workspace; \
    ln -s /var/www/html /workspace/html

# Make sure we don't have any Apache PID in the image else
# it crashes with segfault.
RUN rm -f /var/run/apache2/apache2.pid

WORKDIR /workspace
EXPOSE 22 80 3306 9000

CMD ["/bin/bash", "/usr/local/bin/startsupervisor.sh"]
