#!/usr/bin/env bash
# Back up the database to ~/backups/<name>-<date>.dump (keeps the newest 7).
#   scripts/backup.sh
# Restore (DANGER: overwrites data):
#   docker exec -i <name> sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' < file.dump
source "$(dirname "$0")/_lib.sh"
[ "$STACK_KIND" = db ] || die "backup.sh is for the database stack."
container_running "$SERVICE_NAME" || die "$SERVICE_NAME is not running (scripts/up.sh)."
dir="$HOME/backups"; mkdir -p "$dir"; chmod 700 "$dir"
out="$dir/$SERVICE_NAME-$(date +%Y%m%d-%H%M%S).dump"
docker exec "$SERVICE_NAME" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$out.part"
mv "$out.part" "$out"
pass "Backup written: $out ($(du -h "$out" | cut -f1))"
ls -1t "$dir/$SERVICE_NAME"-*.dump 2>/dev/null | tail -n +8 | xargs -r rm -f
