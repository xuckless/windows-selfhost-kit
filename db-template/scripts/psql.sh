#!/usr/bin/env bash
# Open a psql prompt inside the database container (no password needed).
#   scripts/psql.sh                 interactive prompt
#   scripts/psql.sh -c 'select 1'   run one command
source "$(dirname "$0")/_lib.sh"
[ "$STACK_KIND" = db ] || die "psql.sh is for the database stack."
tty=(); [ -t 0 ] && tty=(-it) || tty=(-i)
exec docker exec "${tty[@]}" "$SERVICE_NAME" sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' psql "$@"
