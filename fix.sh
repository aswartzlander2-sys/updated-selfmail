#!/usr/bin/env bash
# fix.sh — run this ON THE PI, as yourself (it calls sudo only where needed).
# Brings the Cloudflare Tunnel connector up on the Pi, checks postfix, and
# prints exactly which Cloudflare setting to change. Asks before every change.
set -uo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

SELF="${SELFMAIL_DIR:-$HOME/selfmail}"
PC_IP="${PC_IP:-10.20.32.150}"
PI_IP="${PI_IP:-10.20.31.124}"
HOSTNAME_FQDN="mailhook.robo-universe.com"
TUNNEL_ID=""; TUNNEL_TOKEN=""; SVC_TARGET=""; SVC_PORT=""

c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[1m'; c_0=$'\e[0m'
say(){ printf '%s\n' "$*"; }
h(){ printf '\n%s== %s ==%s\n' "$c_b" "$*" "$c_0"; }
ok(){ printf '%s-- %s%s\n' "$c_g" "$*" "$c_0"; }
warn(){ printf '%s!! %s%s\n' "$c_y" "$*" "$c_0"; }
err(){ printf '%s!! %s%s\n' "$c_r" "$*" "$c_0"; }
ask(){ local r; read -r -p "$(printf '%s?? %s [y/N]: %s' "$c_b" "$1" "$c_0")" r </dev/tty; [[ "$r" =~ ^[Yy]$ ]]; }

########################################
h "0. Safety — confirm a clean copy still exists"
########################################
ARCH_FILE="$(ls -1 "$HOME"/selfmail-*.tar.* 2>/dev/null | head -1)"
if [[ -n "$ARCH_FILE" ]]; then
  ok "Verified archive present: $ARCH_FILE ($(du -h "$ARCH_FILE" | cut -f1))"
  say "   Nothing below can lose your mail — this tarball is the fallback."
else
  warn "No selfmail-*.tar.* archive found in \$HOME."
  warn "Also check the PC for: ~/selfmail.PENDING-DELETE-*"
fi
[[ -d "$SELF" ]] && ok "selfmail present: $SELF ($(find "$SELF" -type f 2>/dev/null | wc -l) files)" \
                || { err "No $SELF — set SELFMAIL_DIR=/path and rerun."; exit 1; }

########################################
h "1. Work out how this tunnel is configured"
########################################
# Dashboard-managed tunnels authenticate with a long token; local ones use a JSON.
TUNNEL_TOKEN="$(grep -rhoE 'eyJ[A-Za-z0-9_=-]{40,}' "$SELF" 2>/dev/null | head -1)"
TUNNEL_ID="$(grep -rhoE '^[[:space:]]*tunnel:[[:space:]]*[0-9a-f-]{36}' "$SELF" 2>/dev/null | grep -oE '[0-9a-f-]{36}' | head -1)"
[[ -n "$TUNNEL_ID" ]] || TUNNEL_ID="$(find "$SELF" "$HOME/.cloudflared" -name '*.json' 2>/dev/null \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
CREDS="$(find "$SELF" "$HOME/.cloudflared" -name '*.json' 2>/dev/null | head -1)"

[[ -n "$TUNNEL_ID" ]]    && ok "Tunnel ID:    $TUNNEL_ID"    || warn "No tunnel ID found locally"
[[ -n "$TUNNEL_TOKEN" ]] && ok "Tunnel token: found (dashboard-managed)" || say "No token found (likely locally-managed)"
[[ -n "$CREDS" ]]        && ok "Credentials:  $CREDS"

# What local address should the tunnel forward to?
SVC_TARGET="$(grep -rhoE 'service:[[:space:]]*https?://[^[:space:]]+' "$SELF" --include='*.yml' --include='*.yaml' 2>/dev/null | head -1 | awk '{print $2}')"
[[ -n "$SVC_TARGET" ]] && say "Ingress service target in config: $SVC_TARGET"
SVC_PORT="$(printf '%s' "${SVC_TARGET:-}" | grep -oE ':[0-9]+' | tr -d ':')"
if [[ -z "$SVC_PORT" ]]; then
  say "Ports selfmail is listening on right now:"
  ss -tlnp 2>/dev/null | grep -viE ':(22|53)\b' | awk 'NR>1{print "   "$4}' | head -10
  SVC_PORT="$(ss -tlnp 2>/dev/null | grep -oE '127.0.0.1:[0-9]+|0.0.0.0:[0-9]+' | grep -oE '[0-9]+$' | grep -vE '^(22|53)$' | head -1)"
fi
[[ -n "$SVC_PORT" ]] && ok "selfmail port looks like: $SVC_PORT" || warn "Could not determine selfmail's port"

########################################
h "2. Install cloudflared (ARM64) if missing"
########################################
if command -v cloudflared >/dev/null; then
  ok "cloudflared installed: $(cloudflared --version 2>&1 | head -1)"
else
  warn "cloudflared NOT installed — this alone causes Error 1033."
  if ask "Install the official ARM64 cloudflared .deb now?"; then
    curl -fL --max-time 120 \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb \
      -o /tmp/cloudflared.deb && sudo dpkg -i /tmp/cloudflared.deb && ok "Installed" \
      || { err "Install failed — check network/arch."; exit 1; }
  else
    say "Skipped. The tunnel cannot come up without it."
  fi
fi

########################################
h "3. Start the connector on the Pi"
########################################
if systemctl is-active --quiet cloudflared 2>/dev/null; then
  ok "cloudflared service already running"
elif command -v cloudflared >/dev/null; then
  warn "Connector is not running on this Pi — this is what Error 1033 means."
  if [[ -n "$TUNNEL_TOKEN" ]] && ask "Install the tunnel as a service using the token from selfmail?"; then
    sudo cloudflared service install "$TUNNEL_TOKEN" && ok "Service installed"
    sudo systemctl enable --now cloudflared 2>/dev/null
  elif [[ -n "$CREDS" && -n "$TUNNEL_ID" ]] && ask "Set up from the credentials file instead?"; then
    sudo mkdir -p /etc/cloudflared
    sudo cp "$CREDS" /etc/cloudflared/
    printf 'tunnel: %s\ncredentials-file: /etc/cloudflared/%s\ningress:\n  - hostname: %s\n    service: http://localhost:%s\n  - service: http_status:404\n' \
      "$TUNNEL_ID" "$(basename "$CREDS")" "$HOSTNAME_FQDN" "${SVC_PORT:-8080}" \
      | sudo tee /etc/cloudflared/config.yml >/dev/null
    ok "Wrote /etc/cloudflared/config.yml pointing at localhost:${SVC_PORT:-8080}"
    sudo cloudflared service install 2>/dev/null
    sudo systemctl enable --now cloudflared
  else
    warn "No token or credentials found — you'll need the token from the dashboard:"
    say "   Zero Trust -> Networks -> Tunnels -> your tunnel -> Configure -> copy token"
    say "   then: sudo cloudflared service install <TOKEN>"
  fi
fi
sleep 3
systemctl is-active --quiet cloudflared 2>/dev/null && ok "Connector is UP" || warn "Connector still down — see: sudo journalctl -u cloudflared -n 30"

########################################
h "4. Postfix — what actually broke"
########################################
if systemctl list-unit-files 2>/dev/null | grep -q '^postfix'; then
  systemctl is-active --quiet postfix && ok "postfix running" || err "postfix NOT running"
  say "-- last errors:"
  sudo journalctl -u postfix --no-pager -n 15 2>/dev/null | tail -15
  say "-- config check:"
  sudo postfix check 2>&1 | head -10
else
  say "postfix not installed on this Pi."
fi
say "-- who holds the mail ports:"
sudo ss -tlnp 2>/dev/null | grep -E ':(25|465|587|993)\b' || say "   nothing on mail ports"
warn "Two MTAs cannot both bind :25. If selfmail ships its own, that is the clash."

########################################
h "5. WHAT TO CHANGE IN CLOUDFLARE"
########################################
say "Public DNS for $HOSTNAME_FQDN currently returns Cloudflare proxy IPs,"
say "so the real origin is hidden behind the orange cloud. Open the DNS tab"
say "and read the CONTENT field of the 'mailhook' record, then:"
say ""
say "${c_b}CASE A — content ends in .cfargotunnel.com${c_0}"
say "  Leave DNS alone. It routes by tunnel ID, which did not change."
say "  Fix instead:  Zero Trust -> Networks -> Tunnels -> $HOSTNAME_FQDN"
say "                -> Public Hostname -> Service"
if [[ -n "${SVC_TARGET:-}" ]] && printf '%s' "$SVC_TARGET" | grep -q "$PC_IP"; then
  err "  >> Your config points at $PC_IP (the PC). CHANGE IT TO:"
  say "     http://localhost:${SVC_PORT:-<port>}"
else
  say "  If Service reads http://$PC_IP:<port>  (the PC)"
  say "  change it to     http://localhost:${SVC_PORT:-<port>}"
fi
say ""
say "${c_b}CASE B — content is an IP address${c_0}"
say "  That IP is the one to change."
say "  * Pi behind the SAME Google Fiber line as the PC -> the public IP is"
say "    identical, so the record stays. Change the ROUTER PORT-FORWARD"
say "    from $PC_IP to $PI_IP instead."
say "  * Pi on a different connection -> set content to the new public IP."
say "  A private 10.20.x.x address can never be the content of a public record."
say ""
say "${c_b}NOT changing, either way:${c_0}"
say "  MX  robo-universe.com -> route1/2/3.mx.cloudflare.net  (Email Routing)"
say "  TXT v=spf1 include:_spf.mx.cloudflare.net ~all"
say "  Inbound mail goes to Cloudflare Email Routing, never to the Pi's IP."
say ""
ok "Done. If the connector is UP and Service points at localhost, 1033 clears."
