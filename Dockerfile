FROM ubuntu:latest

MAINTAINER Dave Fletcher

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update; \
  dpkg-divert --local --rename --add /sbin/initctl; \
  ln -sf /bin/true /sbin/initctl; \
  apt-get -y install git curl wget locales iproute2 \
  mysql-client apache2 pwgen unison netcat net-tools \
  nano unzip libapache2-mod-php php php-cli php-common \
  php-gd php-json php-mbstring php-xdebug php-mysql php-opcache php-curl \
  php-readline php-xml php-memcached php-oauth php-bcmath php-zip \
  php-uploadprogress jq; \
  apt-get clean; \
  apt-get autoclean; \
  apt-get -y autoremove; \
  rm -rf /var/lib/apt/lists/*

RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd; \
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config; \
  locale-gen en_US.UTF-8; \
  mkdir -p /var/lock/apache2 /var/run/apache2 /var/run/sshd

# Install Composer, drush and drupal console
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
  && HOME=/ /usr/local/bin/composer global require drush/drush:~9 \
  && ln -s /.composer/vendor/drush/drush/drush /usr/local/bin/drush \
  && curl https://drupalconsole.com/installer -L -o /usr/local/bin/drupal \
  && chmod +x /usr/local/bin/drupal \
  && php --version; composer --version; drupal --version; drush --version

# Installed files
COPY files/bin/foreground.sh /etc/apache2/foreground.sh
COPY files/xdebug.ini /etc/php/7.2/mods-available/xdebug.ini
COPY files/bin/drupaldb /usr/local/bin/drupaldb
COPY files/bin/drupaldbdump /usr/local/bin/drupaldbdump
RUN chmod +x /usr/local/bin/drupaldb; \
    chmod +x /usr/local/bin/drupaldbdump

# Apache & Xdebug
RUN rm /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-enabled/*
ADD files/000-default.conf /etc/apache2/sites-available/000-default.conf
ADD files/xdebug.ini /etc/php/7.2/mods-available/xdebug.ini
RUN a2ensite 000-default ; a2enmod rewrite vhost_alias

# Set some permissions
RUN chmod 755 /etc/apache2/foreground.sh; \
    mkdir /workspace

# Composer install latest Drupal version.
RUN rm -rf /var/www/html/*
RUN composer create-project drupal/recommended-project /var/www/html --no-interaction

# Make sure we don't have any Apache PID in the image else
# it crashes with segfault.
RUN service apache2 stop
RUN update-rc.d -f apache2 remove
RUN rm -f /var/run/apache2/apache2.pid

WORKDIR /workspace
EXPOSE 22 80 3306 9000

CMD /bin/bash /etc/apache2/foreground.sh
