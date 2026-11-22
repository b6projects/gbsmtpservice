#!/usr/bin/env bash
# Health, mailboxes, aliases, mail queue and certificate expiry for an environment.
#
#   ./scripts/status.sh prd

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env "${1:-}"
require_cmd docker

log "Container"
"${COMPOSE[@]}" ps
container_running || die "$CONTAINER is not running — ./scripts/start.sh $ENV"

echo; log "Mailboxes"
docker exec "$CONTAINER" setup email list || true

echo; log "Aliases"
docker exec "$CONTAINER" setup alias list || true

echo; log "Mail queue"
docker exec "$CONTAINER" postqueue -p || true

echo; log "TLS certificate"
docker exec "$CONTAINER" bash -c \
  "openssl x509 -in /etc/letsencrypt/live/$MAIL_HOSTNAME/fullchain.pem -noout -subject -enddate 2>/dev/null" \
  || warn "No certificate found for $MAIL_HOSTNAME"

echo; log "Last 20 mail log lines"
docker exec "$CONTAINER" tail -n 20 /var/log/mail/mail.log 2>/dev/null || docker logs --tail 20 "$CONTAINER"
