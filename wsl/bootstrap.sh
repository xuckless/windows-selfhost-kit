#!/usr/bin/env bash
# One-time setup of the WSL2 Ubuntu machine. Safe to run again: finished steps are skipped.
#
#   From Windows PowerShell (kit folder), no password prompt:
#     .\windows\wsl-run.ps1 -Root '$KIT/wsl/bootstrap.sh --user $KIT_USER'
#   Or inside Ubuntu:
#     sudo ~/selfhost-kit/wsl/bootstrap.sh
#
# Installs: systemd on, Docker Engine + compose + buildx (official Docker repo),
# GitHub CLI (gh), git, jq, openssl, dbus-x11. Adds you to the "docker" group.
# Exit codes: 0 = done, 2 = restart WSL (wsl --shutdown) and run again, 1 = failed.
set -euo pipefail
# shellcheck source=wsl/lib.sh
source "$(dirname "$0")/lib.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --user) KIT_USER="${2:?}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" --user "$(id -un)"
fi
detect_kit_user
export DEBIAN_FRONTEND=noninteractive
# For testing this script in a plain container only:
SKIP_WSL="${BOOTSTRAP_SKIP_WSL_CHECKS:-}"
DISTRO_NAME="${WSL_DISTRO_NAME:-Ubuntu-24.04}"

# ini_set FILE SECTION KEY VALUE  (edit an INI file in place, keeping other lines)
ini_set() {
  local f="$1" s="$2" k="$3" v="$4" tmp
  touch "$f"; tmp="$(mktemp)"
  awk -v s="$s" -v k="$k" -v v="$v" '
    BEGIN { insec = 0; done = 0 }
    /^[[:space:]]*\[/ {
      if (insec && !done) { print k "=" v; done = 1 }
      insec = ($0 ~ "^[[:space:]]*\\[" s "\\][[:space:]]*$"); print; next }
    insec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (!done) { print k "=" v; done = 1 } next }
    { print }
    END { if (!done) { if (!insec) printf "\n[%s]\n", s; print k "=" v } }' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
}

info "Setting up WSL2 for user '$KIT_USER'"

# ---- 1. WSL2 + systemd -------------------------------------------------------------
if [ -z "$SKIP_WSL" ]; then
  is_wsl1 && die "This distro runs on WSL1. From Windows PowerShell run: wsl --set-version $DISTRO_NAME 2   (see README Part A)"
  is_wsl2 || die "This does not look like WSL2 (kernel: $(uname -r))."
  pass "Running on WSL2 (kernel $(uname -r))"
  before="$(cat /etc/wsl.conf 2>/dev/null || true)"
  ini_set /etc/wsl.conf boot systemd true
  ini_set /etc/wsl.conf user default "$KIT_USER"
  [ "$before" = "$(cat /etc/wsl.conf)" ] || info "Updated /etc/wsl.conf (systemd=true, default user=$KIT_USER)"
  if [ "$(ps -p 1 -o comm= 2>/dev/null)" != systemd ]; then
    fail "systemd is not running yet (it was just switched on)."
    next "From Windows PowerShell run:  wsl --shutdown   then run this script again."
    exit 2
  fi
  pass "systemd is running"
fi

# ---- 2. base packages ------------------------------------------------------------------
info "Installing base packages (git, curl, jq, openssl, dbus-x11)"
apt-get update -q
apt-get install -y -q ca-certificates curl git jq openssl dbus-x11 unzip gnupg >/dev/null
pass "Base packages installed"

# ---- 3. Docker Engine (not Docker Desktop) -------------------------------------------------
if [ -d /mnt/wsl/docker-desktop ] || readlink -f "$(command -v docker 2>/dev/null || echo /nonexistent)" | grep -q docker-desktop; then
  die "Docker Desktop's WSL integration is active in this distro. This kit uses Docker Engine inside WSL2 instead. In Docker Desktop: Settings -> Resources -> WSL integration -> turn OFF '$DISTRO_NAME' (or quit Docker Desktop), then run: wsl --shutdown  and run this script again."
fi
if dpkg -s docker-ce >/dev/null 2>&1 && dpkg -s docker-compose-plugin >/dev/null 2>&1; then
  pass "Docker Engine already installed ($(docker --version))"
else
  info "Installing Docker Engine from download.docker.com"
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -s "$p" >/dev/null 2>&1; then apt-get remove -y -q "$p" >/dev/null; fi
  done
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  pass "Docker Engine installed ($(docker --version))"
fi
if [ ! -f /etc/docker/daemon.json ]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  info "Created /etc/docker/daemon.json (log rotation)"
fi
if [ -z "$SKIP_WSL" ]; then
  systemctl enable --now containerd docker >/dev/null 2>&1
  systemctl is-active --quiet docker || die "Docker did not start. See: sudo journalctl -u docker --no-pager | tail -50"
  pass "Docker service is running and starts automatically"
fi
getent group docker >/dev/null || groupadd docker
GROUP_CHANGED=
if id -nG "$KIT_USER" | tr ' ' '\n' | grep -qx docker; then
  pass "$KIT_USER is in the docker group"
else
  usermod -aG docker "$KIT_USER"
  GROUP_CHANGED=1
  pass "Added $KIT_USER to the docker group"
fi

# ---- 4. GitHub CLI ------------------------------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  pass "GitHub CLI already installed ($(gh --version | head -1))"
else
  info "Installing GitHub CLI (gh)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -q
  apt-get install -y -q gh >/dev/null
  pass "GitHub CLI installed ($(gh --version | head -1))"
fi

# ---- 5. kit variables in every login shell ($REPO, $SERVICE_NAME, ... from kit.env) --------------
profile="$KIT_HOME/.profile"
hook='[ -f ~/selfhost-kit/wsl/kit-vars.sh ] && . ~/selfhost-kit/wsl/kit-vars.sh'
if ! grep -qxF "$hook" "$profile" 2>/dev/null; then
  printf '\n# windows-selfhost-kit: $REPO, $SERVICE_NAME, $DB_SERVICE_NAME, $KIT ...\n%s\n' "$hook" >> "$profile"
  chown "$KIT_USER:" "$profile"
fi
pass "Kit variables load in every Ubuntu shell (\$REPO, \$SERVICE_NAME, \$KIT)"

# ---- 6. /dev/net/tun (needed by the Tailscale sidecars) --------------------------------------
if [ -z "$SKIP_WSL" ]; then
  [ -c /dev/net/tun ] || modprobe tun 2>/dev/null || true
  if [ -c /dev/net/tun ]; then pass "/dev/net/tun is available"
  else fail "/dev/net/tun is missing. From Windows run: wsl --update   then: wsl --shutdown   and try again."; exit 1
  fi
fi

echo
pass "WSL2 bootstrap finished."
if [ -n "$GROUP_CHANGED" ]; then
  next "The docker group change needs a fresh login. From Windows PowerShell run:  wsl --terminate $DISTRO_NAME"
  exit 0
fi
next "Continue with README Part A step A7 (auto-start), then Part B (accounts)."
