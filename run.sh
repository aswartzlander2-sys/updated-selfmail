#!/usr/bin/env bash
# Start selfmail and its tunnel (if configured), then report real status.
set -u
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo ./run.sh"; exit 1; }

# Another MTA holding port 25 makes Postfix fail to bind. The failure is quiet:
# postfix.service on Debian/Ubuntu is only a wrapper and still reports
# "active", while the other server answers mail with its own policy - usually
# "554 Relay access denied". Clear it before starting anything.
for m in exim4 exim sendmail nullmailer opensmtpd citadel; do
  if systemctl is-active --quiet "$m" 2>/dev/null; then
    echo "  $m owns port 25 - stopping and disabling it"
    systemctl stop "$m" 2>/dev/null || true
    systemctl disable "$m" >/dev/null 2>&1 || true
  fi
done

UNITS="postfix opendkim selfmail"
[ -f /etc/systemd/system/selfmail-tunnel.service ] && UNITS="$UNITS selfmail-tunnel"

for u in $UNITS; do systemctl start "$u" 2>/dev/null; done
systemctl restart postfix 2>/dev/null || true
[ -f /etc/systemd/system/selfmail-health.timer ] && systemctl start selfmail-health.timer 2>/dev/null
sleep 3

echo
echo "service status:"
FAILED=0
for u in $UNITS; do
  if [ "$u" = postfix ]; then
    # `postfix status` checks the master is really up, unlike systemctl here.
    if postfix status >/dev/null 2>&1; then
      printf '  %-16s %s\n' postfix running
    else
      printf '  %-16s %s\n' postfix "NOT RUNNING"
      FAILED=1
    fi
  else
    printf '  %-16s %s\n' "$u" "$(systemctl is-active "$u")"
  fi
done

if [ "$FAILED" = 1 ]; then
  echo
  echo "Postfix could not start. Whatever is holding port 25:"
  ss -lntp 2>/dev/null | awk 'NR==1 || $4 ~ /:25$/' | sed 's/^/    /'
  echo
  echo "Stop that service, then re-run this script."
fi


# If Postfix still is not up, run the doctor automatically - it clears Docker
# or MTA squatters on port 25, fixes the IPv6 bind issue, and restarts.
if ! postfix status >/dev/null 2>&1; then
  echo
  echo "Postfix is not up - running doctor.sh to repair it..."
  "$(dirname "$0")/doctor.sh" || true
fi

PORT="$(awk -F= '/^SELFMAIL_PORT=/{print $2}' /etc/selfmail/env 2>/dev/null)"
echo
echo "web UI: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT:-8088}"
HOST_PUB="$(awk '/hostname:/ {print $3; exit}' /etc/cloudflared/config.yml 2>/dev/null)"
[ -n "$HOST_PUB" ] && echo "public: https://$HOST_PUB"
