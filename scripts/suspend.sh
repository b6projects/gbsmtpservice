#!/usr/bin/env bash
# Suspend or resume a mailbox without deleting it.
#
#   sudo bash scripts/suspend.sh prd service@goldnpay.in                    # block login (IMAP + sending)
#   sudo bash scripts/suspend.sh prd service@goldnpay.in --block-incoming   # also bounce new incoming mail
#   sudo bash scripts/suspend.sh prd service@goldnpay.in --resume           # restore login (+ incoming)
#   sudo bash scripts/suspend.sh prd --list                                 # show suspended mailboxes
#
# Suspending:
#   - Login is refused for IMAP and SMTP, so the user can neither read nor send mail.
#     Open sessions are ended immediately.
#   - The password is kept (disabled, not deleted); --resume restores the same password.
#   - Stored mail is untouched. By default new mail keeps arriving in the mailbox
#     (useful for staff leave/offboarding). With --block-incoming, senders get a bounce.
#   - Aliases pointing to the mailbox keep delivering to it unless --block-incoming is used.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_ARG="${1:-}"; shift || true
load_env "$ENV_ARG"
require_root
require_cmd awk flock
[[ -f "$ACCOUNTS_CF" ]] || die "No accounts for $ENV — run setup.sh $ENV first"

# ---------- --list
if [[ "${1:-}" == "--list" ]]; then
  log "Suspended mailboxes in ${ENV^^}"
  found=0
  while IFS='|' read -r addr hash; do
    [[ -z "$addr" ]] && continue
    if [[ "$hash" =~ ^\{[A-Z0-9-]+\}${SUSPEND_MARK} ]]; then echo "    $addr"; found=1; fi
  done < "$ACCOUNTS_CF"
  [[ $found -eq 1 ]] || echo "    (none)"
  if container_running; then
    log "Addresses with incoming mail blocked"
    docker exec "$CONTAINER" setup email restrict list receive 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  fi
  exit 0
fi

EMAIL_ARG="${1:-}"; MODE="${2:-}"
[[ -n "$EMAIL_ARG" ]] || usage_env "<email> [--block-incoming | --resume]   |   --list"
EMAIL="$(normalise_email "$EMAIL_ARG")"
is_valid_email "$EMAIL" || die "Not a valid address: $EMAIL_ARG"

lock_accounts
account_exists "$EMAIL" || die "$EMAIL is not a mailbox in ${ENV^^}"
HASH="$(account_hash "$EMAIL")"
SCHEME="${HASH%%\}*}}"          # e.g. {SHA512-CRYPT}
REST="${HASH#"$SCHEME"}"        # the hash itself

restrict_receive() {   # restrict_receive add|del
  container_running || { warn "Container not running — incoming-mail block not changed"; return 0; }
  if docker exec "$CONTAINER" setup email restrict "$1" receive "$EMAIL" >/dev/null 2>&1; then
    [[ "$1" == "add" ]] && ok "Incoming mail to $EMAIL will now bounce" || ok "Incoming mail to $EMAIL accepted again"
  else
    [[ "$1" == "del" ]] || warn "Could not block incoming mail — run: docker exec $CONTAINER setup email restrict add receive $EMAIL"
  fi
}

case "$MODE" in
  ""|--block-incoming)
    if is_suspended "$EMAIL"; then
      warn "$EMAIL is already suspended (login blocked)"
    else
      set_account_hash "$EMAIL" "${SCHEME}${SUSPEND_MARK}${REST}"
      annotate_credential "$EMAIL" "(SUSPENDED)"
      kick_sessions "$EMAIL"
      ok "Suspended $EMAIL — login refused, open sessions ended"
    fi
    if [[ "$MODE" == "--block-incoming" ]]; then
      restrict_receive add
    else
      echo "    New mail to $EMAIL is still delivered to the mailbox (use --block-incoming to bounce it)."
    fi
    ;;
  --resume)
    if is_suspended "$EMAIL"; then
      set_account_hash "$EMAIL" "${SCHEME}${REST#"$SUSPEND_MARK"}"
      annotate_credential "$EMAIL" "(resumed)"
      ok "Resumed $EMAIL — the previous password works again"
    else
      warn "$EMAIL was not suspended (login already allowed)"
    fi
    restrict_receive del
    ;;
  *) die "Unknown option: $MODE (use --block-incoming, --resume or --list)" ;;
esac
