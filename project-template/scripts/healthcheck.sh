#!/usr/bin/env bash
# Check that the app answers {"status":"UP"} on its health endpoint.
# The request is made from inside the Tailscale sidecar (it shares the app's network),
# so it works even though the app image has no curl and no published ports.
#
#   scripts/healthcheck.sh                  wait up to 180s for UP
#   scripts/healthcheck.sh --timeout 30     custom wait
#   scripts/healthcheck.sh --public         also try the public https URL (warning only)
source "$(dirname "$0")/_lib.sh"

TIMEOUT=180; PUBLIC=
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="${2:?}"; shift ;;
    --public) PUBLIC=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
[ "$STACK_KIND" = app ] || die "healthcheck.sh is for app stacks (this is a $STACK_KIND stack)."

URL="http://127.0.0.1:${APP_PORT}${HEALTH_PATH}"
probe() {
  local out rc
  out="$(dc exec -T tailscale wget -q -T 5 -O - "$URL" 2>/dev/null)"; rc=$?
  if [ "$rc" = 127 ] || [ "$rc" = 126 ]; then   # no wget in the sidecar image: use busybox
    out="$(docker run --rm --network "container:$TS_CONTAINER" busybox:stable wget -q -T 5 -O - "$URL" 2>/dev/null)"; rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

container_running "$TS_CONTAINER" || die "The Tailscale sidecar ($TS_CONTAINER) is not running. Start the stack: scripts/up.sh"
info "Waiting for $URL to report UP (max ${TIMEOUT}s)"
end=$((SECONDS + TIMEOUT)); body=""; state=""
while :; do
  if body="$(probe)" && printf '%s' "$body" | grep -q '"status":"UP"'; then
    pass "Health: UP ($SERVICE_NAME$HEALTH_PATH)"
    break
  fi
  state="$(docker inspect -f '{{.State.Status}} (restarts: {{.RestartCount}})' "$SERVICE_NAME" 2>/dev/null || echo 'not created')"
  if [ "$SECONDS" -ge "$end" ]; then
    fail "Health check failed after ${TIMEOUT}s. App container: $state"
    [ -n "$body" ] && echo "  Last response: $(printf '%s' "$body" | head -c 300)" >&2
    cat >&2 <<EOF
  Common causes (README troubleshooting "Health check fails"):
    - the app crashed on startup (see the log below), e.g. wrong DB_HOST / password
    - spring-boot-starter-actuator is missing from pom.xml (404 on $HEALTH_PATH)
    - the app listens on a different port than APP_PORT=$APP_PORT
EOF
    echo "  Last app log lines:" >&2
    dc logs --no-color --tail 40 app >&2 || true
    exit 1
  fi
  sleep 3
done

if [ -n "$PUBLIC" ]; then
  dns="$(ts_json | jq -r '.Self.DNSName // empty')"; dns="${dns%.}"
  if [ -n "$dns" ] && curl -fsS -m 15 "https://$dns$HEALTH_PATH" >/dev/null 2>&1; then
    pass "Public URL works: https://$dns$HEALTH_PATH"
  else
    warn "Public URL https://$dns$HEALTH_PATH not reachable yet. The first time it can take ~10 minutes (DNS + certificate). Also check scripts/up.sh output for HTTPS/Funnel problems."
  fi
fi
