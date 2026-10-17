#!/usr/bin/env bash
# Stop selfmail and its tunnel. Postfix is left running: it is the system MTA
# and other things may rely on it. Pass --all to stop that too.
set -u
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo ./kill.sh"; exit 1; }

UNITS="selfmail"
[ -f /etc/systemd/system/selfmail-tunnel.service ] && UNITS="$UNITS selfmail-tunnel"
[ -f /etc/systemd/system/selfmail-health.timer ] && UNITS="$UNITS selfmail-health.timer"
[ "${1:-}" = "--all" ] && UNITS="$UNITS opendkim postfix"

for u in $UNITS; do
  systemctl stop "$u" 2>/dev/null
  printf '  %-24s %s\n' "$u" "$(systemctl is-active "$u")"
done

# The health timer restarts things it finds down, so warn if it is still armed.
if systemctl is-active selfmail-health.timer >/dev/null 2>&1; then
  echo
  echo "note: selfmail-health.timer is still active and will restart these."
  echo "      run: sudo systemctl stop selfmail-health.timer"
fi
