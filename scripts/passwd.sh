#!/usr/bin/env bash
# Change (or reset) the password of a mailbox.
#
#   sudo bash scripts/passwd.sh prd support@goldnpay.in              # prompts for the new password
#   sudo bash scripts/passwd.sh prd support@goldnpay.in --generate   # generates and shows a random one
#
# - Takes effect within a few seconds, no restart needed.
# - Open IMAP sessions for the address are ended, so devices must log in with the new password.
# - The new password is recorded in $DATA_ROOT/secrets/credentials.txt.
# - A suspended mailbox must be resumed first (scripts/suspend.sh <env> <email> --resume).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_ARG="${1:-}"; EMAIL_ARG="${2:-}"; MODE="${3:-}"
[[ -n "$EMAIL_ARG" ]] || usage_env "<email> [--generate]"
load_env "$ENV_ARG"
require_root "$@"
require_cmd openssl awk flock

EMAIL="$(normalise_email "$EMAIL_ARG")"
is_valid_email "$EMAIL" || die "Not a valid address: $EMAIL_ARG"
[[ -f "$ACCOUNTS_CF" ]] || die "No accounts for $ENV — run setup.sh $ENV first"

lock_accounts
if ! account_exists "$EMAIL"; then
  alias_exists "$EMAIL" && die "$EMAIL is an alias, not a mailbox — aliases have no password"
  die "$EMAIL is not a mailbox in ${ENV^^}"
fi
is_suspended "$EMAIL" && die "$EMAIL is suspended. Resume it first: bash scripts/suspend.sh $ENV $EMAIL --resume"

case "$MODE" in
  --generate) NEW_PASSWORD="$(gen_password)" ;;
  "")         prompt_password ;;
  *)          die "Unknown option: $MODE (use --generate or nothing)" ;;
esac

set_account_hash "$EMAIL" "{SHA512-CRYPT}$(hash_password "$NEW_PASSWORD")"
record_credential "$EMAIL" "$NEW_PASSWORD" "(password changed)"
kick_sessions "$EMAIL"

ok "Password changed for $EMAIL (${ENV^^})"
if [[ "$MODE" == "--generate" ]]; then
  echo
  echo "    New password:  $NEW_PASSWORD"
  echo "    (also saved in $CREDENTIALS_FILE)"
fi
unset NEW_PASSWORD
echo
echo "    Devices using $EMAIL (Thunderbird, phone, apps) must now use the new password."
