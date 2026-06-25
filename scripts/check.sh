#!/usr/bin/env bash
set -euo pipefail

MYSQL_CNF="${MYSQL_CNF:-/etc/zabbix/.my.cnf}"
HAPROXY_SOCKET="${HAPROXY_SOCKET:-/run/haproxy/admin.sock}"
VIP="${VIP:-}"
MYSQL_FRONT_PORT="${MYSQL_FRONT_PORT:-3307}"

mysql_status() {
  local var="$1"
  mysql --defaults-extra-file="$MYSQL_CNF" --batch --skip-column-names \
    -e "SHOW GLOBAL STATUS LIKE '${var}'" 2>/dev/null | awk '{print $2}'
}

mysql_ping() {
  mysqladmin --defaults-extra-file="$MYSQL_CNF" ping --silent >/dev/null 2>&1 && echo 1 || echo 0
}

galera_primary() {
  [[ "$(mysql_status wsrep_cluster_status)" == "Primary" ]] && echo 1 || echo 0
}

galera_ready() {
  [[ "$(mysql_status wsrep_ready)" == "ON" ]] && echo 1 || echo 0
}

galera_connected() {
  [[ "$(mysql_status wsrep_connected)" == "ON" ]] && echo 1 || echo 0
}

galera_synced() {
  [[ "$(mysql_status wsrep_local_state_comment)" == "Synced" ]] && echo 1 || echo 0
}

haproxy_server_up() {
  local server="$1"
  if [[ ! -S "$HAPROXY_SOCKET" ]]; then
    echo 0
    return
  fi

  printf 'show stat\n' | socat -T 2 - UNIX-CONNECT:"$HAPROXY_SOCKET" 2>/dev/null \
    | awk -F, -v server="$server" '$1 == "galera_back" && $2 == server { print ($18 == "UP" ? 1 : 0); found=1 } END { if (!found) print 0 }'
}

haproxy_backends_up_count() {
  if [[ ! -S "$HAPROXY_SOCKET" ]]; then
    echo 0
    return
  fi

  printf 'show stat\n' | socat -T 2 - UNIX-CONNECT:"$HAPROXY_SOCKET" 2>/dev/null \
    | awk -F, '$1 == "galera_back" && $2 != "BACKEND" && $18 == "UP" { count++ } END { print count + 0 }'
}

process_running() {
  local process="$1"
  pgrep -x "$process" >/dev/null 2>&1 && echo 1 || echo 0
}

vip_present() {
  VIP="${1:-$VIP}"
  if [[ -z "$VIP" || "$VIP" == "<CHANGE_ME>" ]]; then
    echo 0
    return
  fi

  ip -o addr show 2>/dev/null | grep -qw "${VIP}" && echo 1 || echo 0
}

tcp_listen() {
  ss -ltn "sport = :${MYSQL_FRONT_PORT}" 2>/dev/null | grep -q ":${MYSQL_FRONT_PORT}" && echo 1 || echo 0
}

case "${1:-}" in
  mysql.ping) mysql_ping ;;
  galera.value) mysql_status "${2:?missing wsrep status variable}" ;;
  galera.primary) galera_primary ;;
  galera.ready) galera_ready ;;
  galera.connected) galera_connected ;;
  galera.synced) galera_synced ;;
  haproxy.server_up) haproxy_server_up "${2:?missing haproxy server name}" ;;
  haproxy.backends_up_count) haproxy_backends_up_count ;;
  process.running) process_running "${2:?missing process name}" ;;
  keepalived.vip.present) vip_present "${2:-}" ;;
  haproxy.mysql_front.listen) tcp_listen ;;
  *)
    echo "Unsupported command" >&2
    exit 1
    ;;
esac
