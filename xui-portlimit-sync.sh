#!/bin/bash
set -euo pipefail

DB_PATH="/etc/x-ui/x-ui.db"
TABLE_FAMILY="inet"
TABLE_NAME="xui_auto_portlimit"
CHAIN_NAME="input"
TIMEOUT="${XUI_PORTLIMIT_TIMEOUT:-5m}"
STATE_FILE="/var/lib/xui-portlimit/desired.conf"
LOCK_FILE="/run/xui-portlimit-sync.lock"

command -v nft >/dev/null 2>&1 || { echo "nft command not found"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 command not found"; exit 1; }
[ -f "$DB_PATH" ] || { echo "db not found: $DB_PATH"; exit 1; }
mkdir -p /var/lib/xui-portlimit

table_exists() {
  nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1
}

port_is_blocked() {
  local port="$1"
  nft list set "$TABLE_FAMILY" "$TABLE_NAME" blocked_ports 2>/dev/null \
    | grep -Eq "(^|[^0-9])${port}([^0-9]|$)"
}

runtime_maintain() {
  [ -z "$DESIRED" ] && return 0
  while IFS=' ' read -r PORT LIMIT; do
    [ -z "$PORT" ] && continue
    SETNAME="p_${PORT}"
    if port_is_blocked "$PORT"; then
      # Clear sticky IP cache while blocked so recovery starts from a clean window.
      nft flush set "$TABLE_FAMILY" "$TABLE_NAME" "$SETNAME" >/dev/null 2>&1 || true
    fi
  done <<< "$DESIRED"
}

# Prevent concurrent runs from timer/manual hooks from corrupting nft state.
if command -v flock >/dev/null 2>&1; then
  exec 200>"$LOCK_FILE"
  if ! flock -w 20 200; then
    echo "busy"
    exit 0
  fi
else
  LOCK_DIR="${LOCK_FILE}.d"
  _wait=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    _wait=$((_wait + 1))
    if [ "$_wait" -ge 40 ]; then
      echo "busy"
      exit 0
    fi
    sleep 0.5
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

# Build desired list: one line "port limit" for enabled inbounds with IP limit > 0
DESIRED=$(
python3 - <<'PY'
import sqlite3, json
con=sqlite3.connect('/etc/x-ui/x-ui.db')
cur=con.cursor()
rows=cur.execute(
    "select port,enable,listen,ip_limit,settings from inbounds "
    "where enable=1 and port between 1 and 65535"
).fetchall()
result=[]
for port, enable, listen, ip_limit, settings in rows:
    # ignore loopback-only listeners
    l=(listen or '').strip().lower()
    if l in ('127.0.0.1','::1','localhost'):
        continue
    # Prefer per-inbound ip_limit (x-ui DB column). Fall back to settings.clients[].limitIp for compatibility.
    try:
        limit=int(ip_limit or 0)
    except Exception:
        limit=0
    if settings:
        try:
            s=json.loads(settings)
            clients=s.get('clients',[])
            for c in clients:
                if isinstance(c, dict):
                    if c.get('enable', True) is False:
                        continue
                    li=int(c.get('limitIp',0) or 0)
                    if li>limit:
                        limit=li
        except Exception:
            pass
    if limit>0:
        result.append((int(port), int(limit)))

# Merge same port by max limit
merged={}
for p,l in result:
    merged[p]=max(merged.get(p,0), l)
for p in sorted(merged):
    print(f"{p} {merged[p]}")
PY
)

# If unchanged, do nothing (keep current nft state / timers)
OLD=""
[ -f "$STATE_FILE" ] && OLD="$(cat "$STATE_FILE")"
if [ "${XUI_PORTLIMIT_FORCE_REBUILD:-0}" != "1" ] && [ "$DESIRED" = "$OLD" ]; then
  if ! table_exists; then
    XUI_PORTLIMIT_FORCE_REBUILD=1
  else
    runtime_maintain
    echo "unchanged"
    exit 0
  fi
fi

# Rebuild table atomically by replacing whole table
nft delete table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null || true
nft add table "$TABLE_FAMILY" "$TABLE_NAME"
nft "add chain $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME { type filter hook input priority 0; policy accept; }"
nft "add set $TABLE_FAMILY $TABLE_NAME blocked_ports { type inet_service; flags timeout,dynamic; timeout $TIMEOUT; }"
nft "add rule $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME tcp dport @blocked_ports counter drop"
nft "add rule $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME udp dport @blocked_ports counter drop"

if [ -n "$DESIRED" ]; then
  while IFS=' ' read -r PORT LIMIT; do
    [ -z "$PORT" ] && continue
    SETNAME="p_${PORT}"
    nft "add set $TABLE_FAMILY $TABLE_NAME $SETNAME { type ipv4_addr; flags timeout,dynamic; timeout $TIMEOUT; size $LIMIT; }"

    nft "add rule $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME tcp dport $PORT ip saddr @$SETNAME accept"
    nft "add rule $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME udp dport $PORT ip saddr @$SETNAME accept"

    nft "add rule $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME tcp dport $PORT add @$SETNAME { ip saddr timeout $TIMEOUT } accept"
    nft "add rule $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME udp dport $PORT add @$SETNAME { ip saddr timeout $TIMEOUT } accept"

    # If a new source IP exceeds the per-port set size, mark this port as blocked for TIMEOUT.
    nft "add rule $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME tcp dport $PORT add @blocked_ports { tcp dport timeout $TIMEOUT } counter drop"
    nft "add rule $TABLE_FAMILY $TABLE_NAME $CHAIN_NAME udp dport $PORT add @blocked_ports { udp dport timeout $TIMEOUT } counter drop"
  done <<< "$DESIRED"
fi

printf '%s' "$DESIRED" > "$STATE_FILE"
runtime_maintain

echo "applied"
if [ -z "$DESIRED" ]; then
  echo "managed_ports=none"
else
  echo "managed_ports=$(echo "$DESIRED" | tr '\n' ',' | sed 's/,$//')"
fi
echo "timeout=$TIMEOUT"
