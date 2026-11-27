#!/usr/bin/env bash
# Shared helpers for GB SMTP Service scripts. Source this file; do not run it.
# Variables defined here are consumed by the scripts that source it.
# shellcheck disable=SC2034,SC2120

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DKIM_SELECTOR="mail"
DKIM_KEYSIZE=2048

# ---------- logging ----------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s ok%s  %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

usage_env() {
  echo "Usage: $(basename "$0") <prd|uat> $*" >&2
  exit 2
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed (needed by $(basename "$0"))"
  done
}

# ---------- environment ----------
# load_env <prd|uat>  — sources env/<env>.env and sets derived variables.
load_env() {
  local env="${1:-}"
  case "$env" in
    prd|uat) ;;
    *) usage_env ;;
  esac
  local env_file="$ROOT_DIR/env/$env.env"
  [[ -f "$env_file" ]] || die "Missing $env_file"

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  [[ "${ENV_NAME:-}" == "$env" ]] || die "ENV_NAME in $env_file must be '$env'"
  : "${MAIL_HOSTNAME:?MAIL_HOSTNAME missing in $env_file}"
  : "${MAILBOXES_FILE:?MAILBOXES_FILE missing in $env_file}"
  : "${ALIASES_FILE:?ALIASES_FILE missing in $env_file}"

  ENV="$env"
  CONTAINER="gbsmtp-$env"
  PROJECT="gbsmtp-$env"
  : "${DATA_ROOT:?DATA_ROOT missing in $env_file}"
  [[ "$DATA_ROOT" == /* ]] || die "DATA_ROOT must be an absolute path (got '$DATA_ROOT')"
  case "$DATA_ROOT/" in "$ROOT_DIR"/*) die "DATA_ROOT ($DATA_ROOT) must be outside the code folder ($ROOT_DIR)";; esac
  DATA_DIR="$DATA_ROOT"
  CONF_DIR="$DATA_DIR/config"
  SECRETS_DIR="$DATA_DIR/secrets"
  CREDENTIALS_FILE="$SECRETS_DIR/credentials.txt"
  ACCOUNTS_CF="$CONF_DIR/postfix-accounts.cf"
  VIRTUAL_CF="$CONF_DIR/postfix-virtual.cf"
  DKIM_DIR="$CONF_DIR/rspamd/dkim"
  DKIM_CONF="$CONF_DIR/rspamd/override.d/dkim_signing.conf"
  MAILBOXES_PATH="$ROOT_DIR/$MAILBOXES_FILE"
  ALIASES_PATH="$ROOT_DIR/$ALIASES_FILE"
  DNS_OUT="$DATA_DIR/dns-records.txt"
  COMPOSE=(docker compose -p "$PROJECT" --env-file "$ROOT_DIR/env/$env.env" -f "$ROOT_DIR/docker-compose.yml")
}

# ---------- mailbox / alias lists ----------
# Prints non-comment, non-empty lines, trimmed, lower-cased.
read_list() {
  local file="$1"
  [[ -f "$file" ]] || die "Missing list file: $file"
  sed -e 's/#.*$//' -e 's/\r$//' "$file" \
    | awk 'NF { $1=$1; print tolower($0) }'
}

mailboxes() { read_list "$MAILBOXES_PATH" | awk '{print $1}'; }
aliases()   { read_list "$ALIASES_PATH"; }        # "<alias> <destination>"
domains()   { mailboxes | awk -F@ '{print $2}' | sort -u; }

is_valid_email() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Validates mailbox + alias files. Returns non-zero with messages on problems.
validate_lists() {
  local errors=0 m a d line
  local -A seen=()
  while read -r m; do
    if ! is_valid_email "$m"; then warn "Invalid mailbox address: $m"; errors=$((errors+1)); fi
    if [[ -n "${seen[$m]:-}" ]]; then warn "Duplicate mailbox: $m"; errors=$((errors+1)); fi
    seen[$m]=1
  done < <(mailboxes)
  [[ ${#seen[@]} -gt 0 ]] || { warn "No mailboxes defined in $MAILBOXES_FILE"; errors=$((errors+1)); }

  while read -r line; do
    read -r a d _ <<<"$line"
    if [[ -z "${d:-}" ]]; then warn "Alias line needs '<alias> <destination>': $line"; errors=$((errors+1)); continue; fi
    is_valid_email "$a" || { warn "Invalid alias address: $a"; errors=$((errors+1)); }
    if [[ -n "${seen[$a]:-}" ]]; then warn "Alias $a is also a mailbox"; errors=$((errors+1)); fi
    if [[ -z "${seen[$d]:-}" ]]; then warn "Alias $a points to $d, which is not a mailbox in $MAILBOXES_FILE"; errors=$((errors+1)); fi
  done < <(aliases)

  return "$errors"
}

is_valid_ip_or_cidr() {
  local re4='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$'
  local re6='^[0-9a-fA-F:]+(/[0-9]{1,3})?$'
  [[ "$1" =~ $re4 || ( "$1" == *:* && "$1" =~ $re6 ) ]]
}

# ---------- secrets ----------
gen_password() {
  # 24 chars, alphanumeric (safe for every mail client and .env file)
  openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-24
}

hash_password() {
  # SHA512-CRYPT, the scheme docker-mailserver/Dovecot uses
  printf '%s' "$1" | openssl passwd -6 -stdin
}

account_exists() {
  [[ -f "$ACCOUNTS_CF" ]] && awk -F'|' -v e="$1" 'tolower($1)==e {found=1} END {exit !found}' "$ACCOUNTS_CF"
}

alias_exists() {
  [[ -f "$VIRTUAL_CF" ]] && awk -v a="$1" 'tolower($1)==a {found=1} END {exit !found}' "$VIRTUAL_CF"
}

# ---------- account administration (passwd / add / suspend) ----------
SUSPEND_MARK="!"   # a hash starting with {SCHEME}! can never match, so login is refused

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (mail accounts and passwords are root-only): sudo bash $0 $*"
}

# Serialise edits to the account files (two admins, or a script racing setup.sh)
lock_accounts() {
  exec 9>"$CONF_DIR/.gbsmtp-admin.lock"
  flock -w 30 9 || die "Another admin script is editing accounts — try again"
}

normalise_email() { printf '%s' "${1,,}" | tr -d '[:space:]'; }

# Prints the stored hash field (e.g. "{SHA512-CRYPT}$6$...") for an address
account_hash() {
  awk -F'|' -v e="$1" 'tolower($1)==e {print $2; exit}' "$ACCOUNTS_CF"
}

is_suspended() {
  local h; h="$(account_hash "$1")"
  [[ "$h" =~ ^\{[A-Z0-9-]+\}${SUSPEND_MARK} ]]
}

# set_account_hash <email> <hash-field> — rewrites the line in place (keeps inode,
# owner and mode, so docker-mailserver's change detector picks it up cleanly)
set_account_hash() {
  local email="$1" field="$2" tmp
  tmp="$(mktemp "$CONF_DIR/.accounts.XXXXXX")"
  awk -F'|' -v OFS='|' -v e="$email" -v h="$field" \
    'tolower($1)==e { $0 = $1 "|" h } { print }' "$ACCOUNTS_CF" > "$tmp"
  cat "$tmp" > "$ACCOUNTS_CF"
  rm -f "$tmp"
}

# Reads a new password interactively (twice) and validates it. Result in $NEW_PASSWORD.
prompt_password() {
  local p1 p2
  while true; do
    read -rsp "New password (min 12 chars): " p1; echo
    read -rsp "Repeat password: " p2; echo
    if [[ "$p1" != "$p2" ]]; then warn "Passwords do not match"; continue; fi
    if (( ${#p1} < 12 )); then warn "Too short — use at least 12 characters"; continue; fi
    if [[ "$p1" =~ [[:space:]\|:\"\'\`\\] ]]; then
      warn "Avoid spaces and these characters: | : \" ' \` \\"; continue
    fi
    NEW_PASSWORD="$p1"; return 0
  done
}

# record_credential <email> <password> <note> — upsert the line in credentials.txt
record_credential() {
  local email="$1" pw="$2" note="$3" tmp line
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  touch "$CREDENTIALS_FILE"; chmod 600 "$CREDENTIALS_FILE"
  line="$(printf '  %-38s %-26s %s  %s' "$email" "$pw" "$(date '+%F %T')" "$note")"
  tmp="$(mktemp "$SECRETS_DIR/.cred.XXXXXX")"
  awk -v e="$email" -v l="$line" '
    !/^[[:space:]]*#/ && tolower($1)==e { if (!done) print l; done=1; next }
    { print }
    END { if (!done) print l }' "$CREDENTIALS_FILE" > "$tmp"
  cat "$tmp" > "$CREDENTIALS_FILE"; rm -f "$tmp"
}

# Marks an address's credentials line without changing the password column
annotate_credential() {
  local email="$1" note="$2" tmp
  [[ -f "$CREDENTIALS_FILE" ]] || return 0
  tmp="$(mktemp "$SECRETS_DIR/.cred.XXXXXX")"
  awk -v e="$email" -v n="$note" -v d="$(date '+%F %T')" '
    !/^[[:space:]]*#/ && tolower($1)==e { printf "  %-38s %-26s %s  %s\n", $1, $2, d, n; next }
    { print }' "$CREDENTIALS_FILE" > "$tmp"
  cat "$tmp" > "$CREDENTIALS_FILE"; rm -f "$tmp"
}

# Ends open IMAP sessions for an address (so a suspend / password change bites at once)
kick_sessions() {
  container_running || return 0
  docker exec "$CONTAINER" doveadm kick "$1" >/dev/null 2>&1 || true
}

# ---------- DKIM ----------
dkim_key_path()      { echo "$DKIM_DIR/$1.$DKIM_SELECTOR.key"; }
dkim_container_path(){ echo "/tmp/docker-mailserver/rspamd/dkim/$1.$DKIM_SELECTOR.key"; }

dkim_public_b64() {
  openssl rsa -in "$(dkim_key_path "$1")" -pubout 2>/dev/null \
    | grep -v -- '-----' | tr -d '\n'
}

# ---------- docker ----------
container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == "true" ]]
}

wait_healthy() {
  local timeout="${1:-240}" waited=0 status
  log "Waiting for $CONTAINER to become healthy (up to ${timeout}s)"
  while (( waited < timeout )); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo missing)"
    case "$status" in
      healthy) ok "$CONTAINER is healthy"; return 0 ;;
      missing) die "Container $CONTAINER does not exist" ;;
    esac
    sleep 5; waited=$((waited+5))
  done
  warn "$CONTAINER not healthy after ${timeout}s — check: docker logs $CONTAINER"
  return 1
}

# Rspamd runs as _rspamd inside the container and must be able to read the keys.
fix_dkim_permissions() {
  container_running || return 0
  docker exec "$CONTAINER" bash -c '
    d=/tmp/docker-mailserver/rspamd/dkim
    [ -d "$d" ] || exit 0
    chown -R _rspamd:_rspamd "$d"
    chmod 750 "$d"
    find "$d" -type f -name "*.key" -exec chmod 600 {} +
    supervisorctl restart rspamd >/dev/null 2>&1 || true
  ' && ok "DKIM key permissions set, Rspamd reloaded"
}

detect_public_ip() {
  if [[ -n "${PUBLIC_IP:-}" ]]; then echo "$PUBLIC_IP"; return; fi
  local ip=""
  ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  echo "${ip:-<SERVER_PUBLIC_IP>}"
}
