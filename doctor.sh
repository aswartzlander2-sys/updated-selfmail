#!/usr/bin/env bash
#
# selfmail doctor - diagnose and repair a Postfix that will not start
#
#   sudo ./doctor.sh
#
# Fixes the common reasons "postfix: down" persists, then prints a diagnostic
# bundle. If it still cannot start Postfix, copy everything between the two
# ==== DIAGNOSTIC BUNDLE ==== markers and send it back for a targeted fix.
#
set -u
[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./doctor.sh"; exit 1; }

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; Z=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; Z=""; fi
step() { printf '\n%s==>%s %s%s%s\n' "$C" "$Z" "$B" "$*" "$Z"; }
ok()   { printf '  %s+%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
bad()  { printf '  %sx%s %s\n' "$R" "$Z" "$*"; }

really_running() { postfix status >/dev/null 2>&1; }

step "1. Clearing anything else on port 25"
for m in exim4 exim sendmail nullmailer opensmtpd citadel; do
  if systemctl is-active --quiet "$m" 2>/dev/null; then
    warn "$m holds port 25 - stopping and disabling it"
    systemctl stop "$m" 2>/dev/null || true
    systemctl disable "$m" >/dev/null 2>&1 || true
  fi
done

# A Docker container that publishes port 25 (another mail server tried earlier)
# holds it through docker-proxy, which Postfix cannot bind past. Find and stop
# those containers, and turn off their restart policy so they do not come back.
OWNER="$(ss -lntp 2>/dev/null | awk '$4 ~ /:25$/' | grep -oE '"[^"]+"' | head -1 | tr -d '"')"
if [ "$OWNER" = docker-proxy ] && command -v docker >/dev/null 2>&1; then
  CIDS="$(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E ':25->' | cut -f1,2)"
  if [ -n "$CIDS" ]; then
    warn "a Docker container is publishing port 25 - stopping it so Postfix can bind"
    printf '%s\n' "$CIDS" | while IFS="$(printf '\t')" read -r cid cname; do
      [ -z "$cid" ] && continue
      warn "  stopping container $cname ($cid)"
      docker update --restart=no "$cid" >/dev/null 2>&1 || true
      docker stop "$cid" >/dev/null 2>&1 || true
    done
    sleep 2
    ok "container(s) on port 25 stopped (they will not restart on their own)"
  else
    warn "docker-proxy holds port 25 but no matching container was found - is another daemon publishing it?"
  fi
fi

# Kill a stale postfix master that survived a crash and is squatting the port.
if ! really_running && ss -lntp 2>/dev/null | grep -q ':25 .*master'; then
  warn "a dead postfix master is still holding port 25 - clearing it"
  fuser -k 25/tcp >/dev/null 2>&1 || true
  sleep 2
fi

OCC="$(ss -lntp 2>/dev/null | awk '$4 ~ /:25$/ {print}')"
if [ -z "$OCC" ]; then
  ok "port 25 is free"
else
  bad "port 25 is still held:"
  printf '%s\n' "$OCC" | sed 's/^/      /'
  STILL="$(printf '%s' "$OCC" | grep -oE '"[^"]+"' | head -1 | tr -d '"')"
  [ -n "$STILL" ] && warn "held by: $STILL - stop that before Postfix can start"
fi

step "2. Checking IPv6 vs Postfix inet_protocols"
# This is the big one. setup.sh set inet_protocols=all; on a host where IPv6
# is disabled the master fatals binding the IPv6 socket and never comes up.
HAVE_V6=1
if [ ! -f /proc/net/if_inet6 ] || [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" = 1 ]; then
  HAVE_V6=0
fi
CUR_PROTO="$(postconf -h inet_protocols 2>/dev/null || echo all)"
if [ "$HAVE_V6" = 0 ] && [ "$CUR_PROTO" != ipv4 ]; then
  bad "IPv6 is disabled on this host but Postfix is set to inet_protocols=$CUR_PROTO"
  warn "setting inet_protocols=ipv4 (this is very likely the whole problem)"
  postconf -e "inet_protocols = ipv4"
  # loopback-only listener may have been pinned to ::1 in master.cf; leave
  # main.cf authoritative and let postfix rebuild.
  ok "switched to ipv4-only"
else
  ok "inet_protocols=$CUR_PROTO is consistent with this host (IPv6 present: $HAVE_V6)"
fi

step "3. Config sanity"
CHK="$(postfix check 2>&1)"
if [ -n "$CHK" ]; then warn "postfix check reported:"; echo "$CHK" | sed 's/^/      /'
else ok "postfix check is clean"; fi
# Rebuild the lookup tables in case a .db is missing or stale.
[ -f /etc/postfix/vmailbox ] && postmap /etc/postfix/vmailbox 2>/dev/null && ok "rebuilt vmailbox map" || true
[ -f /etc/postfix/virtual ]  && postmap /etc/postfix/virtual  2>/dev/null && ok "rebuilt virtual map"  || true
newaliases 2>/dev/null || true

step "4. OpenDKIM milter socket"
# If Postfix is told to use a milter socket that does not exist it still
# starts, but be sure opendkim is actually up and owns the socket.
if systemctl is-active --quiet opendkim; then
  ok "opendkim is running"
else
  warn "opendkim is not running - starting it"
  systemctl restart opendkim 2>/dev/null || true
fi

step "5. Restarting Postfix"
systemctl reset-failed postfix 2>/dev/null || true
systemctl restart postfix 2>/dev/null || true
sleep 3
if really_running; then
  ok "Postfix is now running"
else
  bad "Postfix is still down - capturing the exact reason below"
fi

step "6. Restarting selfmail + tunnel"
systemctl restart selfmail 2>/dev/null || true
[ -f /etc/systemd/system/selfmail-tunnel.service ] && systemctl restart selfmail-tunnel 2>/dev/null || true

# ---------------------------------------------------------------------------
if really_running; then
  step "Result"
  GREET="$( (exec 3<>/dev/tcp/127.0.0.1/25 && head -1 <&3) 2>/dev/null )"
  if printf '%s' "$GREET" | grep -q '^220'; then
    ok "Fixed. Postfix is accepting SMTP on port 25:"
    echo "    $GREET"
  else
    ok "Fixed. Postfix reports running."
  fi
  echo
  echo "  Re-check the Status tab in the web UI - it should read postfix: active."
  exit 0
fi

# Still broken: emit a bundle to paste back.
cat <<'HDR'

  Postfix would not start even after repair. The exact failure is captured
  below. Copy everything between the two ==== markers and send it back.

==== DIAGNOSTIC BUNDLE ====
HDR
echo "--- uname ---";            uname -a
echo "--- os-release ---";       cat /etc/os-release 2>/dev/null | grep -E 'PRETTY|VERSION' || true
echo "--- ipv6 present ---";     { [ -f /proc/net/if_inet6 ] && echo yes || echo no; }
echo "--- inet_protocols ---";   postconf -h inet_protocols 2>&1
echo "--- inet_interfaces ---";  postconf -h inet_interfaces 2>&1
echo "--- port 25 owner ---";    ss -lntp 2>/dev/null | awk 'NR==1 || $4 ~ /:25$/'
echo "--- postfix check ---";    postfix check 2>&1
echo "--- postfix start (fg, 3s) ---"
timeout 3 postfix start-fg 2>&1 | head -25 || true
echo "--- journalctl postfix ---"
journalctl -u postfix@- -u postfix -n 40 --no-pager 2>&1 | tail -40
echo "--- mail.log tail ---"
{ tail -n 40 /var/log/mail.log 2>/dev/null || tail -n 40 /var/log/maillog 2>/dev/null; } | grep -iE 'fatal|error|warning|master' | tail -20
echo "--- master.cf smtp/inet lines ---"
grep -nE '^\s*(smtp|25)\s+inet|inet_protocols' /etc/postfix/master.cf 2>/dev/null || true
echo "==== END DIAGNOSTIC BUNDLE ===="
exit 1
