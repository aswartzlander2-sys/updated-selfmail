#!/usr/bin/env bash
# selfmail-doctor.sh — diagnose AND repair selfmail/postfix on the Pi.
#
#   sudo bash selfmail-doctor.sh                 # diagnose, then repair
#   sudo bash selfmail-doctor.sh --diagnose-only # look, change nothing
#
# Output is safe to paste: tokens, passwords and keys are redacted.
#
# Known state this was built against (verified live, 2026-09-13):
#   * Inbound mail arrives by ForwardEmail WEBHOOK, not SMTP. Inbox works
#     even with postfix dead. Postfix only affects OUTBOUND.
#   * All 7 DNS records pass (allGood:true). DNS is NOT the problem.
#   * /api/status hangs >25s because a status probe reads 127.0.0.1:25 and
#     the socket accepts TCP but never sends a 220 banner. That blank
#     Status tab is this hang, nothing else.
#   * Every probe below is timeout-guarded so this script cannot hang too.
export PATH="$PATH:/usr/sbin:/sbin"
export LC_ALL=C
DIAGNOSE_ONLY=0; [[ "${1:-}" == "--diagnose-only" ]] && DIAGNOSE_ONLY=1

MYHOST="${MYHOST:-mail.robo-universe.com}"
SELF="${SELFMAIL_DIR:-/home/${SUDO_USER:-$USER}/selfmail}"
BK="/root/selfmail-doctor-$(date +%Y%m%d-%H%M%S)"
PROBLEMS=(); FIXED=()

c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[1m'; c_0=$'\e[0m'
say(){ printf '%s\n' "$*"; }
s(){ printf '\n\n%s########## %s ##########%s\n' "$c_b" "$*" "$c_0"; }
t(){ printf '\n--- %s ---\n' "$*"; }
ok(){ printf '  %s[OK]%s %s\n' "$c_g" "$c_0" "$*"; }
prob(){ PROBLEMS+=("$*"); printf '  %s[PROBLEM]%s %s\n' "$c_r" "$c_0" "$*"; }
warn(){ printf '  %s[WARN]%s %s\n' "$c_y" "$c_0" "$*"; }
did(){ FIXED+=("$*"); printf '  %s[FIXED]%s %s\n' "$c_g" "$c_0" "$*"; }

redact(){ sed -E \
  -e 's/(eyJ[A-Za-z0-9_-]{8})[A-Za-z0-9_=.-]+/\1<REDACTED-TOKEN>/g' \
  -e 's#(/inbound/)[A-Za-z0-9]{8}[A-Za-z0-9]*#\1<REDACTED-WEBHOOK-SECRET>#g' \
  -e 's/(pass(word)?|secret|token|apikey|auth)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\3<REDACTED>/Ig' \
  -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/<REDACTED-PRIVATE-KEY>/g'; }

# Every SMTP probe is wrapped: the bug under investigation is a hang.
banner(){ timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/25 && head -1 <&3' 2>/dev/null; }

{
[[ $EUID -eq 0 ]] || { printf '%sRun with sudo: sudo bash %s%s\n' "$c_r" "$0" "$c_0"; exit 1; }

s "0. HOST"
say "  $(date)  |  $(hostname)  |  $(uname -m)"
. /etc/os-release 2>/dev/null && say "  $PRETTY_NAME"
say "  NOTE: Pi is ARM64, source PC was x86 — compiled .db maps are NOT portable."

######################################################################
s "1. DIAGNOSE — postfix"
######################################################################
if ! dpkg -l postfix 2>/dev/null | grep -q '^ii'; then
  prob "postfix package NOT installed"
else
  ok "postfix $(postconf -h mail_version 2>/dev/null)"
fi
say "  service: $(systemctl is-active postfix 2>/dev/null) / $(systemctl is-enabled postfix 2>/dev/null)"

t "fatal errors in journal"
journalctl -u postfix --no-pager -n 80 2>/dev/null | grep -iE 'fatal|panic' | tail -8 \
  || say "  (none)"

t "port 25 — is it bound, and does it greet?"
if ss -lntp 2>/dev/null | grep -q ':25 '; then
  ss -lntp 2>/dev/null | grep ':25 ' | sed 's/^/  /'
  B="$(banner)"
  if [[ -n "$B" ]]; then ok "banner: $B"
  else prob "port 25 is BOUND but sends NO banner — this is what hangs /api/status"; fi
else
  prob "nothing listening on 127.0.0.1:25 (postfix master not running)"
fi

t "showq socket (postqueue depends on it)"
ls -l /var/spool/postfix/public/showq 2>/dev/null | sed 's/^/  /' || prob "showq socket missing"
timeout 6 postqueue -p 2>&1 | head -3 | sed 's/^/  /'

t "config"
postconf -n 2>/dev/null | grep -E 'myhostname|myorigin|inet_interfaces|inet_protocols|relay|virtual|alias' | sed 's/^/  /'
timeout 10 postfix check 2>&1 | head -10 | sed 's/^/  /'

t "files referenced outside /etc/postfix"
for f in /etc/mailname /etc/aliases /etc/aliases.db; do
  [[ -e "$f" ]] && ok "$f" || prob "MISSING $f"
done

t "map databases (x86 -> ARM64)"
while read -r m; do
  [[ -n "$m" ]] || continue
  f="${m#*:}"
  if   [[ ! -f "$f" ]];      then prob "map source missing: $f"
  elif [[ ! -f "$f.db" ]];   then prob "$f has no .db (needs postmap)"
  elif [[ "$f" -nt "$f.db" ]]; then prob "$f.db is stale (needs postmap)"
  else ok "$f.db current"; fi
done < <(postconf -n 2>/dev/null | grep -oE '(hash|btree|lmdb|dbm):[^,[:space:]]+' | sort -u)

t "users, groups, spool permissions"
for u in postfix vmail opendkim; do id "$u" &>/dev/null && ok "user $u" || warn "user $u missing"; done
getent group postdrop >/dev/null && ok "group postdrop" || prob "group postdrop missing"
ls -ld /var/spool/postfix /var/spool/postfix/{public,maildrop,pid} 2>/dev/null | sed 's/^/  /'
say "  (maildrop+public must be group 'postdrop' — a blanket chown -R breaks postqueue)"

######################################################################
s "2. DIAGNOSE — selfmail, opendkim, tunnel"
######################################################################
t "selfmail process"
pgrep -af 'node|selfmail' 2>/dev/null | head -5 | sed 's/^/  /' || prob "no selfmail/node process"
SMPORT="$(ss -lntp 2>/dev/null | grep -i node | grep -oE ':[0-9]+' | tr -d ':' | head -1)"
[[ -n "$SMPORT" ]] && ok "selfmail listening on :$SMPORT" || warn "could not detect selfmail port"

t "does /api/status hang? (the reported symptom)"
if [[ -n "$SMPORT" ]]; then
  RC="$(timeout 20 curl -s -o /dev/null -w '%{http_code}/%{time_total}s' "http://127.0.0.1:$SMPORT/api/status" 2>/dev/null)"
  case "$RC" in
    200*) ok "/api/status -> $RC" ;;
    ""|000*) prob "/api/status HANGS locally ($RC) — Status tab will render blank" ;;
    *) warn "/api/status -> $RC" ;;
  esac
fi

t "opendkim"
say "  $(systemctl is-active opendkim 2>/dev/null)"
postconf -n 2>/dev/null | grep -i milter | sed 's/^/  /' || say "  no milter config"

t "cloudflared"
say "  $(systemctl is-active cloudflared 2>/dev/null)"
command -v cloudflared >/dev/null && cloudflared --version 2>&1 | head -1 | sed 's/^/  /'

t "DNS (verified all-7-pass on 2026-09-13 — do not edit records)"
say "  inbound path is a ForwardEmail webhook, NOT smtp; postfix is outbound only"

if (( DIAGNOSE_ONLY )); then
  s "DIAGNOSE-ONLY — stopping before any change"
  printf '  %d problem(s)\n' "${#PROBLEMS[@]}"; printf '   - %s\n' "${PROBLEMS[@]}"
  exit 0
fi

######################################################################
s "3. REPAIR"
######################################################################
mkdir -p "$BK"
cp -a /etc/postfix "$BK/" 2>/dev/null
cp -a /etc/mailname /etc/aliases "$BK/" 2>/dev/null
ok "backup: $BK"
say "  rollback: cp -a $BK/postfix/. /etc/postfix/ && postfix set-permissions && systemctl restart postfix"

t "stop cleanly, clear any half-started master"
systemctl stop postfix 2>/dev/null
timeout 10 postfix stop 2>/dev/null
pkill -9 -f 'postfix/master' 2>/dev/null && did "killed stale master process"
rm -f /var/spool/postfix/pid/master.pid && did "removed stale master.pid"

t "files outside /etc/postfix"
[[ -f /etc/mailname ]] || { echo "$MYHOST" > /etc/mailname; did "created /etc/mailname=$MYHOST"; }
[[ -f /etc/aliases ]] || { printf 'postmaster: root\nroot: postmaster\n' > /etc/aliases; did "created /etc/aliases"; }
newaliases 2>/dev/null && did "rebuilt alias database"

t "rebuild every map on this architecture"
while read -r m; do
  [[ -n "$m" ]] || continue
  f="${m#*:}"; [[ -f "$f" ]] || continue
  postmap "$m" 2>/dev/null && did "postmap $m"
done < <(postconf -n 2>/dev/null | grep -oE '(hash|btree|lmdb|dbm):[^,[:space:]]+' | sort -u)

t "permissions"
# set-permissions IS the authoritative fix. Never chown -R afterwards:
# maildrop/public need group postdrop, and a recursive chown breaks
# postqueue/postdrop — which is what blanked the Status tab before.
postfix set-permissions 2>/dev/null && did "postfix set-permissions (restores correct ownership)"

t "relay-mode config"
postconf -e "myhostname = $MYHOST"
postconf -e "myorigin = /etc/mailname"
postconf -e "inet_interfaces = loopback-only"
postconf -e "inet_protocols = ipv4"
did "bound loopback-only on 127.0.0.1:25"
say "  127.0.0.1 is CORRECT — selfmail runs on this same Pi. Do not repoint it."

t "start"
timeout 15 postfix check 2>&1 | head -6 | sed 's/^/  /'
systemctl start postfix 2>/dev/null
sleep 3
systemctl is-active --quiet postfix && did "postfix started" || prob "postfix failed to start"

######################################################################
s "4. VERIFY"
######################################################################
if ss -lntp 2>/dev/null | grep -q ':25 '; then
  ok "listening on :25"
  B="$(banner)"
  [[ -n "$B" ]] && ok "SMTP banner: $B" || prob "still bound with NO banner — /api/status will keep hanging"
else
  prob "still nothing on :25"
fi
timeout 8 postqueue -p 2>&1 | head -3 | sed 's/^/  /'
if [[ -n "${SMPORT:-}" ]]; then
  RC="$(timeout 25 curl -s -o /dev/null -w '%{http_code}/%{time_total}s' "http://127.0.0.1:$SMPORT/api/status" 2>/dev/null)"
  [[ "$RC" == 200* ]] && ok "/api/status -> $RC  (Status tab will load)" \
                      || prob "/api/status still not healthy ($RC)"
fi

s "5. SUMMARY"
printf '  fixed:    %d\n' "${#FIXED[@]}";    ((${#FIXED[@]}))    && printf '   + %s\n' "${FIXED[@]}"
printf '  problems: %d\n' "${#PROBLEMS[@]}"; ((${#PROBLEMS[@]})) && printf '   - %s\n' "${PROBLEMS[@]}"
say ""
say "  Then hit Refresh on selfmail's Status tab."
say "  If problems remain, paste this ENTIRE output back (already redacted)."
} 2>&1 | redact
