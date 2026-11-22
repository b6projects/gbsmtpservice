#!/usr/bin/env bash
# Backs up mail, accounts, DKIM keys and credentials for an environment.
# Safe to run while the server is running (Maildir is file-per-message).
#
#   sudo ./scripts/backup.sh prd
#
# Cron (daily 02:30):
#   30 2 * * * /opt/gbsmtpservice/scripts/backup.sh prd >> /var/log/gbsmtp-backup.log 2>&1
#
# Copy BACKUP_DIR off the server (rclone / provider snapshots) — a backup on the
# same disk does not survive a disk failure.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env "${1:-}"

DEST="${BACKUP_DIR:-/var/backups/gbsmtp}/$ENV"
KEEP="${BACKUP_RETENTION_DAYS:-14}"
STAMP="$(date +%F_%H%M%S)"
FILE="$DEST/gbsmtp-$ENV-$STAMP.tar.gz"

mkdir -p "$DEST"; chmod 700 "$DEST"
log "Backing up $ENV -> $FILE"

tar -czf "$FILE" -C "$ROOT_DIR" \
  --exclude="data/$ENV/mail-logs" \
  "data/$ENV" "secrets/$ENV" "env/$ENV.env" "config/$ENV"
chmod 600 "$FILE"
ok "Backup size: $(du -h "$FILE" | cut -f1)"

find "$DEST" -name "gbsmtp-$ENV-*.tar.gz" -mtime +"$KEEP" -print -delete | sed 's/^/  pruned /'
ok "Done (keeping $KEEP days)"

# Restore:
#   ./scripts/stop.sh <env>
#   tar -xzf gbsmtp-<env>-<stamp>.tar.gz -C /opt/gbsmtpservice
#   ./scripts/start.sh <env>
