#!/usr/bin/env bash
# First-time setup (and safe re-run) for one environment.
#
#   sudo ./scripts/setup.sh prd
#   sudo ./scripts/setup.sh uat
#
# What it does (idempotent — re-run any time to add new mailboxes/aliases/domains):
#   1. Pre-flight checks
#   2. Obtains a Let's Encrypt certificate for MAIL_HOSTNAME (if missing)
#   3. Creates every mailbox in config/<env>/mailboxes.txt with a random password
#      (existing mailboxes are never changed) -> secrets/<env>/credentials.txt
#   4. Creates every alias in config/<env>/aliases.txt
#   5. Generates a DKIM key for every domain and configures Rspamd signing
#   6. Starts the container and waits until it is healthy
#   7. Writes the DNS records to publish -> dns/<env>-dns-records.txt
#
# Options:
#   --skip-cert   don't run certbot (certificate already present / managed elsewhere)
#   --no-start    provision files only, don't start the container

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_ARG="${1:-}"; shift || true
SKIP_CERT=0; NO_START=0
for arg in "$@"; do
  case "$arg" in
    --skip-cert) SKIP_CERT=1 ;;
    --no-start)  NO_START=1 ;;
    *) die "Unknown option: $arg" ;;
  esac
done
load_env "$ENV_ARG"

echo
log "GB SMTP Service setup — environment: ${C_GRN}${ENV^^}${C_RST}, host: $MAIL_HOSTNAME"
echo

# ---------------------------------------------------------------- 1. preflight
log "1/7 Pre-flight checks"
require_cmd docker openssl awk sed curl
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin is required ('docker compose')"
if [[ $EUID -ne 0 ]] && ! docker info >/dev/null 2>&1; then
  die "Cannot talk to Docker. Run with sudo or add your user to the docker group."
fi
validate_lists || die "Fix the problems above in $MAILBOXES_FILE / $ALIASES_FILE"
ok "$(mailboxes | wc -l | tr -d ' ') mailboxes across $(domains | wc -l | tr -d ' ') domains: $(domains | paste -sd' ' -)"

mkdir -p "$DATA_DIR"/{mail-data,mail-state,mail-logs,config} "$DKIM_DIR" "$(dirname "$DKIM_CONF")" "$ROOT_DIR/dns"
mkdir -p "$SECRETS_DIR"; chmod 700 "$ROOT_DIR/secrets" "$SECRETS_DIR"
touch "$ACCOUNTS_CF" "$VIRTUAL_CF"

# ---------------------------------------------------------------- 2. certificate
log "2/7 TLS certificate for $MAIL_HOSTNAME"
CERT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}/live/$MAIL_HOSTNAME"
if [[ "${SSL_TYPE:-letsencrypt}" != "letsencrypt" ]]; then
  warn "SSL_TYPE=$SSL_TYPE — skipping certbot"
elif [[ -f "$CERT_DIR/fullchain.pem" ]]; then
  ok "Certificate already present in $CERT_DIR"
elif [[ $SKIP_CERT -eq 1 ]]; then
  warn "--skip-cert given but no certificate at $CERT_DIR — the server will fail TLS until one exists"
else
  [[ $EUID -eq 0 ]] || die "Obtaining a certificate needs root. Re-run with sudo (or use --skip-cert)."
  if ! command -v certbot >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      log "Installing certbot"; apt-get update -qq && apt-get install -y -qq certbot
    else
      die "certbot is not installed — install it, then re-run"
    fi
  fi
  if ss -ltn 2>/dev/null | grep -qE '[:.]80\s'; then
    die "Port 80 is in use — certbot --standalone needs it briefly. Stop the web server, or use --skip-cert and issue the cert yourself."
  fi
  certbot certonly --standalone --non-interactive --agree-tos \
    -m "${ACME_EMAIL:?ACME_EMAIL missing in env file}" -d "$MAIL_HOSTNAME"
  ok "Certificate issued"
fi

# Restart every gbsmtp container after renewal so Postfix/Dovecot pick up the new cert
HOOK="${LETSENCRYPT_DIR:-/etc/letsencrypt}/renewal-hooks/deploy/gbsmtp-restart.sh"
if [[ "${SSL_TYPE:-letsencrypt}" == "letsencrypt" && -d "$(dirname "$HOOK")" && -w "$(dirname "$HOOK")" ]]; then
  cat > "$HOOK" <<'EOF'
#!/bin/sh
# Installed by gbsmtpservice/scripts/setup.sh
for c in $(docker ps --format '{{.Names}}' | grep '^gbsmtp-'); do docker restart "$c"; done
EOF
  chmod 755 "$HOOK"
  ok "Renewal hook installed: $HOOK"
fi

# ---------------------------------------------------------------- 3. mailboxes
log "3/7 Mailboxes"
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  {
    echo "# GB SMTP Service — ${ENV^^} mailbox credentials. KEEP PRIVATE. Do not commit."
    echo "# Server: $MAIL_HOSTNAME | IMAP 993 SSL | SMTP 465 SSL or 587 STARTTLS | username = full address"
    printf '# %-38s %-26s %s\n' "address" "password" "created"
  } > "$CREDENTIALS_FILE"
fi
chmod 600 "$CREDENTIALS_FILE"

created=0
while read -r mbox; do
  if account_exists "$mbox"; then
    ok "exists   $mbox"
    continue
  fi
  pw="$(gen_password)"
  printf '%s|{SHA512-CRYPT}%s\n' "$mbox" "$(hash_password "$pw")" >> "$ACCOUNTS_CF"
  printf '  %-38s %-26s %s\n' "$mbox" "$pw" "$(date '+%F %T')" >> "$CREDENTIALS_FILE"
  ok "created  $mbox"
  created=$((created+1))
done < <(mailboxes)
chmod 640 "$ACCOUNTS_CF"

# Warn about mailboxes on the server that are no longer in the list (never auto-deleted)
ALL_MAILBOXES="$(mailboxes)"
while IFS='|' read -r existing _; do
  [[ -z "$existing" ]] && continue
  grep -qxF "${existing,,}" <<<"$ALL_MAILBOXES" || warn "Mailbox $existing exists on the server but is not in $MAILBOXES_FILE (left untouched)"
done < "$ACCOUNTS_CF"

# ---------------------------------------------------------------- 4. aliases
log "4/7 Aliases"
while read -r a d _; do
  if alias_exists "$a"; then ok "exists   $a -> $d"; continue; fi
  printf '%s %s\n' "$a" "$d" >> "$VIRTUAL_CF"
  ok "created  $a -> $d"
done < <(aliases)

# ---------------------------------------------------------------- 5. DKIM
log "5/7 DKIM keys (selector '$DKIM_SELECTOR', RSA $DKIM_KEYSIZE)"
while read -r dom; do
  key="$(dkim_key_path "$dom")"
  if [[ -f "$key" ]]; then ok "exists   $dom"; continue; fi
  openssl genrsa -out "$key" "$DKIM_KEYSIZE" 2>/dev/null
  chmod 600 "$key"
  ok "created  $dom"
done < <(domains)

{
  echo "# Generated by scripts/setup.sh — do not edit by hand, re-run setup instead."
  echo "enabled = true;"
  echo "sign_authenticated = true;"
  echo "sign_local = true;"
  echo "try_fallback = false;"
  echo "use_domain = \"header\";"
  echo "use_redis = false;"
  echo "use_esld = false;"
  echo "allow_username_mismatch = true;"
  echo "check_pubkey = false;"
  echo "selector = \"$DKIM_SELECTOR\";"
  echo ""
  echo "domain {"
  while read -r dom; do
    echo "  $dom {"
    echo "    path = \"$(dkim_container_path "$dom")\";"
    echo "    selector = \"$DKIM_SELECTOR\";"
    echo "  }"
  done < <(domains)
  echo "}"
} > "$DKIM_CONF"
ok "Rspamd signing config written for $(domains | wc -l | tr -d ' ') domains"

# ---------------------------------------------------------------- 6. start
if [[ $NO_START -eq 1 ]]; then
  warn "6/7 --no-start given — not starting the container"
else
  log "6/7 Starting $CONTAINER"
  "${COMPOSE[@]}" up -d
  wait_healthy 240 || true
  fix_dkim_permissions
fi

# ---------------------------------------------------------------- 7. DNS
log "7/7 DNS records"
"$ROOT_DIR/scripts/dns-records.sh" "$ENV" >/dev/null
ok "Written to ${DNS_OUT#"$ROOT_DIR"/}"

echo
log "${C_GRN}Setup complete for ${ENV^^}${C_RST} ($created new mailbox(es))"
cat <<EOF

  Next steps
  ----------
  1. Publish the DNS records in:   dns/$ENV-dns-records.txt
  2. Set the PTR / reverse DNS of the server IP to $MAIL_HOSTNAME (VPS provider panel)
  3. Mailbox passwords are in:     secrets/$ENV/credentials.txt   (chmod 600, git-ignored)
  4. Check status:                 ./scripts/status.sh $ENV
  5. Test deliverability:          send a mail to the address shown on https://www.mail-tester.com

EOF
