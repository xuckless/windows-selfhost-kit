#!/usr/bin/env bash
# Stop this stack.
#
#   scripts/down.sh          stop the containers (fast to start again with scripts/up.sh)
#   scripts/down.sh --rm     stop and remove the containers (data and identity are kept)
#
# Deleting the volumes (docker compose down -v) is refused on purpose: it wipes the
# Tailscale identity (new machine name/URL) and, for a database, ALL its data.
source "$(dirname "$0")/_lib.sh"
require_docker
case "${1:-}" in
  "") info "Stopping $SERVICE_NAME"; dc stop ;;
  --rm) info "Removing $SERVICE_NAME containers (volumes kept)"; dc down ;;
  -v|--volumes)
    if [ "${2:-}" = --i-know-this-resets-tailscale-identity ]; then
      warn "Deleting containers AND volumes of $SERVICE_NAME"; dc down -v
      warn "Also delete the old machine in https://login.tailscale.com/admin/machines before starting again."
    else
      die "Refusing to delete volumes: this resets the Tailscale identity (and deletes database data). If you are sure: scripts/down.sh -v --i-know-this-resets-tailscale-identity"
    fi ;;
  -h|--help) sed -n '2,9p' "$0" ;;
  *) die "Unknown option: $1 (see --help)" ;;
esac
