#!/usr/bin/env bash
# Add a new mailbox on a domain this environment already serves.
#
#   sudo bash scripts/add-mailbox.sh prd accounts@goldnpay.in                 # random password, default quota
#   sudo bash scripts/add-mailbox.sh prd accounts@goldnpay.in --password      # you type the password
#   sudo bash scripts/add-mailbox.sh prd accounts@goldnpay.in --quota 10G     # custom quota (e.g. 500M, 10G)
#
# - Live within a few seconds, no restart needed.
# - The password is shown once and saved in $DATA_ROOT/secrets/credentials.txt.
# - A NEW DOMAIN needs DKIM keys and DNS records: add it to config/<env>/mailboxes.txt
#   in git and run scripts/setup.sh instead.
# - Also add the address to config/<env>/mailboxes.txt in git so the list stays the
#   source of truth (the script prints the exact line).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_ARG="${1:-}"; EMAIL_ARG="${2:-}"
[[ -n "$EMAIL_ARG" ]] || usage_env "<email> [--password] [--quota <size>]"
shift 2
load_env "$ENV_ARG"
require_root
require_cmd openssl awk flock

ASK_PASSWORD=0; QUOTA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --password) ASK_PASSWORD=1; shift ;;
    --quota)    QUOTA="${2:-}"; [[ "$QUOTA" =~ ^[0-9]+[MG]$ ]] || die "--quota needs a size like 500M or 10G"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

EMAIL="$(normalise_email "$EMAIL_ARG")"
is_valid_email "$EMAIL" || die "Not a valid address: $EMAIL_ARG"
DOMAIN="${EMAIL#*@}"
[[ -f "$ACCOUNTS_CF" ]] || die "No accounts for $ENV — run setup.sh $ENV first"

lock_accounts
account_exists "$EMAIL" && die "$EMAIL already exists in ${ENV^^}"
alias_exists "$EMAIL" && die "$EMAIL is already an alias in ${ENV^^} — remove the alias first"

# Domain must already be served here (has DKIM key and DNS records)
if ! awk -F'|' -v d="@$DOMAIN" '{a=tolower($1)} length(a)>length(d) && substr(a,length(a)-length(d)+1)==d {f=1} END{exit !f}' "$ACCOUNTS_CF" \
   || [[ ! -f "$(dkim_key_path "$DOMAIN")" ]]; then
  die "$DOMAIN is not served by ${ENV^^} yet. New domains need DKIM + DNS: add the address to $MAILBOXES_FILE and run: bash scripts/setup.sh $ENV"
fi

if [[ $ASK_PASSWORD -eq 1 ]]; then prompt_password; else NEW_PASSWORD="$(gen_password)"; fi

printf '%s|{SHA512-CRYPT}%s\n' "$EMAIL" "$(hash_password "$NEW_PASSWORD")" >> "$ACCOUNTS_CF"
record_credential "$EMAIL" "$NEW_PASSWORD" "(added)"
ok "Mailbox created: $EMAIL (${ENV^^})"

if [[ -n "$QUOTA" ]]; then
  if container_running; then
    sleep 5   # let the change detector register the new account first
    if docker exec "$CONTAINER" setup quota set "$EMAIL" "$QUOTA" >/dev/null 2>&1; then
      ok "Quota set to $QUOTA"
    else
      warn "Could not set quota yet — run: docker exec $CONTAINER setup quota set $EMAIL $QUOTA"
    fi
  else
    warn "Container not running — set the quota later: docker exec $CONTAINER setup quota set $EMAIL $QUOTA"
  fi
fi

cat <<EOF

    Address:   $EMAIL
    Password:  $([[ $ASK_PASSWORD -eq 1 ]] && echo "(as entered)" || echo "$NEW_PASSWORD")
    Server:    $MAIL_HOSTNAME — IMAP 993 SSL/TLS, SMTP 465 SSL/TLS (or 587 STARTTLS)
    Saved in:  $CREDENTIALS_FILE

    Keep the repo in sync — add this line to $MAILBOXES_FILE and commit:
        $EMAIL

EOF
unset NEW_PASSWORD
