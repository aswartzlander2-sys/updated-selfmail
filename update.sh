#!/usr/bin/env bash
#
# selfmail update + login helper
#
#   sudo ./update.sh                 pull, deploy the latest code, then set a login
#   sudo ./update.sh <user> <pass>   deploy + set one login non-interactively
#   sudo ./update.sh --login-only    manage logins without touching code
#   sudo ./update.sh --list          show configured usernames
#   sudo ./update.sh --remove <user>
#   sudo ./update.sh --disable-default
#
# Logins live in /etc/selfmail/users.json as username -> sha256(password).
# The published default adminpass / adminpass26! works until removed or disabled.
#
set -u
[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./update.sh"; exit 1; }

APP_DIR="/opt/selfmail"
CFG_DIR="/etc/selfmail"
USERS_FILE="$CFG_DIR/users.json"
ENV_FILE="$CFG_DIR/env"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_USER="selfmail"; id "$APP_USER" >/dev/null 2>&1 || APP_USER=root

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; Z=$'\e[0m'
else B=""; G=""; Y=""; C=""; Z=""; fi
step() { printf '\n%s==>%s %s%s%s\n' "$C" "$Z" "$B" "$*" "$Z"; }
ok()   { printf '  %s+%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }

sha256() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

mkdir -p "$CFG_DIR"
[ -f "$USERS_FILE" ] || echo '{}' > "$USERS_FILE"

users_set() { # user hash
  python3 - "$USERS_FILE" "$1" "$2" <<'PY'
import json,sys
f,u,h=sys.argv[1:4]
try: d=json.load(open(f))
except Exception: d={}
d[u]=h; json.dump(d,open(f,'w'),indent=2)
PY
}
users_del() {
  python3 - "$USERS_FILE" "$1" <<'PY'
import json,sys
f,u=sys.argv[1:3]
try: d=json.load(open(f))
except Exception: d={}
d.pop(u,None); json.dump(d,open(f,'w'),indent=2)
PY
}
users_list() {
  python3 - "$USERS_FILE" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
[print("  -",k) for k in d]
PY
}

# --------------------------------------------------------- deploy code -----
deploy_code() {
  [ -d "$APP_DIR" ] || { warn "$APP_DIR missing - run setup.sh first; skipping code deploy"; return; }

  step "Pulling latest code"
  if [ -d "$SRC_DIR/.git" ]; then
    local owner; owner="$(stat -c '%U' "$SRC_DIR" 2>/dev/null || echo root)"
    if [ "$owner" != root ] && id "$owner" >/dev/null 2>&1; then
      sudo -u "$owner" git -C "$SRC_DIR" pull --ff-only 2>&1 | sed 's/^/  /' || warn "pull failed - using files on disk"
    else
      git config --global --add safe.directory "$SRC_DIR" 2>/dev/null || true
      git -C "$SRC_DIR" pull --ff-only 2>&1 | sed 's/^/  /' || warn "pull failed - using files on disk"
    fi
    ok "at $(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  fi

  step "Deploying application files"
  [ -f "$SRC_DIR/server.js" ] || { warn "server.js missing from $SRC_DIR - not deploying"; return; }
  cp "$SRC_DIR/server.js" "$APP_DIR/server.js"
  cp "$SRC_DIR/package.json" "$APP_DIR/package.json" 2>/dev/null || true
  mkdir -p "$APP_DIR/public"; cp -r "$SRC_DIR/public/." "$APP_DIR/public/" 2>/dev/null || true
  ( cd "$APP_DIR" && npm install --omit=dev --silent --no-audit --no-fund >/dev/null 2>&1 ) || warn "npm install had problems"
  chown -R "$APP_USER":"$APP_USER" "$APP_DIR" 2>/dev/null || true
  ok "code installed to $APP_DIR"

  # Same IPv6 safety net as setup.sh, so an updated box cannot end up with a
  # Postfix that will not bind.
  if [ ! -f /proc/net/if_inet6 ] || [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" = 1 ]; then
    [ "$(postconf -h inet_protocols 2>/dev/null)" != ipv4 ] && postconf -e "inet_protocols = ipv4" && systemctl restart postfix 2>/dev/null || true
  fi
}

finish() {
  chown root:"$APP_USER" "$USERS_FILE" 2>/dev/null || true
  chmod 640 "$USERS_FILE"
  systemctl restart selfmail 2>/dev/null || true
  sleep 1
  echo
  ok "Done. The web interface now requires a login."
  PORT="$(awk -F= '/^SELFMAIL_PORT=/{print $2}' "$ENV_FILE" 2>/dev/null)"
  HOST_PUB="$(awk '/hostname:/ {print $3; exit}' /etc/cloudflared/config.yml 2>/dev/null)"
  echo "  web UI: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT:-8088}"
  [ -n "$HOST_PUB" ] && echo "  public: https://$HOST_PUB"
}

# ------------------------------------------------------------- dispatch ----
case "${1:-}" in
  --list) echo "${B}Configured logins:${Z}"; users_list
    echo "  (built-in default 'adminpass' also works unless disabled)"; exit 0 ;;
  --remove) [ -n "${2:-}" ] || { echo "usage: --remove <user>"; exit 1; }
    users_del "$2"; ok "removed $2"; finish; exit 0 ;;
  --disable-default)
    grep -q '^SELFMAIL_DISABLE_DEFAULT=' "$ENV_FILE" 2>/dev/null \
      && sed -i 's/^SELFMAIL_DISABLE_DEFAULT=.*/SELFMAIL_DISABLE_DEFAULT=1/' "$ENV_FILE" \
      || echo 'SELFMAIL_DISABLE_DEFAULT=1' >> "$ENV_FILE"
    ok "built-in default login disabled"; finish; exit 0 ;;
  --login-only) SKIP_DEPLOY=1; shift ;;
  *) SKIP_DEPLOY=0 ;;
esac

[ "${SKIP_DEPLOY:-0}" = 1 ] || deploy_code

step "Web login"
U="${1:-}"; P="${2:-}"
if [ -z "$U" ]; then
  printf '  %sUsername (blank to keep current logins):%s ' "$B" "$Z"
  if [ -e /dev/tty ]; then read -r U </dev/tty; else read -r U; fi
fi
if [ -n "$U" ]; then
  if [ -z "$P" ]; then
    printf '  Password: '
    if [ -e /dev/tty ]; then read -r -s P </dev/tty; else read -r P; fi
    printf '\n'
  fi
  [ -n "$P" ] || { echo "  a password is required"; exit 1; }
  users_set "$U" "$(sha256 "$P")"
  ok "login '$U' set"
else
  ok "keeping existing logins"
fi
finish
