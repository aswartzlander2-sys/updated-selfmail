#!/usr/bin/env bash
# fix-postfix.sh — run ON THE PI. Gets postfix listening on 127.0.0.1:25 again.
#
# Why this is needed: transfer.sh archived ~/selfmail only. Postfix keeps its
# config in /etc/postfix (and opendkim in /etc/opendkim*), which never moved.
# Those files are still on the PC, untouched. This pulls them over.
set -uo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

PC_IP="${PC_IP:-10.20.32.150}"
MYHOST="${MYHOST:-mail.robo-universe.com}"
BK="/root/postfix-backup-$(date +%Y%m%d-%H%M%S)"

c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[1m'; c_0=$'\e[0m'
say(){ printf '%s\n' "$*"; }
h(){ printf '\n%s== %s ==%s\n' "$c_b" "$*" "$c_0"; }
ok(){ printf '%s-- %s%s\n' "$c_g" "$*" "$c_0"; }
warn(){ printf '%s!! %s%s\n' "$c_y" "$*" "$c_0"; }
err(){ printf '%s!! %s%s\n' "$c_r" "$*" "$c_0"; }
ask(){ local r; read -r -p "$(printf '%s?? %s [y/N]: %s' "$c_b" "$1" "$c_0")" r </dev/tty; [[ "$r" =~ ^[Yy]$ ]]; }

########################################
h "1. Why is postfix down?"
########################################
if ! command -v postfix >/dev/null && ! dpkg -l postfix 2>/dev/null | grep -q '^ii'; then
  err "postfix is NOT INSTALLED on this Pi."
  say "That alone explains 'nothing listening on 127.0.0.1:25'."
  if ask "Install postfix now? (choose 'No configuration' when prompted)"; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix || { err "install failed"; exit 1; }
    ok "postfix installed"
  else
    say "Nothing else here will work without it."; exit 0
  fi
else
  ok "postfix is installed"
  say "-- why it won't start:"
  sudo systemctl status postfix --no-pager -l 2>/dev/null | sed -n '1,12p'
  sudo journalctl -u postfix --no-pager -n 15 2>/dev/null | tail -15
  say "-- config check:"
  sudo postfix check 2>&1 | head -15
fi

########################################
h "2. Pull the real config from the PC ($PC_IP)"
########################################
say "These paths were never in the ~/selfmail archive, so the PC still has them:"
say "    /etc/postfix/   /etc/opendkim.conf   /etc/opendkim/"
say ""
if ask "Copy those from the PC to this Pi now? (a backup is taken first)"; then
  read -r -p "PC SSH username: " PC_USER </dev/tty
  sudo mkdir -p "$BK"
  sudo cp -a /etc/postfix "$BK/" 2>/dev/null
  sudo cp -a /etc/opendkim.conf /etc/opendkim "$BK/" 2>/dev/null
  ok "Existing Pi config backed up to $BK"

  TMP="$(mktemp -d)"
  rsync -a -e ssh "$PC_USER@$PC_IP:/etc/postfix/" "$TMP/postfix/" \
    || { err "Could not read /etc/postfix from the PC."
         say "Postfix config is root-owned. On the PC, run this first:"
         say "   sudo tar czf ~/mailcfg.tgz /etc/postfix /etc/opendkim.conf /etc/opendkim"
         say "   sudo chown \$USER ~/mailcfg.tgz"
         say "then re-run and it will pick up ~/mailcfg.tgz over scp."
         rsync -a -e ssh "$PC_USER@$PC_IP:~/mailcfg.tgz" "$TMP/" 2>/dev/null \
           && { sudo tar xzf "$TMP/mailcfg.tgz" -C / && ok "Restored from mailcfg.tgz"; } ; }

  if [[ -d "$TMP/postfix" ]]; then
    sudo cp -a "$TMP/postfix/." /etc/postfix/ && ok "Copied /etc/postfix from the PC"
    rsync -a -e ssh "$PC_USER@$PC_IP:/etc/opendkim.conf" "$TMP/" 2>/dev/null \
      && sudo cp -a "$TMP/opendkim.conf" /etc/ && ok "Copied opendkim.conf"
    rsync -a -e ssh "$PC_USER@$PC_IP:/etc/opendkim/" "$TMP/opendkim/" 2>/dev/null \
      && sudo cp -a "$TMP/opendkim/." /etc/opendkim/ && ok "Copied /etc/opendkim (DKIM keys)"
  fi
  rm -rf "$TMP"
fi

########################################
h "2b. Files postfix needs that live OUTSIDE /etc/postfix"
########################################
say "main.cf references these by path, but they are not in /etc/postfix,"
say "so copying that directory alone leaves dangling references."
say ""

# /etc/mailname — Debian's myorigin target. Missing file = fatal on startup.
if [[ -f /etc/mailname ]]; then
  ok "/etc/mailname exists: $(cat /etc/mailname)"
else
  err "/etc/mailname MISSING — this is the 'cannot open file' fatal."
  if ask "Create /etc/mailname containing $MYHOST?"; then
    echo "$MYHOST" | sudo tee /etc/mailname >/dev/null
    ok "Created: $(cat /etc/mailname)"
  else
    say "Alternative that drops the file dependency entirely:"
    say "   sudo postconf -e 'myorigin = $MYHOST'"
  fi
fi

# /etc/aliases — alias_maps target; postfix won't start cleanly without it.
if [[ -f /etc/aliases ]]; then
  ok "/etc/aliases exists"
else
  warn "/etc/aliases missing"
  ask "Create a minimal /etc/aliases?" && {
    printf 'postmaster: root\nroot: %s\n' "${SUDO_USER:-$USER}" | sudo tee /etc/aliases >/dev/null
    ok "Created"
  }
fi
sudo newaliases 2>/dev/null && ok "alias database rebuilt" || warn "newaliases failed"

[[ -f /etc/default/opendkim ]] && ok "/etc/default/opendkim exists" \
                               || warn "/etc/default/opendkim missing (opendkim socket may be wrong)"

# Chroot jail copies of system files go stale after a host move.
if ask "Refresh postfix chroot permissions/files? (safe, idempotent)"; then
  sudo postfix set-permissions 2>/dev/null && ok "permissions refreshed"
fi

########################################
h "3. Point the config at this Pi, not the PC"
########################################
say "selfmail is in relay mode and expects smtpd on 127.0.0.1:25 only."
warn "127.0.0.1:25 is CORRECT — do not repoint it at a remote IP."
say "selfmail and postfix run on THIS SAME Pi, so localhost IS the server."
say "Pointing selfmail at another machine's IP would break a working setup."
if ask "Set myhostname=$MYHOST and bind loopback-only?"; then
  sudo postconf -e "myhostname = $MYHOST"
  sudo postconf -e "inet_interfaces = loopback-only"
  sudo postconf -e "inet_protocols = ipv4"
  ok "Set. Loopback-only means no public :25 exposure and no port clash."
fi
say "-- any lingering references to the old PC:"
sudo grep -rn "$PC_IP" /etc/postfix /etc/opendkim.conf 2>/dev/null | head -10 \
  || say "   none found"

########################################
h "4. Start it"
########################################
sudo postfix check 2>&1 | head -10
if ask "Start postfix now?"; then
  sudo systemctl enable --now postfix
  sudo systemctl restart postfix
  sleep 2
  if sudo ss -lntp 2>/dev/null | grep -q '127.0.0.1:25'; then
    ok "LISTENING on 127.0.0.1:25 — selfmail's status tab should go green."
  else
    err "Still not listening. Real error:"
    sudo journalctl -u postfix --no-pager -n 20 | tail -20
  fi
fi

########################################
h "5. Verify"
########################################
say "Queue (should no longer say 'mail system is down'):"
sudo postqueue -p 2>&1 | head -5
say ""
say "Live SMTP test:"
timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/25 && head -1 <&3' 2>/dev/null \
  && ok "smtpd answered — greeting received" \
  || err "no greeting on 127.0.0.1:25"
say ""
say "Then hit Refresh on selfmail's Status tab."
[[ -d "$BK" ]] && say "Rollback if needed:  sudo cp -a $BK/postfix/. /etc/postfix/ && sudo systemctl restart postfix"
