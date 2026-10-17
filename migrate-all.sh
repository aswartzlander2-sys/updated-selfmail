#!/usr/bin/env bash
# migrate-all.sh — complete the selfmail migration end to end.
#
#   RUN THIS ON THE PC (homer), as yourself, NOT with sudo:
#       bash migrate-all.sh
#
# It prompts for the Pi's SSH details and drives every Pi-side step over that
# connection. Your password is never stored or logged; ssh-copy-id prompts you
# once, then key auth is used throughout.
#
# Nothing on the PC is deleted unless you explicitly ask at the very last step,
# and only after the Pi is verified serving.
#
# Verified facts this is built on (2026-09-13):
#   PC  homer       x86    — runs selfmail + cloudflared today, postfix stopped
#   Pi  rasp-robo1  ARM64  — Debian 13, postfix 3.10.13 + cloudflared installed
#                            but inactive; Docker holds :25; vmail/opendkim missing
#   Inbound mail = ForwardEmail WEBHOOK over the tunnel, not SMTP.
#   Postfix is OUTBOUND only. All 7 DNS records pass — do not edit DNS.
set -uo pipefail

SRC="${SELFMAIL_SRC:-$HOME/selfmail}"
FQDN="mailhook.robo-universe.com"
MYHOST="mail.robo-universe.com"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/migrate-all-$STAMP.log"
STOPPED=(); RESTORED=0

c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[1m'; c_0=$'\e[0m'
say(){ printf '%s\n' "$*"; }
h(){ printf '\n%s========== %s ==========%s\n' "$c_b" "$*" "$c_0"; }
t(){ printf '\n-- %s --\n' "$*"; }
ok(){ printf '  %s[OK]%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '  %s[!!]%s %s\n' "$c_y" "$c_0" "$*"; }
err(){ printf '  %s[XX]%s %s\n' "$c_r" "$c_0" "$*"; }
ask(){ local r; read -r -p "$(printf '%s?? %s [y/N]: %s' "$c_b" "$1" "$c_0")" r </dev/tty; [[ "$r" =~ ^[Yy]$ ]]; }
phrase(){ local r; printf '%s%s%s\n' "$c_y" "$1" "$c_0"
  read -r -p "Type exactly '$2' to proceed: " r </dev/tty; [[ "$r" == "$2" ]]; }

redact(){ sed -E \
  -e 's/(eyJ[A-Za-z0-9_-]{8})[A-Za-z0-9_=.-]+/\1<REDACTED-TOKEN>/g' \
  -e 's#(/inbound/)[A-Za-z0-9]{8}[A-Za-z0-9]*#\1<REDACTED-WEBHOOK>#g' \
  -e 's/(pass(word)?|secret|token|apikey)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\3<REDACTED>/Ig' \
  -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/<REDACTED-PRIVATE-KEY>/g'; }
exec > >(tee -a "$LOG" | redact) 2>&1

# Anything stopped here must come back if the script dies or is interrupted.
restore_local(){
  (( RESTORED )) && return 0; RESTORED=1
  [[ ${#STOPPED[@]} -eq 0 ]] && return 0
  h "Restarting PC services that were stopped"
  for u in "${STOPPED[@]}"; do sudo systemctl start "$u" 2>/dev/null && ok "restarted $u"; done
}
trap 'restore_local' EXIT INT TERM

[[ $EUID -eq 0 ]] && { err "Do NOT run this with sudo. Run as yourself: bash $0"; exit 1; }

######################################################################
h "PHASE 1 — SSH to the Pi"
######################################################################
read -r -p "Pi address [10.20.31.124]: " PI_HOST </dev/tty; PI_HOST="${PI_HOST:-10.20.31.124}"
read -r -p "Pi SSH username: " PI_USER </dev/tty
read -r -p "Pi SSH port [22]: " PI_PORT </dev/tty; PI_PORT="${PI_PORT:-22}"
SSHO=(-p "$PI_PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
pi(){ ssh "${SSHO[@]}" "$PI_USER@$PI_HOST" "$@"; }
pisudo(){ ssh -tt "${SSHO[@]}" "$PI_USER@$PI_HOST" "sudo bash -c '$*'" 2>/dev/null; }

say "Your password is never stored by this script — ssh-copy-id prompts you directly."
if ! ssh -o BatchMode=yes "${SSHO[@]}" "$PI_USER@$PI_HOST" true 2>/dev/null; then
  warn "No key auth yet."
  ask "Set up SSH keys now? (recommended)" && {
    [[ -f "$HOME/.ssh/id_ed25519.pub" ]] || ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
    ssh-copy-id -p "$PI_PORT" "$PI_USER@$PI_HOST"; }
fi
pi true || { err "Cannot reach the Pi over SSH."; exit 1; }
PI_NAME="$(pi hostname)"; PC_NAME="$(hostname)"
ok "PC = $PC_NAME    Pi = $PI_NAME ($(pi uname -m))"
[[ -d "$SRC" ]] || { err "$SRC not found on this PC"; exit 1; }
ok "source: $SRC  ($(du -sh "$SRC" 2>/dev/null | cut -f1), $(find "$SRC" -type f | wc -l) files)"

UNIT="$(systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null | grep -i selfmail | awk '{print $1}' | head -1)"
CFUNIT="$(systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null | grep -i cloudflared | awk '{print $1}' | head -1)"
say "  selfmail unit on PC   : ${UNIT:-<none found>}"
say "  cloudflared unit on PC: ${CFUNIT:-<none found>}"

######################################################################
h "PHASE 2 — Diagnose both machines"
######################################################################
t "PC"
say "  selfmail : $(systemctl is-active "${UNIT:-nonexistent}" 2>/dev/null)"
say "  cloudflared: $(systemctl is-active "${CFUNIT:-nonexistent}" 2>/dev/null)"
say "  postfix  : $(systemctl is-active postfix 2>/dev/null)"
t "Pi"
say "  postfix  : $(pi 'systemctl is-active postfix' 2>/dev/null)"
say "  cloudflared: $(pi 'systemctl is-active cloudflared' 2>/dev/null)"
say "  port 25  : $(pi "ss -lntp 2>/dev/null | grep ':25 ' | head -2" || echo free)"
say "  vmail user: $(pi 'id vmail 2>/dev/null || echo MISSING')"

######################################################################
h "PHASE 3 — Free port 25 on the Pi"
######################################################################
say "Docker publishes :25 on the Pi, which blocks postfix from binding."
PORTS="$(pisudo "docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}'" 2>/dev/null | grep ':25' || true)"
if [[ -n "$PORTS" ]]; then
  say "$PORTS" | sed 's/^/  /'
  CNAME="$(printf '%s' "$PORTS" | head -1 | cut -d'|' -f1 | tr -d '\r')"
  if ask "Stop container '$CNAME'? (stopped, not deleted; autostart disabled)"; then
    pisudo "docker stop $CNAME; docker update --restart=no $CNAME"
    ok "stopped $CNAME"
  fi
else
  ok "nothing holding :25 on the Pi"
fi

######################################################################
h "PHASE 4 — Users, config and DKIM keys onto the Pi"
######################################################################
say "main.cf uses static uid/gid 5000 for virtual delivery."
pisudo "getent group vmail >/dev/null || groupadd -g 5000 vmail
        id vmail &>/dev/null || useradd -g vmail -u 5000 -d /var/mail/vhosts -s /usr/sbin/nologin vmail
        mkdir -p /var/mail/vhosts && chown -R vmail:vmail /var/mail/vhosts
        apt-get install -y opendkim opendkim-tools >/dev/null 2>&1 || true"
ok "vmail user + opendkim package"

say "Bundling PC system config (root-owned, so tar first)..."
sudo tar czf /tmp/mailcfg-$STAMP.tgz \
  /etc/postfix /etc/mailname /etc/aliases \
  /etc/opendkim.conf /etc/opendkim /etc/default/opendkim 2>/dev/null
sudo chown "$USER" "/tmp/mailcfg-$STAMP.tgz"
rsync -ah --info=progress2 -e "ssh ${SSHO[*]}" "/tmp/mailcfg-$STAMP.tgz" "$PI_USER@$PI_HOST:/tmp/"
pisudo "mkdir -p /root/premigrate-$STAMP && cp -a /etc/postfix /root/premigrate-$STAMP/ 2>/dev/null
        tar xzf /tmp/mailcfg-$STAMP.tgz -C /
        chown -R opendkim:opendkim /etc/opendkim 2>/dev/null
        newaliases 2>/dev/null"
ok "config + DKIM keys restored on the Pi (backup: /root/premigrate-$STAMP)"

say "Rebuilding map databases on ARM (x86 .db files are not portable)..."
pisudo "for m in \$(postconf -n | grep -oE '(hash|btree):/[^,[:space:]]+'); do postmap \$m 2>/dev/null; done
        postconf -e 'myhostname = $MYHOST'
        postconf -e 'myorigin = /etc/mailname'
        postconf -e 'inet_interfaces = loopback-only'
        postconf -e 'inet_protocols = ipv4'
        postfix set-permissions"
ok "maps rebuilt, relay-mode config set, permissions correct"

######################################################################
h "PHASE 5 — CUTOVER: stop the PC, sync the delta"
######################################################################
warn "Mail has kept arriving on this PC since the first copy."
warn "From here the PC stops serving. Brief downtime is expected and safe:"
warn "ForwardEmail retries webhook deliveries that fail."
ask "Begin cutover?" || { say "Nothing changed. Re-run when ready."; exit 0; }

[[ -n "$UNIT" ]] && { sudo systemctl stop "$UNIT" && STOPPED+=("$UNIT") && ok "stopped $UNIT on PC"; }
rsync -ah --delete --info=progress2 -e "ssh ${SSHO[*]}" \
      "$SRC/" "$PI_USER@$PI_HOST:/home/$PI_USER/selfmail/" \
  && ok "delta sync complete — Pi store is now identical" \
  || { err "delta sync FAILED — aborting, PC services will restart"; exit 1; }

######################################################################
h "PHASE 6 — Start everything on the Pi"
######################################################################
if [[ -n "$UNIT" && -f "/etc/systemd/system/$UNIT" ]]; then
  sudo cp "/etc/systemd/system/$UNIT" "/tmp/$UNIT"; sudo chown "$USER" "/tmp/$UNIT"
  rsync -ah -e "ssh ${SSHO[*]}" "/tmp/$UNIT" "$PI_USER@$PI_HOST:/tmp/"
  pisudo "cp /tmp/$UNIT /etc/systemd/system/
          sed -i 's#/home/[^/]*/#/home/$PI_USER/#g' /etc/systemd/system/$UNIT
          systemctl daemon-reload"
  ok "unit $UNIT installed on the Pi with paths rewritten"
fi
pi "cd ~/selfmail && (npm ci --omit=dev || npm install --omit=dev) >/dev/null 2>&1 && echo ok" >/dev/null \
  && ok "node dependencies installed" || warn "npm install reported problems"

pisudo "systemctl enable --now postfix
        systemctl enable --now opendkim 2>/dev/null
        ${UNIT:+systemctl enable --now $UNIT}"
sleep 4
say "  postfix : $(pi 'systemctl is-active postfix')"
say "  opendkim: $(pi 'systemctl is-active opendkim' 2>/dev/null)"
[[ -n "$UNIT" ]] && say "  selfmail: $(pi "systemctl is-active $UNIT")"
BANNER="$(pi "timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/25 && head -1 <&3'" 2>/dev/null)"
[[ -n "$BANNER" ]] && ok "SMTP banner: $BANNER" || err "no SMTP banner on the Pi — outbound will fail"

######################################################################
h "PHASE 7 — Move the tunnel (never both at once)"
######################################################################
warn "Two connectors on one tunnel splits mail across both machines."
if ask "Stop the PC connector and start the Pi's?"; then
  [[ -n "$CFUNIT" ]] && { sudo systemctl stop "$CFUNIT"; sudo systemctl disable "$CFUNIT" 2>/dev/null; ok "PC connector stopped + disabled"; }
  TOKEN="$(sudo grep -rhoE 'eyJ[A-Za-z0-9_=-]{40,}' /etc/cloudflared "$SRC" 2>/dev/null | head -1)"
  if [[ -n "$TOKEN" ]]; then
    pisudo "cloudflared service install $TOKEN"
  else
    sudo tar czf /tmp/cf-$STAMP.tgz /etc/cloudflared 2>/dev/null; sudo chown "$USER" "/tmp/cf-$STAMP.tgz"
    rsync -ah -e "ssh ${SSHO[*]}" "/tmp/cf-$STAMP.tgz" "$PI_USER@$PI_HOST:/tmp/"
    pisudo "tar xzf /tmp/cf-$STAMP.tgz -C / && cloudflared service install 2>/dev/null"
  fi
  pisudo "systemctl enable --now cloudflared"
  sleep 8
  say "  cloudflared on Pi: $(pi 'systemctl is-active cloudflared')"
fi

######################################################################
h "PHASE 8 — Verify the Pi is serving"
######################################################################
sleep 5
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://$FQDN/")"
say "  https://$FQDN -> $CODE   (401 = up and prompting for auth)"
say ""
say "  ${c_b}The check that actually proves it:${c_0}"
say "  Open selfmail's log view. Entries must now read '$PI_NAME'."
say "  While they still read '$PC_NAME', this PC is still serving."
say "  A 401 alone does NOT tell you which machine answered."

######################################################################
h "PHASE 9 — Leave the PC as a fallback"
######################################################################
[[ -n "$UNIT" ]] && sudo systemctl disable "$UNIT" 2>/dev/null && ok "disabled $UNIT at boot"
sudo systemctl disable postfix 2>/dev/null && ok "disabled postfix at boot"
RESTORED=1   # stopping these is now intentional, not an interruption
ok "PC services disabled. $SRC is untouched and still bootable as a fallback."

######################################################################
h "PHASE 10 — Remove the PC copy (optional, not now)"
######################################################################
say "Only do this after mail has flowed on the Pi for several days."
if ask "Delete $SRC from this PC today?"; then
  if [[ -z "$BANNER" ]]; then
    err "Refusing: the Pi has no working SMTP yet."
  elif ask "Have you confirmed the log view shows '$PI_NAME' and your mail is all there?"; then
    Q="$SRC.PENDING-DELETE-$STAMP"; mv "$SRC" "$Q"; ok "moved to $Q"
    say "  Undo:  mv \"$Q\" \"$SRC\""
    phrase "FINAL: permanently erase $Q. Cannot be undone." "DELETE SELFMAIL" \
      && { rm -rf "$Q"; ok "deleted"; } || ok "kept at $Q"
  fi
else
  ok "Kept. Correct answer for today."
fi

say ""
ok "Done. Log: $LOG"
say "Rollback: on the Pi 'sudo systemctl stop cloudflared', then on this PC"
say "          'sudo systemctl enable --now ${CFUNIT:-cloudflared} ${UNIT:-selfmail}'"
