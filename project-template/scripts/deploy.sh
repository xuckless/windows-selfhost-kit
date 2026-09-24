#!/usr/bin/env bash
# Rebuild and restart ONLY the app container. Used by the GitHub Actions deploy job,
# but you can run it by hand too. The Tailscale sidecar is never recreated, so the
# machine name, tailnet IP and public URL never change.
#
#   scripts/deploy.sh              build the current folder and restart the app
#   scripts/deploy.sh --rollback   go back to the image that ran before the last deploy
source "$(dirname "$0")/_lib.sh"
[ "$STACK_KIND" = app ] || die "deploy.sh is for app stacks."
require_docker
[ -f .env ] || die ".env is missing in $STACK_DIR (README Part E)."
normalize_env

IMG="${SERVICE_NAME}-app"

if [ "${1:-}" = --rollback ]; then
  docker image inspect "$IMG:previous" >/dev/null 2>&1 || die "No previous image to roll back to."
  info "Rolling back $SERVICE_NAME to the previous image"
  docker tag "$IMG:previous" "$IMG:latest"
  dc up -d --no-deps --no-build --force-recreate app
  pass "Rolled back. Check it with: scripts/healthcheck.sh"
  exit 0
fi
[ $# -eq 0 ] || die "Unknown option: $1"

# The sidecar must be up (the app lives inside its network). Start it if needed.
if [ "$(container_health "$TS_CONTAINER")" != healthy ]; then
  info "Tailscale sidecar is not healthy; starting it"
  dc up -d tailscale
  end=$((SECONDS + 120))
  until [ "$(container_health "$TS_CONTAINER")" = healthy ]; do
    [ "$SECONDS" -lt "$end" ] || { wait_tailnet 5 || true; die "Tailscale sidecar did not become healthy."; }
    sleep 3
  done
fi

if docker image inspect "$IMG:latest" >/dev/null 2>&1; then
  docker tag "$IMG:latest" "$IMG:previous"
fi

GIT_SHA="${GIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo dev)}"
export GIT_SHA
info "Building $IMG (revision ${GIT_SHA:0:12})"
dc build app          # if this fails, the running app is untouched

info "Restarting the app container only"
dc up -d --no-deps --no-build --force-recreate app

want="$(docker image inspect -f '{{.Id}}' "$IMG:latest")"
have="$(docker inspect -f '{{.Image}}' "$SERVICE_NAME")"
[ "$want" = "$have" ] || die "The app container is not running the new image ($have vs $want)."
docker image prune -f >/dev/null 2>&1 || true
pass "Deployed revision ${GIT_SHA:0:12}. Next: scripts/healthcheck.sh"
