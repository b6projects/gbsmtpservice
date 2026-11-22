#!/usr/bin/env bash
# Stop an environment. Mail data in data/<env>/ is kept.
# Mail sent to you while stopped is retried by the sending servers (typically for up to 5 days).
#
#   ./scripts/stop.sh prd

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env "${1:-}"
require_cmd docker

log "Stopping $CONTAINER (data in data/$ENV/ is preserved)"
"${COMPOSE[@]}" down
ok "Stopped"
