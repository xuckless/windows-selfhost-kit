# shellcheck shell=bash
# Shared helpers for the machine-level scripts in wsl/. Source it, don't run it.
# Never prints secret values: env_has/env_state only report set/empty/missing.

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
next() { printf '%sNEXT:%s %s\n' "$C_YEL" "$C_OFF" "$*"; }

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed. Run wsl/bootstrap.sh first."
  done
}

# is_wsl2: true on a WSL2 kernel (WSL1 kernels are "4.4.0-xxxxx-Microsoft").
is_wsl2() { grep -qi 'microsoft-standard' /proc/sys/kernel/osrelease 2>/dev/null; }
is_wsl1() { grep -q 'Microsoft' /proc/sys/kernel/osrelease 2>/dev/null && ! is_wsl2; }

# ---- user / root handling ----------------------------------------------------
# Scripts may run as the normal user (and use sudo) or as root via
# "wsl-run.ps1 -Root" (no password prompt). KIT_USER is the normal Linux user.
detect_kit_user() {
  if [ -n "${KIT_USER:-}" ]; then :
  elif [ "$(id -u)" -ne 0 ]; then KIT_USER="$(id -un)"
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then KIT_USER="$SUDO_USER"
  else KIT_USER="$(getent passwd 1000 | cut -d: -f1)"
  fi
  [ -n "$KIT_USER" ] || die "Could not work out your Linux user name. Pass --user <name>."
  KIT_HOME="${KIT_HOME:-$(getent passwd "$KIT_USER" | cut -d: -f6)}"
  export KIT_USER KIT_HOME
}

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$KIT_USER" != root ]; then
    runuser -u "$KIT_USER" -- env HOME="$KIT_HOME" "$@"
  else
    "$@"
  fi
}

# ---- kit.env -----------------------------------------------------------------
# Parses KEY=VALUE lines without executing anything.
load_kit_env() {
  local file="${1:-$KIT_DIR/kit.env}" line key val
  [ -f "$file" ] || die "Missing $file. Copy kit.env.example to kit.env, fill it in, then re-run 'setup-windows.ps1 -Phase Stage'."
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    printf -v "$key" '%s' "$val"
    export "${key?}"
  done < "$file"
  : "${APP_PORT:=8080}" "${JAVA_VERSION:=21}" "${BRANCH:=main}" "${DISTRO:=Ubuntu-24.04}"
  : "${WITH_DB:=yes}" "${WITH_MTLS:=no}" "${RUNNER_LABEL:=wsl}"
  : "${HEALTH_PATH:=/actuator/health}" "${MTLS_PORT:=8443}"
  [ -n "${DB_SERVICE_NAME:-}" ] || DB_SERVICE_NAME="${SERVICE_NAME:-app}-db"
  export APP_PORT JAVA_VERSION BRANCH DISTRO WITH_DB WITH_MTLS RUNNER_LABEL HEALTH_PATH MTLS_PORT DB_SERVICE_NAME
}

validate_kit_env() {
  local bad=0 n
  for n in GITHUB_OWNER REPO SERVICE_NAME; do
    case "${!n:-}" in ''|your-*) fail "kit.env: set $n"; bad=1 ;; esac
  done
  for n in SERVICE_NAME DB_SERVICE_NAME; do
    [[ "${!n:-}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { fail "kit.env: $n='${!n:-}' must be lowercase letters, digits and '-' (max 63)"; bad=1; }
  done
  [[ "$APP_PORT" =~ ^[0-9]+$ ]] || { fail "kit.env: APP_PORT must be a number"; bad=1; }
  [[ "$JAVA_VERSION" =~ ^[0-9]+$ ]] || { fail "kit.env: JAVA_VERSION must be a number like 21"; bad=1; }
  [ "$bad" -eq 0 ] || die "Fix kit.env (in the Windows kit folder), re-run 'setup-windows.ps1 -Phase Stage', then retry."
}

# ---- .env helpers (values are never printed) ----------------------------------
# env_state FILE KEY -> "set" | "EMPTY" | "MISSING"
env_state() {
  local line
  line="$(grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -n1)" || true
  if [ -z "$line" ]; then echo MISSING
  else
    line="${line#*=}"; line="${line%$'\r'}"; line="${line#\"}"; line="${line%\"}"
    if [ -n "$line" ]; then echo set; else echo EMPTY; fi
  fi
}
env_has() { [ "$(env_state "$1" "$2")" = set ]; }

# ---- stack registry ------------------------------------------------------------
# One "<kind> <dir>" line per stack; kind is db or app. db stacks start first.
stacks_file() { echo "${KIT_HOME:-$HOME}/.config/selfhost-kit/stacks"; }
list_stacks() {
  local f; f="$(stacks_file)"
  [ -f "$f" ] || return 0
  { grep -E '^db ' "$f" || true; grep -E '^app ' "$f" || true; } | while read -r _kind dir; do
    [ -d "$dir" ] && echo "$dir"
  done
}
register_stack() {
  local kind="$1" dir="$2" f; f="$(stacks_file)"
  mkdir -p "$(dirname "$f")"
  touch "$f"
  grep -qxF "$kind $dir" "$f" || echo "$kind $dir" >> "$f"
}
