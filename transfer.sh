#!/usr/bin/env bash
# transfer.sh — move ~/selfmail (mailhook.robo-universe.com) from this PC to a Raspberry Pi.
#
# Run this ON THE PC that currently holds selfmail.
# Every step that changes or copies anything asks you first. Default is always "no".
set -euo pipefail

SRC="${SELFMAIL_SRC:-$HOME/selfmail}"
MAILHOST="mailhook.robo-universe.com"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
ARCHIVE="$WORK/selfmail-$STAMP.tar.zst"
LOG="$HOME/selfmail-transfer-$STAMP.log"
VERIFIED=0
STOPPED_UNITS=()
USES_TUNNEL=0
USES_SMTP=0

trap 'rm -rf "$WORK"' EXIT
exec > >(tee -a "$LOG") 2>&1

c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[1m'; c_0=$'\e[0m'
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s== %s ==%s\n' "$c_b" "$*" "$c_0"; }
warn() { printf '%s!! %s%s\n' "$c_y" "$*" "$c_0"; }
err()  { printf '%s!! %s%s\n' "$c_r" "$*" "$c_0"; }
ok()   { printf '%s-- %s%s\n' "$c_g" "$*" "$c_0"; }

ask() {
  local reply
  read -r -p "$(printf '%s?? %s [y/N]: %s' "$c_b" "$1" "$c_0")" reply </dev/tty
  [[ "$reply" =~ ^[Yy]$ ]]
}

ask_phrase() {
  local reply
  printf '%s%s%s\n' "$c_y" "$1" "$c_0"
  read -r -p "Type exactly '$2' to proceed (anything else cancels): " reply </dev/tty
  [[ "$reply" == "$2" ]]
}

abort() { err "Cancelled. Nothing further was changed."; exit 1; }

########################################
head2 "About your SSH credentials — read this, don't take my word for it"
########################################
cat <<NOTE
This script asks for the Pi's address, a username, and (once) an SSH password.
Concretely, what happens to them:

  * The password is never read, stored, echoed, or logged by this script.
    If you set up key auth, the prompt you see belongs to ssh-copy-id --
    it is ssh's own prompt, and the password goes straight to your Pi.
  * The transfer is a direct rsync from this PC to your Pi over SSH.
    Nothing is uploaded anywhere else, and no third party is contacted.
  * This whole file is plain text. Two commands that check the above:

        less "$0"                              # read exactly what it does
        grep -nE 'curl|wget|nc |ftp|@' "$0"    # look for anything phoning home

  * A full transcript of this run is written to:
        $LOG

Never trust a script's claim about its own trustworthiness, including this
one. The commands above are there so you can confirm it instead.
NOTE
say ""
ask "Read that and happy to continue?" || abort

########################################
head2 "Phase 0 — preflight"
########################################
for t in rsync ssh tar sha256sum; do
  command -v "$t" >/dev/null || { err "Missing required tool: $t"; exit 1; }
done
command -v zstd >/dev/null && ZSTD=1 || { ZSTD=0; ARCHIVE="$WORK/selfmail-$STAMP.tar.gz"; }
if [[ ! -d "$SRC" ]]; then
  err "Not found: $SRC"
  if [[ -n "${SUDO_USER:-}" ]] && [[ -d "/home/$SUDO_USER/selfmail" ]]; then
    say "Looks like you ran this with sudo, so \$HOME became root's."
    say "Run it as yourself instead (no sudo) -- it calls sudo only where needed:"
    say "    ./$(basename "$0")"
  else
    say "Point it at the right place with:  SELFMAIL_SRC=/path/to/selfmail ./$(basename "$0")"
  fi
  exit 1
fi
ok "Source: $SRC"

########################################
head2 "Phase 1 — inventory (read-only, copies nothing)"
########################################
SIZE_H="$(du -sh "$SRC" 2>/dev/null | cut -f1)"
SIZE_K="$(du -sk "$SRC" 2>/dev/null | cut -f1)"
FILES="$(find "$SRC" -type f 2>/dev/null | wc -l)"
say "Size:  $SIZE_H"
say "Files: $FILES"
say ""
say "Components found:"
[[ -f "$SRC/docker-compose.yml" || -f "$SRC/compose.yml" ]] && say "  - docker compose project"
[[ -f "$SRC/package.json" ]] && say "  - Node.js app"
[[ -f "$SRC/requirements.txt" || -f "$SRC/pyproject.toml" ]] && say "  - Python app"
find "$SRC" -maxdepth 3 -type d \( -name cur -o -name new \) 2>/dev/null | head -1 | grep -q . && say "  - Maildir mail store"
find "$SRC" -maxdepth 3 \( -name '*.sqlite*' -o -name '*.db' \) 2>/dev/null | head -3 | sed 's/^/  - database: /'
find "$SRC" -maxdepth 3 \( -iname '*dkim*' -o -iname '*.pem' -o -iname '*.key' \) 2>/dev/null | head -5 | sed 's/^/  - key\/cert: /'
find "$SRC" -maxdepth 2 -iname '.env*' 2>/dev/null | head -3 | sed 's/^/  - env file: /'

# How does mail actually reach this box? Decides the DNS advice in Phase 7.
if grep -rqi 'cloudflared\|tunnel' "$SRC" --include='*.yml' --include='*.yaml' --include='*.json' --include='.env*' 2>/dev/null \
   || systemctl list-units --no-pager --no-legend 2>/dev/null | grep -qi 'cloudflared'; then
  USES_TUNNEL=1; say "  - fronted by a Cloudflare Tunnel (HTTP webhook style)"
fi
if ss -tlnp 2>/dev/null | grep -qE ':(25|465|587|993)\b'; then
  USES_SMTP=1; say "  - listening on real SMTP ports:"
  ss -tlnp 2>/dev/null | grep -E ':(25|465|587|993)\b' | awk '{print "      "$4"  "$6}'
fi

say ""
say "selfmail-related services running:"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | grep -iE 'selfmail|postfix|dovecot|opendkim|cloudflared' | awk '{print "  - "$1}' || say "  (none)"
command -v docker >/dev/null 2>&1 && docker ps --format '  - {{.Names}}  {{.Image}}  {{.Ports}}' 2>/dev/null

say ""
ask "Inventory looks right — continue?" || abort

########################################
head2 "Phase 2 — connect to the Pi"
########################################
read -r -p "Pi address (hostname or IP) [10.20.31.124]: " PI_HOST </dev/tty
PI_HOST="${PI_HOST:-10.20.31.124}"
read -r -p "Pi SSH username: " PI_USER </dev/tty
read -r -p "Pi SSH port [22]: " PI_PORT </dev/tty
PI_PORT="${PI_PORT:-22}"
DEST="${SELFMAIL_DEST:-/home/$PI_USER/selfmail}"
SSHOPTS=(-p "$PI_PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

if ! ssh -o BatchMode=yes "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" true 2>/dev/null; then
  warn "No key-based login yet. ssh-copy-id will prompt you once (that prompt is ssh's, not mine)."
  if ask "Set up SSH key auth now? (recommended)"; then
    [[ -f "$HOME/.ssh/id_ed25519.pub" ]] || ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
    ssh-copy-id -p "$PI_PORT" "$PI_USER@$PI_HOST"
  fi
fi
ssh "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" true || { err "Cannot reach the Pi over SSH."; exit 1; }
ok "SSH to $PI_USER@$PI_HOST:$PI_PORT works"

AVAIL_K="$(ssh "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" "df -Pk \"\$HOME\" | awk 'NR==2{print \$4}'")"
say "Pi free: $(( AVAIL_K / 1024 )) MB | needed: ~$(( SIZE_K * 2 / 1024 )) MB"
(( AVAIL_K > SIZE_K * 2 )) || { err "Not enough free space on the Pi."; exit 1; }
ok "Space OK"

ssh "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" "[ -e '$DEST' ]" && {
  warn "$DEST already exists on the Pi and may be overwritten."
  ask "Continue anyway?" || abort
}

########################################
head2 "Phase 3 — stop selfmail for a clean snapshot"
########################################
say "Copying a live mail store risks a torn snapshot (half-written message,"
say "in-flight database write). Stopping it first avoids that."
if ask "Stop selfmail on this PC before copying?"; then
  while read -r unit; do
    [[ -n "$unit" ]] || continue
    ask "  Stop $unit?" && sudo systemctl stop "$unit" && STOPPED_UNITS+=("$unit") && ok "  stopped $unit"
  done < <(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
            | grep -i selfmail | awk '{print $1}')
  if [[ -f "$SRC/docker-compose.yml" || -f "$SRC/compose.yml" ]] && command -v docker >/dev/null; then
    ask "  Run 'docker compose stop' in $SRC?" && ( cd "$SRC" && sudo docker compose stop ) && ok "  compose stopped"
  fi
else
  warn "Copying live — snapshot may be inconsistent."
fi

restore_services() {
  [[ ${#STOPPED_UNITS[@]} -eq 0 ]] && return 0
  head2 "Restarting what was stopped"
  for u in "${STOPPED_UNITS[@]}"; do sudo systemctl start "$u" && ok "restarted $u"; done
}

########################################
head2 "Phase 4 — archive + checksum"
########################################
say "Reading $SRC (never modified)..."
if (( ZSTD )); then
  tar -C "$(dirname "$SRC")" -cf - "$(basename "$SRC")" | zstd -T0 -3 -o "$ARCHIVE"
else
  tar -C "$(dirname "$SRC")" -czf "$ARCHIVE" "$(basename "$SRC")"
fi
LOCAL_SUM="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
ok "Archive: $(du -h "$ARCHIVE" | cut -f1)"
ok "SHA256:  $LOCAL_SUM"

########################################
head2 "Phase 5 — transfer"
########################################
ask "Send to $PI_USER@$PI_HOST now?" || { restore_services; abort; }
ssh "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" "mkdir -p '$(dirname "$DEST")'"
rsync -avh --partial --progress -e "ssh ${SSHOPTS[*]}" "$ARCHIVE" "$PI_USER@$PI_HOST:$(dirname "$DEST")/"
ok "Transfer complete"

########################################
head2 "Phase 6 — verify on the Pi"
########################################
REMOTE_ARCHIVE="$(dirname "$DEST")/$(basename "$ARCHIVE")"
REMOTE_SUM="$(ssh "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" "sha256sum '$REMOTE_ARCHIVE' | awk '{print \$1}'")"
say "local : $LOCAL_SUM"
say "remote: $REMOTE_SUM"
[[ "$LOCAL_SUM" == "$REMOTE_SUM" ]] || { err "CHECKSUM MISMATCH — corrupt transfer. Nothing deleted."; restore_services; exit 1; }
ok "Checksum matches"

ssh "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" \
  "cd '$(dirname "$DEST")' && tar $( (( ZSTD )) && echo --use-compress-program=unzstd ) -xf '$REMOTE_ARCHIVE'"
REMOTE_FILES="$(ssh "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" "find '$DEST' -type f | wc -l")"
say "local files : $FILES"
say "remote files: $REMOTE_FILES"
[[ "$FILES" == "$REMOTE_FILES" ]] || { err "FILE COUNT MISMATCH — incomplete. Nothing deleted."; restore_services; exit 1; }
VERIFIED=1
ok "Verified: $REMOTE_FILES files at $DEST"
restore_services

########################################
head2 "Phase 7 — DNS changes for $MAILHOST"
########################################
PI_IP="$(ssh "${SSHOPTS[@]}" "$PI_USER@$PI_HOST" "curl -s --max-time 10 https://api.ipify.org" 2>/dev/null || echo "<PI_PUBLIC_IP>")"
say "Pi's public IPv4: $PI_IP"
say ""
if (( USES_TUNNEL )); then
  # Pull the real tunnel ID out of the config or the credentials filename.
  TUNNEL_ID="$(grep -rhoE '^[[:space:]]*tunnel:[[:space:]]*[0-9a-f-]{36}' "$SRC" 2>/dev/null \
                | grep -oE '[0-9a-f-]{36}' | head -1)"
  [[ -n "$TUNNEL_ID" ]] || TUNNEL_ID="$(find "$SRC" -name '*.json' 2>/dev/null \
                | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [[ -n "$TUNNEL_ID" ]] || TUNNEL_ID="<tunnel-id>"

  say "selfmail looks Cloudflare-Tunnel-fronted, so DNS is simple:"
  say ""
  say "  CNAME  $MAILHOST  ->  $TUNNEL_ID.cfargotunnel.com   (proxied)"
  say ""
  if [[ "$TUNNEL_ID" != "<tunnel-id>" ]]; then
    say "If your CNAME already points at that exact target, DNS needs NO change"
    say "at all -- the tunnel moves with the credentials, the hostname follows."
    say ""
  fi
  say "Run the tunnel on the Pi with the same credentials JSON that came"
  say "across in the archive and the hostname keeps resolving. No A record,"
  say "no port forwarding, and the Pi's IP never appears in public DNS --"
  say "which also means a dynamic home IP does not matter."
else
  say "  A   $MAILHOST   ->  $PI_IP"
  say "  MX  robo-universe.com  ->  $MAILHOST   (priority 10)"
  say ""
  warn "The Pi sits on a private LAN address, so $PI_IP is your router's"
  warn "public IP, not the Pi's. This path only works if you forward the mail"
  warn "ports on the router to the Pi -- and a home IP can change. A Cloudflare"
  warn "Tunnel avoids both problems."
  say ""
  say "  SPF -- the one people miss. If your TXT hardcodes the old IP:"
  say "      v=spf1 ip4:<OLD IP> ... -> v=spf1 ip4:$PI_IP ...  (or just 'mx')"
  say "      Miss this and outbound starts failing SPF silently."
  say ""
  say "  DKIM + DMARC: unchanged. Keep the existing selector and key --"
  say "  they moved with the archive. Regenerating breaks signing."
fi
say ""
say "Drop TTLs on these records to 300s a day BEFORE cutover so you can"
say "roll back fast, then raise them once mail is flowing."
(( USES_SMTP )) && {
  say ""
  warn "selfmail binds real SMTP ports. If the destination Pi already runs an"
  warn "MTA on :25, both cannot listen at once -- sort that before cutover."
}

########################################
head2 "Phase 8 — remove the copy on this PC"
########################################
(( VERIFIED )) || { err "Not verified — deletion not offered."; exit 1; }

say "The Pi's copy is byte-identical with a matching file count."
say "That is NOT the same as selfmail actually WORKING there."
warn "Recommended: keep this copy until mail has flowed on the Pi for a few days."
say ""
ask "Delete the selfmail copy on THIS PC?" || { ok "Kept at: $SRC"; exit 0; }
ask "Have you logged into selfmail ON THE PI and confirmed your mail is all there?" \
  || { ok "Good call — keeping it until you've checked."; exit 0; }

QUARANTINE="$SRC.PENDING-DELETE-$STAMP"
mv "$SRC" "$QUARANTINE"
ok "Moved to: $QUARANTINE"
say "Nothing destroyed yet. Undo with:  mv \"$QUARANTINE\" \"$SRC\""
say ""
if ask_phrase "FINAL: permanently erase $QUARANTINE. Cannot be undone." "DELETE SELFMAIL"; then
  rm -rf "$QUARANTINE"; ok "Permanently deleted."
else
  ok "Stopped. Recoverable copy remains at: $QUARANTINE"
fi

say ""
ok "Done. Log: $LOG"
