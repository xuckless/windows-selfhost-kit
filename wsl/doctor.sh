#!/usr/bin/env bash
# Check the whole setup and print PASS / WARN / FAIL for every item, with a fix.
# Changes nothing and never prints secrets. AI agents: use this as your "Verify" step.
#
#   ~/selfhost-kit/wsl/doctor.sh
# Exit code: 0 = no FAIL, 1 = at least one FAIL.
set -uo pipefail
# shellcheck source=wsl/lib.sh
source "$(dirname "$0")/lib.sh"
detect_kit_user
NP=0; NW=0; NF=0
ok()   { pass "$*"; NP=$((NP+1)); }
wn()   { warn "$*"; NW=$((NW+1)); }
bad()  { fail "$*"; NF=$((NF+1)); }

echo "== Machine"
if is_wsl2; then ok "WSL2 kernel ($(uname -r))"
elif is_wsl1; then bad "This is WSL1. From Windows: wsl --set-version <distro> 2"
else wn "Not WSL2 ($(uname -r)); fine only for testing on plain Linux"; fi
[ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ] && ok "systemd is PID 1" || bad "systemd is off. Run wsl/bootstrap.sh, then from Windows: wsl --shutdown"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then ok "Docker works for $(id -un) ($(docker --version | cut -d, -f1))"
  elif id -nG | grep -qw docker; then bad "Docker is not running: sudo systemctl start docker"
  else bad "No Docker permission: from Windows run  wsl --terminate <distro>  and reopen Ubuntu"; fi
  docker compose version >/dev/null 2>&1 && ok "docker compose v2" || bad "docker compose plugin missing: run wsl/bootstrap.sh"
  docker buildx version >/dev/null 2>&1 && ok "docker buildx" || wn "docker buildx missing (builds are slower): run wsl/bootstrap.sh"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled --quiet docker 2>/dev/null && ok "Docker starts automatically" || wn "Docker is not enabled at boot: sudo systemctl enable docker"
  fi
else
  bad "Docker is not installed: run wsl/bootstrap.sh"
fi
[ -c /dev/net/tun ] && ok "/dev/net/tun present" || bad "/dev/net/tun missing: sudo modprobe tun (or wsl --update from Windows)"
for c in jq git gh openssl curl; do command -v "$c" >/dev/null 2>&1 || bad "$c missing: run wsl/bootstrap.sh"; done
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ok "GitHub CLI logged in"
  else bad "GitHub CLI not logged in. HUMAN: gh auth login -h github.com -p https -w -s workflow"; fi
  git config --global --get-regexp '^credential\..*helper' 2>/dev/null | grep -q 'gh auth git-credential' \
    && ok "git uses gh for GitHub logins" || wn "git is not using gh for logins: run  gh auth setup-git"
fi
if [ -f "$KIT_DIR/kit.env" ]; then
  if (load_kit_env && validate_kit_env) >/dev/null 2>&1; then ok "kit.env is filled in"; else bad "kit.env has unfilled values (see kit.env.example)"; fi
else
  bad "kit.env missing in $KIT_DIR (copy kit.env.example to kit.env on Windows, then Stage again)"
fi
if command -v powershell.exe >/dev/null 2>&1; then
  wslcfg="$(wslpath "$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r')" 2>/dev/null)/.wslconfig"
  if grep -qiE '^[[:space:]]*instanceIdleTimeout[[:space:]]*=[[:space:]]*-1' "$wslcfg" 2>/dev/null; then ok ".wslconfig keeps WSL running (instanceIdleTimeout=-1)"
  else wn ".wslconfig does not keep WSL running: run  setup-windows.ps1 -Phase Configure  (Part A7)"; fi
fi

mapfile -t STACKS < <(list_stacks)
for dir in "${STACKS[@]}"; do
  name="$(basename "$dir")"
  echo; echo "== Stack $name ($dir)"
  svc="$(grep -E '^SERVICE_NAME=' "$dir/scripts/stack.env" | cut -d= -f2)"
  kind="$(grep -E '^STACK_KIND=' "$dir/scripts/stack.env" | cut -d= -f2)"
  if [ ! -f "$dir/.env" ]; then bad ".env missing: cd $dir && cp .env.example .env"
  else
    [ "$(stat -c %a "$dir/.env")" = 600 ] && ok ".env is private (600)" || wn ".env should be mode 600: chmod 600 $dir/.env"
    grep -q $'\r' "$dir/.env" && bad ".env has Windows line endings: sed -i 's/\\r\$//' $dir/.env"
    if (cd "$dir" && scripts/env.sh check >/dev/null 2>&1); then ok "required .env keys are set"
    else bad "required .env keys missing: cd $dir && scripts/env.sh check"; fi
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$svc-ts" 2>/dev/null)" != true ]; then
    bad "Tailscale sidecar $svc-ts is not running: cd $dir && scripts/up.sh"; continue
  fi
  json="$(docker exec "$svc-ts" tailscale status --json 2>/dev/null || true)"
  st="$(printf '%s' "$json" | jq -r '.BackendState // "unknown"')"
  [ "$st" = Running ] && ok "on the tailnet as $(printf '%s' "$json" | jq -r '.Self.DNSName' | sed 's/\.$//') ($(printf '%s' "$json" | jq -r '.Self.TailscaleIPs[0]'))" \
    || bad "Tailscale state is $st: cd $dir && scripts/up.sh (it explains the fix)"
  [ -z "$(printf '%s' "$json" | jq -r '.Self.KeyExpiry // empty')" ] && ok "key expiry disabled" \
    || wn "key expiry is ON: admin console -> Machines -> $svc -> ... -> Disable key expiry"
  if [ "$kind" = app ]; then
    [ "$(printf '%s' "$json" | jq -r '(.CertDomains // []) | length')" != 0 ] && ok "HTTPS certificates enabled" \
      || bad "HTTPS off: https://login.tailscale.com/admin/dns -> Enable HTTPS"
    [ "$(printf '%s' "$json" | jq -r '(.Self.CapMap // {}) | any(keys[]; test("funnel"))')" = true ] && ok "Funnel allowed" \
      || bad "Funnel not allowed: https://login.tailscale.com/admin/acls -> Add Funnel to policy"
    (cd "$dir" && scripts/healthcheck.sh --timeout 5 >/dev/null 2>&1) && ok "app health is UP" \
      || bad "app is not healthy: cd $dir && scripts/healthcheck.sh"
    rdir="$KIT_HOME/actions-runner/$name"
    if [ -f "$rdir/.service" ]; then
      u="$(cat "$rdir/.service")"
      systemctl is-active --quiet "$u" 2>/dev/null && ok "GitHub runner service active ($u)" || bad "GitHub runner $u not running: sudo systemctl start $u"
    else
      wn "no GitHub runner registered for $name yet (README Part F: wsl/register-runner.sh)"
    fi
  else
    [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$svc" 2>/dev/null)" = healthy ] \
      && ok "Postgres healthy" || bad "Postgres not healthy: cd $dir && scripts/up.sh"
  fi
done
[ ${#STACKS[@]} -gt 0 ] || { echo; wn "No stacks registered yet (they register on their first scripts/up.sh)."; }

echo
echo "== Result: $NP passed, $NW warnings, $NF failed"
[ "$NF" = 0 ]
