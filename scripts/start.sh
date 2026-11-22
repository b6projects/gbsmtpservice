#!/usr/bin/env bash
# Start (or restart) an environment.
#
#   ./scripts/start.sh prd            start / apply compose changes
#   ./scripts/start.sh prd --restart  restart the running container
#   ./scripts/start.sh prd --pull     pull the image first, then recreate (upgrade)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env "${1:-}"; shift || true
require_cmd docker

[[ -s "$ACCOUNTS_CF" ]] || die "No mailboxes provisioned for $ENV — run ./scripts/setup.sh $ENV first"

case "${1:-}" in
  --restart)
    log "Restarting $CONTAINER"
    docker restart "$CONTAINER" >/dev/null ;;
  --pull)
    log "Pulling image and recreating $CONTAINER"
    "${COMPOSE[@]}" pull
    "${COMPOSE[@]}" up -d ;;
  "")
    log "Starting $CONTAINER ($MAIL_HOSTNAME)"
    "${COMPOSE[@]}" up -d ;;
  *) die "Unknown option: $1" ;;
esac

wait_healthy 240
fix_dkim_permissions
"${COMPOSE[@]}" ps
