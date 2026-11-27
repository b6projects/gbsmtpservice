#!/usr/bin/env bash
# Report storage used, quota and balance for every mailbox.
#
#   bash scripts/quota-report.sh prd                      # all domains
#   bash scripts/quota-report.sh prd goldnpay.in          # one domain
#   bash scripts/quota-report.sh prd --csv > report.csv   # CSV (also: prd goldnpay.in --csv)
#
# - Reads live usage from Dovecot inside the container (doveadm quota get), so the
#   container must be running.
# - Accounts with no quota set show "unlimited" and no balance.
# - Needs permission to run `docker exec` (root or a member of the docker group).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_ARG="${1:-}"
[[ -n "$ENV_ARG" ]] || usage_env "[domain] [--csv]"
shift
load_env "$ENV_ARG"
require_cmd docker awk

DOMAIN_ARG=""; CSV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) CSV=1; shift ;;
    -*)    die "Unknown option: $1" ;;
    *)     [[ -z "$DOMAIN_ARG" ]] || die "Only one domain can be given"; DOMAIN_ARG="${1,,}"; shift ;;
  esac
done

container_running || die "$CONTAINER is not running — start it with: bash scripts/start.sh $ENV"
[[ -f "$ACCOUNTS_CF" ]] || die "No accounts file for $ENV ($ACCOUNTS_CF)"

# Mailboxes actually provisioned (source of truth is the live accounts file)
mapfile -t ADDRESSES < <(awk -F'|' 'NF && $1 !~ /^[[:space:]]*#/ {print tolower($1)}' "$ACCOUNTS_CF" | sort -t@ -k2,2 -k1,1)

if [[ -n "$DOMAIN_ARG" ]]; then
  filtered=()
  for a in "${ADDRESSES[@]}"; do [[ "${a#*@}" == "$DOMAIN_ARG" ]] && filtered+=("$a"); done
  [[ ${#filtered[@]} -gt 0 ]] || die "No mailboxes found for domain '$DOMAIN_ARG' in ${ENV^^}"
  ADDRESSES=("${filtered[@]}")
fi
[[ ${#ADDRESSES[@]} -gt 0 ]] || die "No mailboxes found in ${ENV^^}"

# Human readable size from KiB
human() {
  awk -v k="$1" 'BEGIN {
    if (k < 1024)            printf "%d KB", k
    else if (k < 1048576)    printf "%.1f MB", k/1024
    else                     printf "%.2f GB", k/1048576
  }'
}

# One mailbox: prints "used_kb<TAB>limit_kb" (limit_kb empty when unlimited)
quota_of() {
  local out
  out="$(docker exec "$CONTAINER" doveadm -f tab quota get -u "$1" 2>/dev/null || true)"
  awk -F'\t' 'NR>1 && $2=="STORAGE" { used=$3; limit=$4 }
              END { if (used=="") used=0; if (limit=="-") limit=""; print used "\t" limit }' <<<"$out"
}

if [[ $CSV -eq 1 ]]; then
  echo "domain,email,used_kb,quota_kb,balance_kb,percent_used"
else
  printf '%-40s %12s %12s %12s %7s\n' "EMAIL" "USED" "QUOTA" "BALANCE" "USED%"
  printf '%-40s %12s %12s %12s %7s\n' "-----" "----" "-----" "-------" "-----"
fi

current_domain=""; dom_used=0; dom_count=0; tot_used=0; tot_count=0
flush_domain() {
  [[ -n "$current_domain" && $CSV -eq 0 ]] || return 0
  printf '%-40s %12s\n' "  subtotal $current_domain ($dom_count mailboxes)" "$(human "$dom_used")"
}

for email in "${ADDRESSES[@]}"; do
  domain="${email#*@}"
  if [[ "$domain" != "$current_domain" ]]; then
    flush_domain
    [[ $CSV -eq 1 ]] || printf '\n[%s]\n' "$domain"
    current_domain="$domain"; dom_used=0; dom_count=0
  fi

  IFS=$'\t' read -r used limit <<<"$(quota_of "$email")"
  used="${used:-0}"
  dom_used=$((dom_used + used)); dom_count=$((dom_count + 1))
  tot_used=$((tot_used + used)); tot_count=$((tot_count + 1))

  if [[ -n "$limit" && "$limit" -gt 0 ]]; then
    balance=$((limit - used)); (( balance < 0 )) && balance=0
    pct="$(awk -v u="$used" -v l="$limit" 'BEGIN { printf "%.1f", u*100/l }')"
    if [[ $CSV -eq 1 ]]; then
      echo "$domain,$email,$used,$limit,$balance,$pct"
    else
      printf '%-40s %12s %12s %12s %6s%%\n' "$email" "$(human "$used")" "$(human "$limit")" "$(human "$balance")" "$pct"
    fi
  else
    if [[ $CSV -eq 1 ]]; then
      echo "$domain,$email,$used,unlimited,,"
    else
      printf '%-40s %12s %12s %12s %7s\n' "$email" "$(human "$used")" "unlimited" "-" "-"
    fi
  fi
done
flush_domain

if [[ $CSV -eq 0 ]]; then
  printf '\n%s: %d mailboxes, %s used in total\n' "${DOMAIN_ARG:-All domains (${ENV^^})}" "$tot_count" "$(human "$tot_used")"
fi
