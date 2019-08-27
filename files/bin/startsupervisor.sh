#!/bin/bash

function killit(){
  N="${1}"
  F="${2}"
  P=$(pgrep "${N}")
  [[ -z ${P} ]] || kill -SIGKILL ${P}
  [[ -z ${F} ]] || rm -f ${F}
}

killit supervisord
killit apache2 /var/run/apache2/apache2.pid
killit mysql /var/run/mysqld/mysqld.pid
killit sshd /var/run/sshd.pid

/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf -l /tmp/supervisord.log
/usr/bin/tail -f /tmp/supervisord.log
