#!/bin/bash

function setting(){
  defaultsettings="${SYSTEM_SETTINGS_JSON}"
  [[ -f ${USER_SETTINGS_JSON} ]] && defaultsettings="${USER_SETTINGS_JSON}"
  jq -Mr "${1}" "${2:-${defaultsettings}}"
}

function csetting(){
  setting "${1}" "${COMPOSER}"
}

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
  mysqladmin -h${DATABASE_HOST} -uroot status >/dev/null 2>&1 || \
    mysqladmin -h${DATABASE_HOST} -uroot "-p${MYSQL_ROOT_PASSWORD}" status >/dev/null 2>&1 || \
    mysqladmin -h${DATABASE_HOST} -udrupal "-p${MYSQL_PASSWORD}" status >/dev/null 2>&1
}

function message(){
  echo
  echo "----------------------------------------------------------------------------------"
  echo "     ${1}"
  echo "     $(date)"
  echo "----------------------------------------------------------------------------------"
}

ENVIRONMENT="${ENVIRONMENT:-dev}"
APPDIR="${APPDIR:-/var/www/html}"
DRUPAL_PROJECT=${DRUPAL_PROJECT:-"drupal/recommended-project"}
WORKSPACE="${WORKSPACE:-/workspace}"
SYSTEM_SETTINGS_JSON="${WORKSPACE}/.devcontainer/files/drupal-ide.default.json"
USER_SETTINGS_JSON="${USER_SETTINGS_JSON:-"${WORKSPACE}/.drupal-ide.json"}"
DRUSH="/.composer/vendor/drush/drush/drush -y"
GRPID=$(stat -c "%g" /var/lib/mysql/)
LOCAL_IP=$(hostname -I| awk '{print $1}')
HOSTIP=$(/sbin/ip route | awk '/default/ { print $3 }')

# Settings controlled by .drupal-ide.json
SITE_NAME="$(setting .sitename)"
DEV_DRUPAL_ADMIN_USER="$(setting .admin.user)"
DEV_DRUPAL_ADMIN_PASSWORD="$(setting .admin.password)"
declare -a DEV_MODULES_ENABLED=$(setting .modules.enable[])
declare -a DEV_MODULES_DISABLED=$(setting .modules.disable[])
declare -a DEV_THEMES_ENABLED=$(setting .themes.enable[])
declare -a DEV_THEMES_DISABLED=$(setting .themes.disable[])
DEV_PUBLIC_THEME="$(setting .themes.public)"
DEV_ADMIN_THEME="$(setting .themes.admin)"
DATABASE_HOST="${DATABASE_HOST:-"mysqldb"}"

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
  cp composer.json ${WORKSPACE}/
  rm composer.json
  COMPOSER="${WORKSPACE}/composer.json"
fi
[[ -f composer.json ]] || ln -s "${COMPOSER}" composer.json

if ! logrun "Running \`composer update\`. This takes a while." \
    "composer-update.log" \
    composer update --no-interaction; then
  exit $?
fi

# Paths that are based on location of core directory, these need
# to be set after the above composer installation has run.
COMPOSER_DIR=$(dirname "${COMPOSER}")
COREPATH=$(jq -Mr 'last(paths(.. == "type:drupal-core"))[2]' "${COMPOSER}" 2>/dev/null )
WORKSPACE_DRUPALCORE="${COMPOSER_DIR}/${COREPATH}"
WORKSPACE_DRUPALBASE=$(dirname "${WORKSPACE_DRUPALCORE}")
WORKSPACE_MODULES="${WORKSPACE_MODULES:-${WORKSPACE_DRUPALBASE}/modules}"
WORKSPACE_THEMES="${WORKSPACE_THEMES:-${WORKSPACE_DRUPALBASE}/themes}"
WORKSPACE_PROFILES="${WORKSPACE_PROFILES:-${WORKSPACE_DRUPALBASE}/profiles}"
WORKSPACE_FEATURES="${WORKSPACE_FEATURES:-${WORKSPACE_DRUPALBASE}/features}"
APPDIR_DRUPALCORE="${APPDIR}/${COREPATH}"
APPDIR_DRUPALBASE=$(dirname "${APPDIR_DRUPALCORE}")
APPDIR_ROOT="${APPDIR}/${COREPATH}"
APPDIR_MODULES="${APPDIR_ROOT}/modules/custom"
APPDIR_THEMES="${APPDIR_ROOT}/themes/custom"
APPDIR_PROFILES="${APPDIR_ROOT}/profiles/custom"
APPDIR_FEATURES="${APPDIR_ROOT}/modules/custom_features"
DEV_MODULES_ENABLED=("${DEV_MODULES_ENABLED[*]}" $(ls "${WORKSPACE_MODULES}"))
DEV_MODULES_ENABLED=("${DEV_MODULES_ENABLED[*]}" $(ls "${WORKSPACE_FEATURES}"))
HTDOCS="${APPDIR_DRUPALBASE}"

# Create supported user directories if they don't exist.
for x in "${WORKSPACE_MODULES}" "${WORKSPACE_THEMES}" "${WORKSPACE_PROFILES}" "${WORKSPACE_FEATURES}"; do
  if [[ ! -d "${x}" ]]; then
    mkdir -p "${x}"
    touch "${x}/.gitignore"
  fi
done

# Link workspace user directories into application dir.
[[ -d "${APPDIR_MODULES}" ]] || ln -s "${WORKSPACE_MODULES}" "${APPDIR_MODULES}"
[[ -d "${APPDIR_THEMES}" ]] || ln -s "${WORKSPACE_THEMES}" "${APPDIR_THEMES}"
[[ -d "${APPDIR_PROFILES}" ]] || ln -s "${WORKSPACE_PROFILES}" "${APPDIR_PROFILES}"
[[ -d "${APPDIR_FEATURES}" ]] || ln -s "${WORKSPACE_FEATURES}" "${APPDIR_FEATURES}"

# Settings file can declare additional packages.
# If necessary, add them to composer.json.
for m in $(setting .install[]); do
  if [[ $(csetting .require[\"${m}\"]) = "null" ]]; then
    if ! logrun "Require ${m}." \
        "composer-require-includes.log" \
          composer require "${m}"; then
        exit $?
    fi
  fi
done

# Permissions fixups.
chmod a+w ${HTDOCS}/sites/default;
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

# Create and change MySQL creds
#mysql -h${DATABASE_HOST} -uroot -p${MYSQL_ROOT_PASSWORD} -e \
#      "CREATE DATABASE drupal; GRANT ALL PRIVILEGES ON drupal.* TO 'drupal'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'; FLUSH PRIVILEGES;" 2>/dev/null
cd ${APPDIR}
cp "${APPDIR_DRUPALBASE}/sites/default/default.settings.php" "${APPDIR_DRUPALBASE}/sites/default/settings.php"

# Drush crashes w segfault if xdebug is on. Disable for cli.
rm -f /etc/php/7.2/cli/conf.d/20-xdebug.ini

# Site install.
if ! logrun "Running \`drush site-install\`." \
     "drush-site-install.log" \
      ${DRUSH} site-install standard \
        --account-name="${DEV_DRUPAL_ADMIN_USER}" \
        --account-pass="${DEV_DRUPAL_ADMIN_PASSWORD}" \
        --db-url="mysql://root:${MYSQL_ROOT_PASSWORD}@${DATABASE_HOST}:3306/drupal" \
        --site-name="${SITE_NAME}"; then
    exit $?
fi
chown -R www-data.www-data /var/www/html/web/sites/default/files

# Enabled themes
if [[ ! -z "${DEV_THEMES_ENABLED[*]}" ]]; then
  for theme in ${DEV_THEMES_ENABLED[*]}; do
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
if [[ ! -z ${DEV_PUBLIC_THEME} ]]; then
  if ! logrun "Set primary site theme: ${DEV_PUBLIC_THEME}." \
    "drush-config-set-system-theme-default.log" \
    ${DRUSH} config-set system.theme default "${DEV_PUBLIC_THEME}"; then
    echo "Cannot set theme ${DEV_PUBLIC_THEME}"
  fi
fi

# Set the admin theme
if [[ ! -z ${DEV_ADMIN_THEME} ]]; then
  if ! logrun "Set administration theme: ${DEV_ADMIN_THEME[*]}." \
    "drush-config-set-system-theme-admin.log" \
    ${DRUSH} config-set system.theme admin "${DEV_ADMIN_THEME}"; then
    echo "Cannot set admin theme ${DEV_ADMIN_THEME}"
  fi
fi

# Disabled themes
if [[ ! -z "${DEV_THEMES_DISABLED[*]}" ]]; then
  for theme in ${DEV_THEMES_DISABLED[*]}; do
    if ! logrun "Disable theme: ${theme}." \
      "drush-theme-uninstall.log" ${DRUSH} theme:uninstall ${theme}; then
      echo "Cannot disable theme ${theme}"
    fi
  done
fi

# Enabled modules
if [[ ! -z "${DEV_MODULES_ENABLED[*]}" ]]; then
  for module in ${DEV_MODULES_ENABLED[*]}; do
    if ! logrun "Enable module: ${module}." \
      "drush-pm-enable.log" ${DRUSH} pm-enable ${module}; then
      echo "Cannot enable module ${module}"
    fi
  done
fi

# Disabled modules
if [[ ! -z "${DEV_MODULES_DISABLED[*]}" ]]; then
  for module in ${DEV_MODULES_DISABLED[*]}; do
    if ! logrun "Disable module: ${module}." \
      "drush-pm-uninstall.log" ${DRUSH} pm-uninstall ${module}; then
      echo "Cannot uninstall module ${module}"
    fi
  done
fi

# Import features configuration.
if ! logrun "Applying Features configuration." \
  "drush-features-import-all.log" \
  ${DRUSH} features-import-all; then
  echo "Cannot import features see /tmp/drush-features-import-all.log"
fi

# Reset files perms
chown -R www-data:${GRPID} ${APPDIR}/sites/default/
chmod -R ug+w ${APPDIR}/sites/default/
chown -R mysql:${GRPID} /var/lib/mysql/
chmod -R ug+w /var/lib/mysql/

# User post installation script.
[[ -f "${WORKSPACE}/postinstall.sh" ]] && . "${WORKSPACE}/postinstall.sh" "${ENVIRONMENT}"

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
echo "  DRUPAL:  http://localhost               with user/pass: ${DEV_DRUPAL_ADMIN_USER}/${DEV_DRUPAL_ADMIN_PASSWORD}"
echo
echo "  SSH   :  ssh root@localhost             user:     root/${MYSQL_ROOT_PASSWORD}"
echo
echo "  Please report any issues to https://github.com/dfletcher/drupal-devcontainer"
echo
echo "----------------------------------------------------------------------------------"
echo
