#!/bin/bash

. /workspace/ENV

ENVIRONMENT="dev"
BASEHTML="/var/www/html"
DOCROOT="/var/www/html/web"
DRUSH="/.composer/vendor/drush/drush/drush -y"
GRPID=$(stat -c "%g" /var/lib/mysql/)
LOCAL_IP=$(hostname -I| awk '{print $1}')
HOSTIP=$(/sbin/ip route | awk '/default/ { print $3 }')

DEV_MODULES_ENABLED=("${DEV_MODULES_ENABLED[*]}" $(ls /workspace/modules))
DEV_MODULES_ENABLED=("${DEV_MODULES_ENABLED[*]}" $(ls /workspace/.base/modules))
DEV_MODULES_ENABLED=("${DEV_MODULES_ENABLED[*]}" $(ls /workspace/features))
DEV_MODULES_ENABLED=("${DEV_MODULES_ENABLED[*]}" $(ls /workspace/.base/features))
DEV_THEMES_ENABLED=("${DEV_THEMES_ENABLED[*]}" $(ls /workspace/themes))
DEV_THEMES_ENABLED=("${DEV_THEMES_ENABLED[*]}" $(ls /workspace/.base/themes))

function logrun(){
  LABEL=$1; shift
  LOGFILE=$1; shift
  COMMAND=$1; shift
  declare -a ARGS=(${@@Q})
  echo ${COMMAND} ${ARGS[*]} >> "/tmp/${LOGFILE}"
  echo | tee "/tmp/${LOGFILE}"
  echo "++++ ${LABEL}" | tee "/tmp/${LOGFILE}"
  echo "     Started $(date)" | tee "/tmp/${LOGFILE}"
  eval ${COMMAND} ${ARGS[*]} >> "/tmp/${LOGFILE}" 2>&1
  if [[ $? -ne 0 ]]; then
    echo "    Error running command. Output follows:"
    cat "/tmp/${LOGFILE}"
    echo
    exit -1
  fi
  echo "     Completed $(date)"
}

echo
echo "----------------------------------------------------------------------------------"
echo "       ${SITE_NAME} installation started"
echo "       $(date)"
echo "----------------------------------------------------------------------------------"

# Setup hosts file.
echo "${HOSTIP} dockerhost" >> /etc/hosts

# Start supervisord
supervisord -c /etc/supervisor/conf.d/supervisord.conf -l /tmp/supervisord.log

# Composer and Drush commands run from here.
cd ${BASEHTML}

# Run composer create-project
if ! logrun "Running \`composer create-project\`. This takes a while." \
     "composer-create-project.log" \
     composer create-project --no-interaction; then
  exit $?
fi

# Fetch adminer.
if ! logrun "Fetch adminer." \
     "wget-fetch-adminer.log" \
      wget "http://www.adminer.org/latest.php" -O ${DOCROOT}/adminer.php; then
    exit $?
fi

chmod a+w ${DOCROOT}/sites/default;
chown -R www-data:${GRPID} ${DOCROOT}
chmod -R ug+w ${DOCROOT}

# Generate random passwords
DRUPAL_DB="drupal"
DEBPASS=$(grep password /etc/mysql/debian.cnf |head -n1|awk '{print $3}')
ROOT_PASSWORD=`pwgen -c -n -1 12`
MYSQL_PASSWORD=`pwgen -c -n -1 12`
echo ${ROOT_PASSWORD} > /var/lib/mysql/mysql/mysql-root-pw.txt
echo ${MYSQL_PASSWORD} > /var/lib/mysql/mysql/drupal-db-pw.txt

# Wait for mysql
if ! mysqladmin status >/dev/null 2>&1; then
  echo -n "Waiting for mysql ." ; sleep 1;
  while ! mysqladmin status >/dev/null 2>&1; do
    echo -n .
    sleep 1
  done
  echo
fi

# Create and change MySQL creds
mysqladmin -u root password ${ROOT_PASSWORD} 2>/dev/null
mysql -uroot -p${ROOT_PASSWORD} -e \
      "GRANT ALL PRIVILEGES ON *.* TO 'debian-sys-maint'@'localhost' IDENTIFIED BY '$DEBPASS';" 2>/dev/null
mysql -uroot -p${ROOT_PASSWORD} -e \
      "CREATE DATABASE drupal; GRANT ALL PRIVILEGES ON drupal.* TO 'drupal'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'; FLUSH PRIVILEGES;" 2>/dev/null
cd ${DOCROOT}
cp sites/default/default.settings.php sites/default/settings.php

# Drush crashes w segfault if xdebug is on. Disable for cli.
rm -f /etc/php/7.2/cli/conf.d/20-xdebug.ini

# Site install.
if ! logrun "Running \`drush site-install\`." \
     "drush-site-install.log" \
      ${DRUSH} site-install standard \
        --account-name="${DEV_DRUPAL_ADMIN_USER}" \
        --account-pass="${DEV_DRUPAL_ADMIN_PASSWORD}" \
        --db-url="mysql://drupal:${MYSQL_PASSWORD}@localhost:3306/drupal" \
        --site-name="${SITE_NAME}"; then
    exit $?
fi

# Change root password
echo "root:${ROOT_PASSWORD}" | chpasswd

# Enabled themes
if [[ ! -z "${DEV_THEMES_ENABLED[*]}" ]]; then
  for theme in ${DEV_THEMES_ENABLED[*]}; do
    if ! logrun "Enable theme: ${theme}." \
      "drush-theme-enable.log" ${DRUSH} theme-enable ${theme}; then
      exit $?
    fi
  done
fi

# Set the site theme
if [[ ! -z ${DEV_PUBLIC_THEME} ]]; then
  if ! logrun "Set primary site theme: ${DEV_PUBLIC_THEME[*]}." \
    "drush-config-set-system-theme-default.log" \
    ${DRUSH} config-set system.theme default "${DEV_PUBLIC_THEME}"; then
    exit $?
  fi
fi

# Set the admin theme
if [[ ! -z ${DEV_ADMIN_THEME} ]]; then
  if ! logrun "Set administration theme: ${DEV_ADMIN_THEME[*]}." \
    "drush-config-set-system-theme-admin.log" \
    ${DRUSH} config-set system.theme admin "${DEV_ADMIN_THEME}"; then
    exit $?
  fi
fi

# Disabled themes
if [[ ! -z "${DEV_THEMES_DISABLED[*]}" ]]; then
  for theme in ${DEV_THEMES_DISABLED[*]}; do
    if ! logrun "Disable theme: ${theme}." \
      "drush-theme-uninstall.log" ${DRUSH} theme-uninstall ${theme}; then
      exit $?
    fi
  done
fi

# Enabled modules
if [[ ! -z "${DEV_MODULES_ENABLED[*]}" ]]; then
  if ! logrun "Enable modules: ${DEV_MODULES_ENABLED[*]}." \
    "drush-pm-enable.log" ${DRUSH} pm-enable ${DEV_MODULES_ENABLED[*]}; then
    exit $?
  fi
fi

# Disabled modules
if [[ ! -z "${DEV_MODULES_DISABLED[*]}" ]]; then
  if ! logrun "Disable modules: ${DEV_MODULES_DISABLED[*]}." \
    "drush-pm-uninstall.log" ${DRUSH} pm-uninstall ${DEV_MODULES_DISABLED[*]}; then
    exit $?
  fi
fi

# Import features configuration.
if ! logrun "Applying Features configuration." \
  "drush-features-import-all.log" \
  ${DRUSH} features-import-all; then
  exit $?
fi

# Reset files perms
chown -R www-data:${GRPID} ${DOCROOT}/sites/default/
chmod -R ug+w ${DOCROOT}/sites/default/
chown -R mysql:${GRPID} /var/lib/mysql/
chmod -R ug+w /var/lib/mysql/

# User post installation script.
[[ -f "/workspace/postinstall.sh" ]] && . /workspace/postinstall.sh "${ENVIRONMENT}"

# Wait a few then rebuild cache
sleep 3
if ! logrun "Cache rebuild." \
  "drush-pm-config-set-system-theme-admin.log" \
  ${DRUSH} --root=${DOCROOT} cache-rebuild; then
  exit $?
fi

# Credentials report
echo
echo "----------------------------------------------------------------------------------"
echo
echo "  ${SITE_NAME} installation complete $(date)"
echo
echo "  DRUPAL:  http://localhost               with user/pass: ${DEV_DRUPAL_ADMIN_USER}/${DEV_DRUPAL_ADMIN_PASSWORD}"
echo
echo "  MYSQL :  http://localhost/adminer.php   database: drupal"
echo "                                          user:     drupal/${MYSQL_PASSWORD}"
echo
echo "  SSH   :  ssh root@localhost             user:     root/${ROOT_PASSWORD}"
echo
echo "  Please report any issues to https://github.com/dfletcher/drupal-devcontainer"
echo
echo "----------------------------------------------------------------------------------"
echo
