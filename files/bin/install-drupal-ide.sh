#!/bin/bash

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
    echo "     Error running command. Output in /tmp/${LOGFILE}."
    #cat "/tmp/${LOGFILE}"
    echo
    #exit -1
  fi
  echo "     Completed $(date)"
}

function mysqlrunning(){
  mysqladmin -h${MYSQL_HOST} -uroot status >/dev/null 2>&1 || \
    mysqladmin -h${MYSQL_HOST} -uroot "-p${MYSQL_ROOT_PASSWORD}" status >/dev/null 2>&1 || \
    mysqladmin -h${MYSQL_HOST} -udrupal "-p${MYSQL_PASSWORD}" status >/dev/null 2>&1
}

function message(){
  echo
  echo "----------------------------------------------------------------------------------"
  echo "     ${1}"
  echo "     $(date)"
  echo "----------------------------------------------------------------------------------"
}

# User config.
[[ -f "${WORKSPACE}/.env.drupal-ide" ]] && . "${WORKSPACE}/.env.drupal-ide"

DRUSH="${DRUSH_BIN} -y"
GRPID=$(stat -c "%g" /var/www/html/)
LOCAL_IP=$(hostname -I| awk '{print $1}')
HOSTIP=$(/sbin/ip route | awk '/default/ { print $3 }')

# Run from app directory.
cd ${APPDIR}

# Startup messaging.
cat ${WORKSPACE}/.devcontainer/files/bin/logo.txt
message "${SITE_NAME} installation started."

if [[ -z "${APPDIR}" ]]; then
  echo "Fatal: APPDIR is not set. Cannot continue."
  exit -1
fi

# Install Drupal into $APPDIR.
COMPOSER="${COMPOSER:-$(find ${WORKSPACE} -name composer.json | grep -v .devcontainer | sort | head -n1)}"
if [[ -z "${COMPOSER}" ]]; then
  # We do not have an existing composer.json. Use supplied.
  cp ${WORKSPACE}/.devcontainer/files/composer.json ${WORKSPACE}/
  rm composer.json
  COMPOSER="${WORKSPACE}/composer.json"
fi
[[ -f "${APPDIR}/composer.json" ]] || ln -s "${COMPOSER}" "${APPDIR}/composer.json"

if ! logrun "Running \`composer update\`. This takes a while." \
    "composer-update.log" \
    composer update --no-interaction; then
  exit $?
fi

# Paths that are based on location of core directory, these need
# to be set after the above composer installation has run.
COMPOSER_DIR=$(dirname "${COMPOSER}")
COREPATH=$(jq -Mr '.["extra"]["drupal-scaffold"]["locations"]["web-root"]' "${COMPOSER}" 2>/dev/null )
WORKSPACE_DRUPALBASE="${COMPOSER_DIR}/${COREPATH}"
WORKSPACE_MODULES="${WORKSPACE_MODULES:-${WORKSPACE_DRUPALBASE}/modules}"
WORKSPACE_THEMES="${WORKSPACE_THEMES:-${WORKSPACE_DRUPALBASE}/themes}"
WORKSPACE_PROFILES="${WORKSPACE_PROFILES:-${WORKSPACE_DRUPALBASE}/profiles}"
WORKSPACE_FEATURES="${WORKSPACE_FEATURES:-${WORKSPACE_DRUPALBASE}/features}"
APPDIR_DRUPALBASE="${APPDIR}/${COREPATH}"
APPDIR_ROOT="${APPDIR}/${COREPATH}"
APPDIR_MODULES="${APPDIR_ROOT}/modules/custom"
APPDIR_THEMES="${APPDIR_ROOT}/themes/custom"
APPDIR_PROFILES="${APPDIR_ROOT}/profiles/custom"
APPDIR_FEATURES="${APPDIR_ROOT}/modules/custom_features"

# Link workspace user directories into application dir.
[[ -d "${APPDIR_MODULES}" ]] || ln -s "${WORKSPACE_MODULES}" "${APPDIR_MODULES}"
[[ -d "${APPDIR_THEMES}" ]] || ln -s "${WORKSPACE_THEMES}" "${APPDIR_THEMES}"
[[ -d "${APPDIR_PROFILES}" ]] || ln -s "${WORKSPACE_PROFILES}" "${APPDIR_PROFILES}"
[[ -d "${APPDIR_FEATURES}" ]] || ln -s "${WORKSPACE_FEATURES}" "${APPDIR_FEATURES}"

# Permissions fixups.
chmod a+w ${APPDIR_DRUPALBASE}/sites/default;
chown -R www-data:${GRPID} ${APPDIR}
chmod -R ug+w ${APPDIR}

# Generate random passwords or read existing.
DRUPAL_DB="drupal"
MYSQL_PASSWORD_FILE="/etc/drupal-db-pw.txt"
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-"root"}

if [[ -f "${MYSQL_PASSWORD_FILE}" ]]; then
  MYSQL_PASSWORD="$(cat "${MYSQL_PASSWORD_FILE}")"
else
  MYSQL_PASSWORD="$(pwgen -c -n -1 12)"
  echo ${MYSQL_PASSWORD} > "${MYSQL_PASSWORD_FILE}"
fi

# Wait for mysql
if ! mysqlrunning; then
  echo
  echo -n "++++ Waiting for mysql ." ; sleep 1;
  while ! mysqlrunning; do
    echo -n .
    sleep 1
  done
  echo
fi

cd ${APPDIR}

# Drush crashes w segfault if xdebug is on. Disable for cli.
rm -f /etc/php/7.2/cli/conf.d/20-xdebug.ini

# Site install.
if ! logrun "Running \`drush site-install\`." \
     "drush-site-install.log" \
      ${DRUSH} site-install standard \
        --account-name="${DRUPAL_ADMIN_USER}" \
        --account-pass="${DRUPAL_ADMIN_PASSWORD}" \
        --db-url="mysql://root:${MYSQL_ROOT_PASSWORD}@${MYSQL_HOST}:3306/drupal" \
        --site-name="${SITE_NAME}"; then
    exit $?
fi

# Enabled themes
if [[ ! -z "${DRUPAL_THEMES_ENABLED[*]}" ]]; then
  for theme in ${DRUPAL_THEMES_ENABLED[*]}; do
    if ! logrun "Uninstall theme: ${theme}." \
      "drush-theme-enable.log" ${DRUSH} theme:uninstall ${theme}; then
      echo "Cannot uninstall theme ${theme}"
    fi
    if ! logrun "Enable theme: ${theme}." \
      "drush-theme-enable.log" ${DRUSH} theme:enable ${theme}; then
      echo "Cannot enable theme ${theme}"
    fi
  done
fi

# Set the site theme
if [[ ! -z ${DRUPAL_PUBLIC_THEME} ]]; then
  if ! logrun "Set primary site theme: ${DRUPAL_PUBLIC_THEME}." \
    "drush-config-set-system-theme-default.log" \
    ${DRUSH} config-set system.theme default "${DRUPAL_PUBLIC_THEME}"; then
    echo "Cannot set theme ${DRUPAL_PUBLIC_THEME}"
  fi
fi

# Set the admin theme
if [[ ! -z ${ADMIN_THEME} ]]; then
  if ! logrun "Set administration theme: ${ADMIN_THEME[*]}." \
    "drush-config-set-system-theme-admin.log" \
    ${DRUSH} config-set system.theme admin "${ADMIN_THEME}"; then
    echo "Cannot set admin theme ${ADMIN_THEME}"
  fi
fi

# Disabled themes
if [[ ! -z "${DRUPAL_THEMES_DISABLED[*]}" ]]; then
  for theme in ${DRUPAL_THEMES_DISABLED[*]}; do
    if ! logrun "Disable theme: ${theme}." \
      "drush-theme-uninstall.log" ${DRUSH} theme:uninstall ${theme}; then
      echo "Cannot disable theme ${theme}"
    fi
  done
fi

# Enabled modules
if [[ ! -z "${DRUPAL_MODULES_ENABLED[*]}" ]]; then
  for module in ${DRUPAL_MODULES_ENABLED[*]}; do
    if ! logrun "Enable module: ${module}." \
      "drush-pm-enable.log" ${DRUSH} pm-enable ${module}; then
      echo "Cannot enable module ${module}"
    fi
  done
fi

# Disabled modules
if [[ ! -z "${DRUPAL_MODULES_DISABLED[*]}" ]]; then
  for module in ${DRUPAL_MODULES_DISABLED[*]}; do
    if ! logrun "Disable module: ${module}." \
      "drush-pm-uninstall.log" ${DRUSH} pm-uninstall ${module}; then
      echo "Cannot uninstall module ${module}"
    fi
  done
fi

# Import features configuration.
if ${DRUSH} pm:list | grep features; then
  if ! logrun "Applying Features configuration." \
    "drush-features-import-all.log" \
    ${DRUSH} features-import-all; then
    echo "Cannot import features see /tmp/drush-features-import-all.log"
  fi
fi

# Reset files perms
chown -R www-data:${GRPID} ${APPDIR_DRUPALBASE}/sites/default/
chmod -R ug+w ${APPDIR_DRUPALBASE}/sites/default/

# Wait a few then rebuild cache
sleep 3
if ! logrun "Cache rebuild." \
  "drush-pm-config-set-system-theme-admin.log" \
  ${DRUSH} --root=${APPDIR} cache-rebuild; then
  exit $?
fi

# Credentials report
echo
echo "----------------------------------------------------------------------------------"
echo
echo "  ${SITE_NAME} installation complete $(date)"
echo
echo "  DRUPAL:  http://localhost with user/pass: ${DRUPAL_ADMIN_USER}/${DRUPAL_ADMIN_PASSWORD}"
echo
echo "  Please report any issues to https://github.com/dfletcher/drupal-ide"
echo
echo "----------------------------------------------------------------------------------"
echo
