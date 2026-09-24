# shellcheck shell=bash
# Shared helpers for this stack's scripts. Sourced by up.sh, status.sh, down.sh,
# deploy.sh, healthcheck.sh, env.sh (and backup.sh/psql.sh for a database stack).
# Rule: nothing here prints a secret value from .env.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"

if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_OFF=$'\e[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_OFF=
fi
info() { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
pass() { printf '%s[PASS]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { fail "$*"; exit 1; }

# ---- stack settings (scripts/stack.env, committed, not secret) ----------------
[ -f scripts/stack.env ] || die "scripts/stack.env is missing in $STACK_DIR"
while IFS= read -r _line || [ -n "$_line" ]; do
  _line="${_line%$'\r'}"
  case "$_line" in ''|'#'*) continue ;; esac
  [[ "${_line%%=*}" =~ ^[A-Z_][A-Z0-9_]*$ ]] && printf -v "${_line%%=*}" '%s' "${_line#*=}"
done < scripts/stack.env
unset _line
: "${STACK_KIND:=app}" "${SERVICE_NAME:?SERVICE_NAME missing in scripts/stack.env}"
: "${APP_PORT:=8080}" "${HEALTH_PATH:=/actuator/health}" "${MTLS_PORT:=8443}"
if [ "$STACK_KIND" = db ]; then MAIN_SERVICE=postgres; else MAIN_SERVICE=app; fi
TS_CONTAINER="${SERVICE_NAME}-ts"
STATE_VOLUME="${SERVICE_NAME}_tailscale-state"   # used by up.sh and env.sh
export STATE_VOLUME TS_CONTAINER MAIN_SERVICE

dc() { docker compose "$@"; }

# ---- .env helpers --------------------------------------------------------------
# env_get KEY -> value (internal use only: never echo secrets to the screen)
env_get() {
  local line
  line="$(grep -E "^[[:space:]]*$1=" .env 2>/dev/null | tail -n1)" || true
  line="${line#*=}"; line="${line%$'\r'}"
  line="${line#\"}"; line="${line%\"}"; line="${line#\'}"; line="${line%\'}"
  printf '%s' "$line"
}
env_state() {
  if ! grep -qE "^[[:space:]]*$1=" .env 2>/dev/null; then echo MISSING
  elif [ -n "$(env_get "$1")" ]; then echo set
  else echo EMPTY
  fi
}
env_has() { [ "$(env_state "$1")" = set ]; }

# Remove Windows line endings from .env and make it private (owner read/write only).
normalize_env() {
  [ -f .env ] || return 0
  if grep -q $'\r' .env; then sed -i 's/\r$//' .env; warn ".env had Windows (CRLF) line endings; fixed."; fi
  chmod 600 .env
}

# ---- docker / tailscale helpers -------------------------------------------------
require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run wsl/bootstrap.sh (README Part A)."
  command -v jq >/dev/null 2>&1 || die "jq is not installed. Run wsl/bootstrap.sh (README Part A)."
  local err
  if ! err="$(docker info 2>&1 >/dev/null)"; then
    if printf '%s' "$err" | grep -qi 'permission denied'; then
      die "No permission to use Docker. Your user was just added to the 'docker' group: from Windows run 'wsl --terminate <distro>', open Ubuntu again and retry."
    fi
    die "Docker is not running. Try: sudo systemctl start docker   (then retry)"
  fi
}

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
container_health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo missing; }
started_ns() { date -d "$(docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null)" +%s%N 2>/dev/null || echo 0; }

# tailscale status --json from inside the sidecar ("" if not available)
ts_json() { dc exec -T tailscale tailscale status --json 2>/dev/null || true; }

# If the sidecar restarted after the app/db started, the app is stuck in the old,
# dead network namespace. Recreate it (fast, no rebuild).
fix_stale_netns() {
  container_running "$SERVICE_NAME" || return 0
  container_running "$TS_CONTAINER" || return 0
  if [ "$(started_ns "$SERVICE_NAME")" -lt "$(started_ns "$TS_CONTAINER")" ]; then
    warn "The Tailscale sidecar restarted after $SERVICE_NAME; reconnecting $SERVICE_NAME to it."
    dc up -d --no-deps --no-build --force-recreate "$MAIN_SERVICE"
  fi
}

# Wait until the sidecar reports BackendState=Running. Returns 1 with advice on failure.
wait_tailnet() {
  local timeout="${1:-120}" end state="" json keyerr=""
  end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    json="$(ts_json)"
    state="$(printf '%s' "$json" | jq -r '.BackendState // empty' 2>/dev/null || true)"
    [ "$state" = Running ] && return 0
    # Tailscale rejected the key: no point waiting any longer.
    keyerr="$(docker logs "$TS_CONTAINER" 2>&1 | grep -m1 -iE 'invalid key|key does not exist|key (has )?expired|not authorized' \
              | sed -E 's/tskey-[A-Za-z0-9_-]+/tskey-REDACTED/g' || true)"
    [ -n "$keyerr" ] && break
    sleep 3
  done
  if [ -n "$keyerr" ]; then
    fail "Tailscale rejected the auth key: ${keyerr#* * }"
  else
    fail "Tailscale did not come online within ${timeout}s (state: ${state:-unknown})."
  fi
  if [ -n "$keyerr" ] || [ "$state" = NeedsLogin ] || [ -z "$state" ]; then
    cat >&2 <<EOF
  Most likely the auth key is wrong, expired, already used (not reusable), or was
  pasted with extra characters. Fix:
    1. https://login.tailscale.com/admin/settings/keys -> Generate auth key
       (Reusable: ON, Ephemeral: OFF, no tags). Copy it.
    2. scripts/env.sh secret TS_AUTHKEY      (paste it; typing is hidden)
    3. scripts/up.sh
EOF
  fi
  echo "  Last sidecar log lines:" >&2
  dc logs --no-color --tail 15 tailscale 2>&1 | sed -E 's/tskey-[A-Za-z0-9_-]+/tskey-REDACTED/g' >&2 || true
  return 1
}

# ---- stack registry (used by wsl/selfhost.sh to start everything) ----------------
register_stack() {
  case "$STACK_DIR" in /mnt/*) return 0 ;; esac
  local f="$HOME/.config/selfhost-kit/stacks"
  mkdir -p "$(dirname "$f")"; touch "$f"
  grep -qxF "$STACK_KIND $STACK_DIR" "$f" || echo "$STACK_KIND $STACK_DIR" >> "$f"
}
