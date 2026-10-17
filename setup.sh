#!/usr/bin/env bash
#
# selfmail installer
#
# Sets up Postfix + OpenDKIM + the selfmail web UI on a Linux host.
# Designed for machines that cannot receive on port 25 (home servers behind
# NAT), which is why "relay" mode exists alongside classic direct delivery.
#
# Usage:  sudo ./setup.sh
#
set -euo pipefail

APP_NAME="selfmail"
APP_USER="selfmail"
APP_DIR="/opt/selfmail"
CFG_DIR="/etc/selfmail"
CFG_FILE="$CFG_DIR/config.json"
ENV_FILE="$CFG_DIR/env"
MAILROOT="/var/mail/vhosts"
PORT_DEFAULT=8088
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- output --
if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; Z=$'\e[0m'
else
  B=""; G=""; Y=""; R=""; C=""; Z=""
fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$C" "$Z" "$B" "$*" "$Z"; }
ok()   { printf '  %s+%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '\n%sError:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo:  sudo ./setup.sh"


# Another MTA holding port 25 makes Postfix fail with
#   fatal: bind 0.0.0.0 port 25: Address already in use
# and the failure is quiet: on Debian/Ubuntu `systemctl is-active postfix`
# still reports "active" because postfix.service is only a wrapper. The other
# server then answers mail with its own policy, typically "Relay access denied".
# A Docker container publishing port 25 (another mail server tried earlier)
# blocks Postfix from binding. Stop it and turn off its restart policy.
clear_docker_25() {
  command -v docker >/dev/null 2>&1 || return 0
  local owner
  owner="$(ss -lntp 2>/dev/null | awk '$4 ~ /:25$/' | grep -oE '"[^"]+"' | head -1 | tr -d '"')"
  [ "$owner" = docker-proxy ] || return 0
  docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E ':25->' | cut -f1,2 \
  | while IFS="$(printf '\t')" read -r cid cname; do
      [ -z "$cid" ] && continue
      warn "Docker container $cname publishes port 25 - stopping it"
      docker update --restart=no "$cid" >/dev/null 2>&1 || true
      docker stop "$cid" >/dev/null 2>&1 || true
    done
  sleep 2
}

clear_port25() {
  local m stopped=0
  for m in exim4 exim sendmail nullmailer opensmtpd citadel; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${m}\.service"; then
      if systemctl is-active --quiet "$m" 2>/dev/null; then
        warn "$m is running and owns port 25 - stopping and disabling it"
        systemctl stop "$m" 2>/dev/null || true
        systemctl disable "$m" >/dev/null 2>&1 || true
        stopped=1
      fi
    fi
  done
  [ "$stopped" = 1 ] && sleep 2
  return 0
}

# Postfix reports success even when the master died, so confirm for real.
postfix_really_running() {
  postfix status >/dev/null 2>&1
}

# `postfix status` only proves the master is alive. Sending needs smtpd to
# actually greet, which fails separately - and silently. Prints the banner;
# returns 0 greeting, 1 nothing listening, 2 connected but no greeting.
smtp_probe() {
  local out rc
  out="$(timeout 8 bash -c '
    exec 3<>/dev/tcp/127.0.0.1/25 2>/dev/null || exit 1
    IFS= read -r -t 6 l <&3 || exit 2
    printf "%s" "$l"' 2>/dev/null)"
  rc=$?
  printf '%s' "${out//$'\r'/}"
  return $rc
}

# Shared by setup.sh and update.sh so both installs and upgrades are checked
# the same way. Returns non-zero when the send path would not work.
report_smtp() {
  local banner rc
  banner="$(smtp_probe)"; rc=$?
  case "$rc" in
    0)
      case "$banner" in
        220*) ok "smtpd greets on 127.0.0.1:25 - $banner"; return 0 ;;
        *)    warn "port 25 answered with something that is not SMTP: $banner" ;;
      esac
      ;;
    1) warn "nothing is listening on 127.0.0.1:25 - postfix is not running" ;;
    *)
      warn "port 25 accepted the connection but sent no greeting"
      warn "that is exactly what makes the web UI report \"Greeting never received\""
      warn "smtpd consults the OpenDKIM milter before it greets - check:"
      warn "  systemctl status opendkim ; journalctl -u opendkim -n 30"
      ;;
  esac
  echo "  Holding port 25 right now:"
  ss -lntp 2>/dev/null | awk 'NR==1 || $4 ~ /:25$/' | sed 's/^/    /'
  return 1
}

# ------------------------------------------------------------ platform ----
step "Checking platform"
PM=""
if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
else die "no supported package manager found (need apt, dnf or yum)"
fi
command -v systemctl >/dev/null 2>&1 || die "systemd is required"
. /etc/os-release 2>/dev/null || true
ok "${PRETTY_NAME:-unknown Linux} using $PM"

MAILLOG=/var/log/mail.log
[ "$PM" = apt ] || MAILLOG=/var/log/maillog

# -------------------------------------------------------------- prompts ---
step "Configuration"
say "  Answer a few questions. Press Enter to accept the [default]."
say ""

# Reads from the terminal when there is one, otherwise from stdin, so the
# installer can also be driven from a here-doc for unattended installs.
INTERACTIVE=0
[ -t 0 ] && [ -e /dev/tty ] && INTERACTIVE=1

ask() { # ask VAR "prompt" "default"
  local __v="$1" __p="$2" __d="${3:-}" __in=""
  if [ -n "$__d" ]; then printf '  %s [%s]: ' "$__p" "$__d"; else printf '  %s: ' "$__p"; fi
  if [ "$INTERACTIVE" = 1 ]; then read -r __in </dev/tty || true; else read -r __in || true; printf '%s\n' "$__in"; fi
  [ -z "$__in" ] && __in="$__d"
  printf -v "$__v" '%s' "$__in"
}

MAIL_DOMAIN=""
while [ -z "$MAIL_DOMAIN" ]; do
  ask MAIL_DOMAIN "Mail domain (right-hand side of your addresses, e.g. mail.example.com)"
  case "$MAIL_DOMAIN" in
    *.*) : ;;
    *) warn "that does not look like a domain"; MAIL_DOMAIN="" ;;
  esac
done

DEFAULT_MX="mx.${MAIL_DOMAIN#*.}"
ask MX_HOST "Hostname for this server (used as the SMTP HELO name)" "$DEFAULT_MX"
ask MAILBOX "Mailbox name (the part before the @)" "admin"
ask SELECTOR "DKIM selector" "mail"
ask WEB_PORT "Port for the web interface" "$PORT_DEFAULT"

say ""
say "  ${B}How will inbound mail reach this machine?${Z}"
say "    1) relay  - a free relay accepts mail on its port 25 and posts it"
say "                to a public HTTPS URL for this app. Works behind NAT"
say "                with no port forwarding. Recommended."
say "    2) direct - this host owns port 25 and receives mail itself."
say "                Requires inbound TCP 25 from the internet."
ask MODE_CHOICE "Choose 1 or 2" "1"
if [ "$MODE_CHOICE" = "2" ]; then MODE="direct"; else MODE="relay"; fi

WEBHOOK_BASE=""
USE_CF=0
TUNNEL_HOST=""
if [ "$MODE" = "relay" ]; then
  say ""
  say "  Relay mode needs a public HTTPS URL that reaches this machine."
  say "  This installer can create a Cloudflare Tunnel for you: it downloads"
  say "  cloudflared, opens a Cloudflare sign-in for you to approve in a"
  say "  browser, then publishes a permanent hostname. No port forwarding."
  ask CF_ANSWER "Set up a Cloudflare Tunnel now? (y/n)" "y"
  case "$CF_ANSWER" in
    y|Y|yes|YES)
      USE_CF=1
      ask TUNNEL_HOST "Hostname to publish (a domain in your Cloudflare account)" "mailhook.${MAIL_DOMAIN#*.}"
      ;;
    *)
      say "  You can point any public HTTPS URL at this app instead."
      ask WEBHOOK_BASE "Public base URL (leave blank to fill in later)" ""
      ;;
  esac
fi

DETECTED_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
ask PUBLIC_IP "Public IPv4 address of this server" "$DETECTED_IP"
[ -n "$PUBLIC_IP" ] || die "a public IP is required for the SPF record"

INBOUND_SECRET="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-28)"

say ""
say "  ${B}Summary${Z}"
say "    domain      @$MAIL_DOMAIN"
say "    address     $MAILBOX@$MAIL_DOMAIN"
say "    hostname    $MX_HOST"
say "    public IP   $PUBLIC_IP"
say "    mode        $MODE"
say "    web UI      http://<this-host>:$WEB_PORT"
say ""
ask CONFIRM "Proceed? (y/n)" "y"
case "$CONFIRM" in y|Y|yes|YES) : ;; *) die "aborted" ;; esac

# ------------------------------------------------------------- packages ---
step "Installing packages"
clear_port25
clear_docker_25
export DEBIAN_FRONTEND=noninteractive

# Unattended upgrades or a concurrent install will hold the dpkg lock and make
# apt fail outright, so wait for it rather than dying on a transient conflict.
wait_for_apt() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ "$waited" = 0 ] && warn "another package manager is running; waiting for it to finish"
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge 300 ]; then
      die "timed out after 5 minutes waiting for the dpkg lock; re-run once it is free"
    fi
  done
}

if [ "$PM" = apt ]; then
  wait_for_apt
  # preseed so postfix does not open an interactive dialog
  echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
  echo "postfix postfix/mailname string $MX_HOST" | debconf-set-selections
  apt-get update -qq
  apt-get install -y -qq postfix opendkim opendkim-tools curl ca-certificates \
    dnsutils psmisc sudo >/dev/null
  if ! command -v node >/dev/null 2>&1; then
    apt-get install -y -qq nodejs npm >/dev/null || true
  fi
else
  $PM install -y -q postfix opendkim opendkim-tools curl bind-utils psmisc sudo >/dev/null
  command -v node >/dev/null 2>&1 || $PM install -y -q nodejs npm >/dev/null || true
fi
command -v node >/dev/null 2>&1 || die "Node.js could not be installed automatically; install Node 18+ and re-run"
ok "packages installed (node $(node -v))"


# ------------------------------------------------------------ cloudflare --
if [ "$USE_CF" = 1 ]; then
  step "Setting up Cloudflare Tunnel"

  if ! command -v cloudflared >/dev/null 2>&1; then
    case "$(uname -m)" in
      x86_64|amd64)   CF_ARCH=amd64 ;;
      aarch64|arm64)  CF_ARCH=arm64 ;;
      armv7l|armv6l)  CF_ARCH=arm ;;
      *) die "unsupported architecture for cloudflared: $(uname -m)" ;;
    esac
    say "  downloading cloudflared ($CF_ARCH)..."
    curl -fsSL --max-time 180       "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"       -o /tmp/cloudflared || die "could not download cloudflared"
    install -m755 /tmp/cloudflared /usr/local/bin/cloudflared
    rm -f /tmp/cloudflared
  fi
  ok "cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}')"

  export TUNNEL_ORIGIN_CERT=/etc/cloudflared/cert.pem
  mkdir -p /etc/cloudflared

  if [ ! -f /etc/cloudflared/cert.pem ]; then
    say ""
    say "  ${B}Cloudflare sign-in required.${Z}"
    say "  A URL will appear below. Open it in any browser, sign in, and"
    say "  authorise the domain you entered. This installer waits for you."
    say ""
    # `tunnel login` ignores TUNNEL_ORIGIN_CERT and always writes to the
    # invoking user's home directory, so collect it from wherever it landed.
    cloudflared tunnel login || die "cloudflare login failed"
    CF_CERT=""
    for c in "$HOME/.cloudflared/cert.pem" /root/.cloudflared/cert.pem              "${SUDO_USER:+/home/$SUDO_USER/.cloudflared/cert.pem}"; do
      [ -n "$c" ] && [ -f "$c" ] && { CF_CERT="$c"; break; }
    done
    [ -n "$CF_CERT" ] || die "login did not produce a certificate"
    install -m600 "$CF_CERT" /etc/cloudflared/cert.pem
  fi
  ok "authorised with Cloudflare"

  TUNNEL_NAME="selfmail-$(echo "$TUNNEL_HOST" | tr '.' '-')"
  if ! cloudflared tunnel list 2>/dev/null | grep -qw "$TUNNEL_NAME"; then
    cloudflared tunnel create "$TUNNEL_NAME" >/dev/null || die "could not create tunnel"
  fi
  TUNNEL_ID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2==n {print $1}' | head -1)"
  [ -n "$TUNNEL_ID" ] || die "could not determine tunnel id"
  if [ ! -f "/etc/cloudflared/$TUNNEL_ID.json" ]; then
    for d in "$HOME/.cloudflared" /root/.cloudflared "${SUDO_USER:+/home/$SUDO_USER/.cloudflared}"; do
      [ -n "$d" ] && [ -f "$d/$TUNNEL_ID.json" ] && { install -m600 "$d/$TUNNEL_ID.json" "/etc/cloudflared/$TUNNEL_ID.json"; break; }
    done
  fi
  [ -f "/etc/cloudflared/$TUNNEL_ID.json" ] || die "tunnel credentials file not found"
  ok "tunnel $TUNNEL_NAME ($TUNNEL_ID)"

  # creates the CNAME in Cloudflare DNS automatically
  cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_HOST" >/dev/null 2>&1 ||     warn "DNS route already exists or could not be created; check the dashboard"

  cat > /etc/cloudflared/config.yml <<CFG
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/$TUNNEL_ID.json
loglevel: info

ingress:
  - hostname: $TUNNEL_HOST
    service: http://localhost:$WEB_PORT
  - service: http_status:404
CFG
  chmod 600 /etc/cloudflared/*.json 2>/dev/null || true

  cat > /etc/systemd/system/selfmail-tunnel.service <<UNIT
[Unit]
Description=Cloudflare Tunnel for selfmail
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /etc/cloudflared/config.yml tunnel run
Restart=always
RestartSec=10
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT

  # A hung tunnel keeps its process alive, so systemd cannot detect it.
  # Probe locally first: if the app is down, restarting the tunnel is pointless.
  cat > /usr/local/bin/selfmail-health <<'HEALTH'
#!/bin/bash
. /etc/selfmail/env 2>/dev/null || exit 1
HOST_PUB="$(awk '/hostname:/ {print $3; exit}' /etc/cloudflared/config.yml 2>/dev/null)"
S="$SELFMAIL_INBOUND_SECRET"
P="${SELFMAIL_PORT:-8088}"
[ -n "$S" ] || exit 0
D=/run/selfmail-health; mkdir -p "$D"
bump() { local f="$D/$1" n; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$f"; echo "$n"; }

if curl -fsS --max-time 10 "http://127.0.0.1:$P/inbound/$S/ping" 2>/dev/null | grep -q '"ready":true'; then
  rm -f "$D/local"
else
  n=$(bump local)
  logger -t selfmail-health "local probe failed (strike $n)"
  [ "$n" -ge 2 ] && { logger -t selfmail-health "restarting selfmail"; systemctl restart selfmail; rm -f "$D/local"; }
  exit 0
fi

[ -n "$HOST_PUB" ] || exit 0
if curl -fsS --max-time 25 "https://$HOST_PUB/inbound/$S/ping" 2>/dev/null | grep -q '"ready":true'; then
  rm -f "$D/public"; exit 0
fi
n=$(bump public)
logger -t selfmail-health "public probe via $HOST_PUB failed (strike $n)"
[ "$n" -ge 2 ] && { logger -t selfmail-health "restarting tunnel"; systemctl restart selfmail-tunnel; rm -f "$D/public"; }
HEALTH
  chmod +x /usr/local/bin/selfmail-health

  cat > /etc/systemd/system/selfmail-health.service <<UNIT
[Unit]
Description=Verify selfmail is reachable end to end
[Service]
Type=oneshot
ExecStart=/usr/local/bin/selfmail-health
UNIT

  cat > /etc/systemd/system/selfmail-health.timer <<UNIT
[Unit]
Description=Run the selfmail health check every 2 minutes
[Timer]
OnBootSec=90s
OnUnitActiveSec=120s
AccuracySec=10s
[Install]
WantedBy=timers.target
UNIT

  WEBHOOK_BASE="https://$TUNNEL_HOST"
  ok "tunnel will publish https://$TUNNEL_HOST"
fi

# ----------------------------------------------------------- mail users ---
step "Creating mail storage"
getent group vmail >/dev/null || groupadd -g 5000 vmail
getent passwd vmail >/dev/null || useradd -g vmail -u 5000 -d "$MAILROOT" -s /usr/sbin/nologin vmail
mkdir -p "$MAILROOT/$MAIL_DOMAIN/$MAILBOX"/{new,cur,tmp}
chown -R vmail:vmail "$MAILROOT"
chmod 770 "$MAILROOT"
ok "maildir at $MAILROOT/$MAIL_DOMAIN/$MAILBOX"

id "$APP_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d "$APP_DIR" "$APP_USER"

# -------------------------------------------------------------- postfix ---
step "Configuring Postfix"
cp -n /etc/postfix/main.cf "/etc/postfix/main.cf.selfmail-backup" 2>/dev/null || true

printf '%s@%s\t%s/%s/\npostmaster@%s\t%s/%s/\n' \
  "$MAILBOX" "$MAIL_DOMAIN" "$MAIL_DOMAIN" "$MAILBOX" \
  "$MAIL_DOMAIN" "$MAIL_DOMAIN" "$MAILBOX" > /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox
printf '@%s\t%s@%s\n' "$MAIL_DOMAIN" "$MAILBOX" "$MAIL_DOMAIN" > /etc/postfix/virtual
postmap /etc/postfix/virtual

# Do not enable IPv6 in Postfix on a host where it is disabled, or the master
# fatals on the IPv6 bind and never starts. Match the setting to the host.
INET_PROTO=all
if [ ! -f /proc/net/if_inet6 ] || [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" = 1 ]; then
  INET_PROTO=ipv4
fi

postconf -e \
  "myhostname = $MX_HOST" \
  "smtpd_banner = \$myhostname ESMTP" \
  "mydestination = localhost" \
  "mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128" \
  "inet_interfaces = all" \
  "inet_protocols = $INET_PROTO" \
  "smtp_address_preference = ipv4" \
  "disable_vrfy_command = yes" \
  "smtpd_helo_required = yes" \
  "smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated defer_unauth_destination" \
  "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination" \
  "smtpd_client_connection_count_limit = 10" \
  "smtpd_client_connection_rate_limit = 30" \
  "smtpd_error_sleep_time = 5s" \
  "smtpd_soft_error_limit = 3" \
  "smtpd_hard_error_limit = 8" \
  "smtp_tls_security_level = may" \
  "smtp_tls_loglevel = 1" \
  "smtpd_tls_security_level = may" \
  "virtual_mailbox_domains = $MAIL_DOMAIN" \
  "virtual_mailbox_base = $MAILROOT" \
  "virtual_mailbox_maps = hash:/etc/postfix/vmailbox" \
  "virtual_alias_maps = hash:/etc/postfix/virtual" \
  "virtual_minimum_uid = 100" \
  "virtual_uid_maps = static:5000" \
  "virtual_gid_maps = static:5000" \
  "milter_default_action = accept" \
  "milter_protocol = 6" \
  "smtpd_milters = local:/opendkim/opendkim.sock" \
  "non_smtpd_milters = local:/opendkim/opendkim.sock"

# Postfix asks the milter about a new connection *before* it sends the 220
# banner, and milter_connect_timeout defaults to 30s. An OpenDKIM that is
# listening but not answering therefore holds the greeting for half a minute,
# which every SMTP client - the web UI included - reports as the unhelpful
# "Greeting never received". milter_default_action does not cover this: it
# applies to a *refused* milter connection, not a silent one. Cap the wait, so
# a sick milter costs a signature rather than the entire send path.
postconf -e \
  "milter_connect_timeout = 5s" \
  "milter_command_timeout = 10s" \
  "milter_content_timeout = 30s"

# Sending over IPv6 without a PTR record gets rejected by major providers,
# so pin the outbound client to IPv4 while still listening on both.
postconf -P 'smtp/unix/inet_protocols=ipv4' 2>/dev/null || true
ok "postfix configured for @$MAIL_DOMAIN"

# --------------------------------------------------------------- opendkim -
step "Generating DKIM key"
mkdir -p "/etc/opendkim/keys/$MAIL_DOMAIN"
if [ ! -f "/etc/opendkim/keys/$MAIL_DOMAIN/$SELECTOR.private" ]; then
  ( cd "/etc/opendkim/keys/$MAIL_DOMAIN" && opendkim-genkey -b 2048 -d "$MAIL_DOMAIN" -s "$SELECTOR" )
  ok "2048-bit key created"
else
  warn "existing key kept"
fi

cat > /etc/opendkim.conf <<CONF
Syslog                  yes
SyslogSuccess           yes
UMask                   007
Mode                    sv
Canonicalization        relaxed/simple
SubDomains              no
OversignHeaders         From
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
PidFile                 /run/opendkim/opendkim.pid
UserID                  opendkim:postfix
KeyTable                /etc/opendkim/key.table
SigningTable            refile:/etc/opendkim/signing.table
ExternalIgnoreList      /etc/opendkim/trusted.hosts
InternalHosts           /etc/opendkim/trusted.hosts
CONF

echo "$SELECTOR._domainkey.$MAIL_DOMAIN $MAIL_DOMAIN:$SELECTOR:/etc/opendkim/keys/$MAIL_DOMAIN/$SELECTOR.private" > /etc/opendkim/key.table
echo "*@$MAIL_DOMAIN $SELECTOR._domainkey.$MAIL_DOMAIN" > /etc/opendkim/signing.table
printf '127.0.0.1\nlocalhost\n%s\n' "$MAIL_DOMAIN" > /etc/opendkim/trusted.hosts

mkdir -p /var/spool/postfix/opendkim /run/opendkim
chown opendkim:postfix /var/spool/postfix/opendkim
chown opendkim:opendkim /run/opendkim
chmod 750 /var/spool/postfix/opendkim
chown -R opendkim:opendkim /etc/opendkim
chmod 600 "/etc/opendkim/keys/$MAIL_DOMAIN/$SELECTOR.private"
id -nG postfix 2>/dev/null | grep -qw opendkim || usermod -aG opendkim postfix 2>/dev/null || true

# The web UI shows the DKIM *public* key so it can be pasted into DNS. Grant
# read access through the opendkim group rather than widening permissions;
# the private key stays 0600 and unreadable.
usermod -aG opendkim "$APP_USER" 2>/dev/null || true
chmod 750 /etc/opendkim /etc/opendkim/keys "/etc/opendkim/keys/$MAIL_DOMAIN"
chmod 640 "/etc/opendkim/keys/$MAIL_DOMAIN/$SELECTOR.txt"
ok "opendkim configured"

# ------------------------------------------------------------------ app ---
step "Installing the web interface"
mkdir -p "$APP_DIR"
cp -r "$SRC_DIR/server.js" "$SRC_DIR/package.json" "$SRC_DIR/public" "$APP_DIR/"
( cd "$APP_DIR" && npm install --omit=dev --silent --no-audit --no-fund >/dev/null 2>&1 )
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
ok "app installed to $APP_DIR"

mkdir -p "$CFG_DIR"
WEBHOOK_URL=""
[ -n "$WEBHOOK_BASE" ] && WEBHOOK_URL="${WEBHOOK_BASE%/}/inbound/$INBOUND_SECRET"

cat > "$CFG_FILE" <<JSON
{
  "domain": "$MAIL_DOMAIN",
  "mxhost": "$MX_HOST",
  "selector": "$SELECTOR",
  "publicIp": "$PUBLIC_IP",
  "mailbox": "$MAILBOX",
  "fromName": "",
  "defaultTo": "",
  "dmarcRua": "",
  "dmarcPolicy": "none",
  "mode": "$MODE",
  "relayProvider": "forwardemail",
  "webhookUrl": "$WEBHOOK_URL"
}
JSON
chown "$APP_USER":"$APP_USER" "$CFG_FILE"
chmod 640 "$CFG_FILE"

cat > "$ENV_FILE" <<ENV
SELFMAIL_PORT=$WEB_PORT
SELFMAIL_INBOUND_SECRET=$INBOUND_SECRET
SELFMAIL_CONFIG=$CFG_FILE
SELFMAIL_MAILROOT=$MAILROOT
ENV
chown root:"$APP_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"

# Seed the web login. The published default adminpass/adminpass26! works until
# changed with ./update.sh; users may add their own logins there too.
DEF_HASH="$(printf '%s' 'adminpass26!' | sha256sum | awk '{print $1}')"
printf '{\n  "adminpass": "%s"\n}\n' "$DEF_HASH" > "$CFG_DIR/users.json"
chown root:"$APP_USER" "$CFG_DIR/users.json" 2>/dev/null || true
chmod 640 "$CFG_DIR/users.json"


# The app reads maildirs owned by vmail and queries postfix, so it needs a
# few specific commands as root - listed explicitly rather than blanket sudo.
cat > /etc/sudoers.d/selfmail <<SUDO
$APP_USER ALL=(root) NOPASSWD: /usr/bin/cat, /usr/bin/find, /usr/bin/install, /usr/bin/tail, /usr/sbin/postconf, /usr/sbin/postmap, /bin/cat, /bin/find, /usr/bin/mailq
SUDO
chmod 440 /etc/sudoers.d/selfmail
visudo -cf /etc/sudoers.d/selfmail >/dev/null || die "generated sudoers file is invalid"
ok "configuration written to $CFG_DIR"

# -------------------------------------------------------------- systemd ---
step "Installing services"
cat > /etc/systemd/system/selfmail.service <<UNIT
[Unit]
Description=selfmail web interface
After=network-online.target postfix.service
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$(command -v node) $APP_DIR/server.js
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now opendkim >/dev/null 2>&1 || true
systemctl restart opendkim || true

# Postfix hands every connection to this socket before greeting, so confirm it
# exists before starting Postfix rather than discovering it on the first send.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S /var/spool/postfix/opendkim/opendkim.sock ] && break
  sleep 1
done
if [ ! -S /var/spool/postfix/opendkim/opendkim.sock ]; then
  warn "OpenDKIM's milter socket never appeared - mail will send but go unsigned"
  warn "check: journalctl -u opendkim -n 30"
fi

clear_port25
systemctl enable --now postfix >/dev/null 2>&1 || true
systemctl restart postfix || true
sleep 2
if ! postfix_really_running; then
  warn "Postfix did not start. Whatever is on port 25 right now:"
  ss -lntp 2>/dev/null | awk 'NR==1 || $4 ~ /:25$/' | sed 's/^/    /' || true
  warn "Stop that service, then run: sudo systemctl restart postfix"
fi
systemctl enable --now selfmail >/dev/null 2>&1 || true
systemctl restart selfmail || true
if [ "$USE_CF" = 1 ]; then
  systemctl enable --now selfmail-tunnel >/dev/null 2>&1 || true
  systemctl restart selfmail-tunnel || true
  systemctl enable --now selfmail-health.timer >/dev/null 2>&1 || true
fi
sleep 5

SERVICES="postfix opendkim selfmail"
[ "$USE_CF" = 1 ] && SERVICES="$SERVICES selfmail-tunnel"
for s in $SERVICES; do
  if [ "$s" = postfix ]; then
    if postfix_really_running; then ok "postfix running"; else warn "postfix is NOT running - something else owns port 25 (see above)"; fi
  elif [ "$(systemctl is-active "$s")" = active ]; then ok "$s running"; else warn "$s is NOT running - check: journalctl -u $s -n 40"; fi
done
report_smtp || true

# ---------------------------------------------------------------- finish --
IP_SHOW="$(hostname -I 2>/dev/null | awk '{print $1}')"
step "Done"
say ""
say "  ${B}Web interface${Z}   http://${IP_SHOW:-localhost}:$WEB_PORT"
say "  ${Y}The interface has no login. Keep it on a trusted network,${Z}"
say "  ${Y}or put it behind a reverse proxy or tunnel with its own auth.${Z}"
say ""
say "  Open the web interface and go to the ${B}DNS${Z} tab. It lists every record"
say "  you need to add at your DNS host, and the ${B}Check records${Z} button verifies"
say "  them live once you have saved them."
say ""
if [ "$MODE" = relay ]; then
  if [ "$USE_CF" = 1 ]; then
    say "  ${B}Public URL${Z}      https://$TUNNEL_HOST"
    say "    The tunnel runs as selfmail-tunnel.service and restarts itself."
    say "    selfmail-health.timer re-checks it every 2 minutes and restarts"
    say "    it if the public URL stops answering."
    say ""
  fi
  if [ -n "$WEBHOOK_URL" ]; then
    say "  Relay webhook URL (the DNS tab shows the TXT record to add):"
    say "    ${C}$WEBHOOK_URL${Z}"
  else
    say "  ${Y}Relay mode selected but no public URL was given.${Z}"
    say "  Set one in the web interface (Settings -> Public base URL), then use:"
    say "    https://YOUR-URL/inbound/$INBOUND_SECRET"
  fi
  say ""
fi
say "  Mail log: $MAILLOG"
say "  Service:  systemctl status selfmail"
say ""
