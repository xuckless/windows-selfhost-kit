#!/usr/bin/env bash
# Start this stack (Tailscale sidecar + app, or + database) and check that it works.
#
#   scripts/up.sh            start (builds the app image only if it doesn't exist yet)
#   scripts/up.sh --build    rebuild the app image from this folder, then start
#   scripts/up.sh --pull     also download newer Tailscale/Postgres images
#
# Exit codes: 0 = all good, 1 = failed, 2 = running but not reachable from the internet yet.
source "$(dirname "$0")/_lib.sh"

BUILD=; PULL=
for a in "$@"; do
  case "$a" in
    --build) BUILD=1 ;;
    --pull) PULL=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "Unknown option: $a (see --help)" ;;
  esac
done

# ---- 1. preflight -------------------------------------------------------------
info "Checking $SERVICE_NAME ($STACK_DIR)"
require_docker
grep -qi 'microsoft-standard' /proc/sys/kernel/osrelease 2>/dev/null || warn "Not running inside WSL2 (fine for testing on Linux)."
case "$STACK_DIR" in
  /mnt/*) die "This folder is on the Windows drive ($STACK_DIR). Stacks must live in the Linux filesystem, e.g. ~/apps/<name> (README Part E)." ;;
esac
[ -c /dev/net/tun ] || die "/dev/net/tun is missing. Run: sudo modprobe tun   (README troubleshooting: /dev/net/tun)"
[ -f .env ] || die ".env is missing. Run: cp .env.example .env   then set the values (README Part E)."
normalize_env

if ! env_has TS_AUTHKEY && ! docker volume inspect "$STATE_VOLUME" >/dev/null 2>&1; then
  die "TS_AUTHKEY is not set and this machine has never logged in. HUMAN step: scripts/env.sh secret TS_AUTHKEY"
fi

if [ "$STACK_KIND" = app ]; then
  uid="$(env_get APP_UID)"
  [ -z "$uid" ] || [ "$uid" = "$(id -u)" ] || warn "APP_UID in .env is $uid but your user id is $(id -u). Fix: scripts/env.sh set APP_UID $(id -u)"
  grep -q "127.0.0.1:${APP_PORT}\"" ts-serve.json || warn "ts-serve.json does not proxy to 127.0.0.1:${APP_PORT} (APP_PORT in scripts/stack.env)."
  if grep -q 'SPRING_DATASOURCE_URL' docker-compose.yml; then
    env_has DB_HOST || warn "DB_HOST is empty in .env: the app will not reach its database. Fix: scripts/env.sh set DB_HOST <100.x IP of the DB>"
    env_has POSTGRES_PASSWORD || warn "POSTGRES_PASSWORD is empty in .env. HUMAN step: scripts/env.sh secret POSTGRES_PASSWORD --from ~/apps/<db>/.env"
  fi
  if env_get SPRING_PROFILES_ACTIVE | grep -qw mtls; then
    for f in certs/ca.crt "certs/$SERVICE_NAME.crt" "certs/$SERVICE_NAME.key"; do
      [ -f "$f" ] || die "mTLS is on (SPRING_PROFILES_ACTIVE has mtls) but $f is missing. Run mtls/install-certs.sh (README Part G)."
    done
  fi
else
  env_has POSTGRES_PASSWORD || die "POSTGRES_PASSWORD is not set. HUMAN step: scripts/env.sh secret POSTGRES_PASSWORD --generate"
fi

# ---- 2. start the sidecar first and wait until it is on the tailnet ----------------
if [ -n "$PULL" ]; then
  info "Downloading newer images"
  dc pull --ignore-buildable
fi
info "Starting the Tailscale sidecar ($TS_CONTAINER)"
dc up -d tailscale
wait_tailnet 120 || exit 1
json="$(ts_json)"
ip="$(printf '%s' "$json" | jq -r '.Self.TailscaleIPs[0] // empty')"
dns="$(printf '%s' "$json" | jq -r '.Self.DNSName // empty')"; dns="${dns%.}"
expiry="$(printf '%s' "$json" | jq -r '.Self.KeyExpiry // empty')"
pass "On the tailnet as ${dns:-$SERVICE_NAME} ($ip)"

# ---- 3. start the app / database ------------------------------------------------------
info "Starting $MAIN_SERVICE"
if [ -n "$BUILD" ]; then
  GIT_SHA="${GIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo dev)}" dc up -d --build "$MAIN_SERVICE"
else
  dc up -d "$MAIN_SERVICE"
fi
fix_stale_netns

# ---- 4. health -----------------------------------------------------------------
rc=0
if [ "$STACK_KIND" = app ]; then
  "$STACK_DIR/scripts/healthcheck.sh" --timeout 180 || exit 1
else
  info "Waiting for Postgres to accept connections"
  end=$((SECONDS + 120))
  until [ "$(container_health "$SERVICE_NAME")" = healthy ]; do
    [ "$SECONDS" -lt "$end" ] || { dc logs --no-color --tail 30 postgres >&2; die "Postgres did not become healthy."; }
    sleep 3
  done
  pass "Postgres is accepting connections"
fi

# ---- 5. public exposure checks (app only) ------------------------------------------------
problems=()
if [ "$STACK_KIND" = app ]; then
  if [ "$(printf '%s' "$json" | jq -r '(.CertDomains // []) | length')" = 0 ]; then
    problems+=("HTTPS certificates are OFF for your tailnet. Fix: https://login.tailscale.com/admin/dns -> 'HTTPS Certificates' -> Enable HTTPS. Then run scripts/up.sh again.")
  fi
  if [ "$(printf '%s' "$json" | jq -r '(.Self.CapMap // {}) | any(keys[]; test("funnel"))')" != true ]; then
    problems+=("Funnel is not allowed for this machine. Fix: https://login.tailscale.com/admin/acls -> in the Funnel section click 'Add Funnel to policy' (or add nodeAttrs {\"target\":[\"autogroup:member\"],\"attr\":[\"funnel\"]}). Then run scripts/up.sh again.")
  fi
fi

register_stack

echo
echo "  Service:      $SERVICE_NAME"
echo "  Tailnet IP:   $ip   (use this for DB_HOST / mTLS peers)"
if [ "$STACK_KIND" = app ]; then
  echo "  Public URL:   https://$dns"
  echo "  Health:       https://$dns$HEALTH_PATH"
else
  echo "  JDBC URL:     jdbc:postgresql://$ip:5432/$(env_get POSTGRES_DB)   user: $(env_get POSTGRES_USER)"
  echo "  From Windows: localhost:5432 (e.g. IntelliJ/DBeaver)"
fi
if [ -n "$expiry" ]; then
  echo "  Key expiry:   ON (expires $expiry)"
  warn "HUMAN step: turn off key expiry so this machine never gets logged out: https://login.tailscale.com/admin/machines -> $SERVICE_NAME -> '...' menu -> Disable key expiry"
else
  echo "  Key expiry:   disabled (good)"
fi
for p in "${problems[@]}"; do fail "$p"; rc=2; done
[ "$rc" = 0 ] && [ "$STACK_KIND" = app ] && echo "  Note: the very first time, the public URL can take up to ~10 minutes to start working (DNS + certificate)."
exit "$rc"
