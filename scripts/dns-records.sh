#!/usr/bin/env bash
# Prints the DNS records to publish for an environment and saves them to
# dns/<env>-dns-records.txt. Run after setup.sh (needs the DKIM keys).
#
#   ./scripts/dns-records.sh prd

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env "${1:-}"
require_cmd openssl

IP="$(detect_public_ip)"
POLICY="${DMARC_POLICY:-none}"

# Split a long TXT value into quoted 250-char strings (for registrars with a 255-char limit)
split_txt() {
  local s="$1" out=""
  while [[ -n "$s" ]]; do out+="\"${s:0:250}\" "; s="${s:250}"; done
  echo "${out% }"
}

{
  echo "# ======================================================================"
  echo "# DNS records for GB SMTP Service — ${ENV^^}"
  echo "# Mail host: $MAIL_HOSTNAME    Server IP: $IP"
  echo "# Generated: $(date '+%F %T')"
  echo "# ======================================================================"
  echo "#"
  echo "# If a domain already has an SPF record (e.g. Google Workspace, Zoho, an ESP),"
  echo "# MERGE the mechanisms into ONE record — a domain must never have two SPF TXT records."
  echo "# Only change MX if this server should RECEIVE that domain's mail."
  echo
  echo "## Mail host (publish once, in the goldbucks.org zone)"
  printf '%-6s %-45s %s\n' "A" "$MAIL_HOSTNAME." "$IP"
  printf '%-6s %-45s %s\n' "PTR" "$IP" "$MAIL_HOSTNAME.   <- set in the VPS provider panel, not at the registrar"
  echo

  while read -r dom; do
    key="$(dkim_key_path "$dom")"
    echo "## $dom"
    printf '%-6s %-45s %s\n' "MX"  "$dom." "10 $MAIL_HOSTNAME."
    printf '%-6s %-45s %s\n' "TXT" "$dom." "\"v=spf1 ip4:$IP mx -all\""
    printf '%-6s %-45s %s\n' "TXT" "_dmarc.$dom." "\"v=DMARC1; p=$POLICY; rua=mailto:dmarc@$dom; fo=1\""
    if [[ -f "$key" ]]; then
      dkim="v=DKIM1; k=rsa; p=$(dkim_public_b64 "$dom")"
      printf '%-6s %-45s %s\n' "TXT" "$DKIM_SELECTOR._domainkey.$dom." "\"$dkim\""
      echo "#   If your registrar limits TXT values to 255 characters, paste this split form instead:"
      echo "#   $(split_txt "$dkim")"
    else
      echo "#   DKIM key not generated yet — run ./scripts/setup.sh $ENV"
    fi
    echo
  done < <(domains)

  echo "## Registrar 'Host' field hints"
  echo "#  Most registrars want the host RELATIVE to the zone, e.g. in the goldnpay.in zone:"
  echo "#    MX  @              -> 10 $MAIL_HOSTNAME"
  echo "#    TXT @              -> v=spf1 ..."
  echo "#    TXT _dmarc         -> v=DMARC1 ..."
  echo "#    TXT mail._domainkey -> v=DKIM1 ..."
  if [[ "$ENV" == "uat" ]]; then
    echo "#  UAT sub-domains live inside the parent zone, e.g. in the goldnpay.in zone:"
    echo "#    MX  uatmail                 -> 10 $MAIL_HOSTNAME"
    echo "#    TXT uatmail                 -> v=spf1 ..."
    echo "#    TXT _dmarc.uatmail          -> v=DMARC1 ..."
    echo "#    TXT mail._domainkey.uatmail -> v=DKIM1 ..."
  fi
} | tee "$DNS_OUT"
