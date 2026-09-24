#!/usr/bin/env bash
# Install a GitHub Actions self-hosted runner for ONE repo inside WSL2, as a systemd
# service that starts with WSL. Safe to run again (does nothing if already online).
#
#   ~/selfhost-kit/wsl/register-runner.sh                 repo from kit.env
#   ~/selfhost-kit/wsl/register-runner.sh --owner me --repo other-app
#   ~/selfhost-kit/wsl/register-runner.sh --force         re-register (e.g. runner was removed)
#   ~/selfhost-kit/wsl/register-runner.sh --remove        unregister and delete it
#
# From Windows PowerShell (no password prompt):
#   .\windows\wsl-run.ps1 -Root '$KIT/wsl/register-runner.sh --user $KIT_USER'
#
# Needs: "gh auth login" done as your user (README Part B). The repo must be PRIVATE:
# on a public repo anyone could run code on your PC through a pull request.
set -euo pipefail
# shellcheck source=wsl/lib.sh
source "$(dirname "$0")/lib.sh"

OWNER=; REPO_NAME=; LABEL=; NAME=; FORCE=; REMOVE=
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="${2:?}"; shift ;;
    --repo) REPO_NAME="${2:?}"; shift ;;
    --label) LABEL="${2:?}"; shift ;;
    --name) NAME="${2:?}"; shift ;;
    --user) KIT_USER="${2:?}"; shift ;;
    --force) FORCE=1 ;;
    --remove) REMOVE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
detect_kit_user
if [ -f "$KIT_DIR/kit.env" ]; then load_kit_env; fi
OWNER="${OWNER:-${GITHUB_OWNER:-}}"; REPO_NAME="${REPO_NAME:-${REPO:-}}"
LABEL="${LABEL:-${RUNNER_LABEL:-wsl}}"
[ -n "$OWNER" ] && [ -n "$REPO_NAME" ] || die "Set GITHUB_OWNER and REPO in kit.env (or pass --owner/--repo)."
NAME="${NAME:-$(hostname | tr '[:upper:]' '[:lower:]')-$REPO_NAME}"
SLUG="$OWNER/$REPO_NAME"
BASE="$KIT_HOME/actions-runner"
DIR="$BASE/$REPO_NAME"
require_cmd gh jq curl tar sha256sum

gh_user() { as_user gh "$@"; }
unit_name() { [ -f "$DIR/.service" ] && cat "$DIR/.service" || echo ""; }
svc() { (cd "$DIR" && as_root ./svc.sh "$@"); }
api_status() {
  gh_user api "repos/$SLUG/actions/runners" --paginate --jq ".runners[] | select(.name==\"$NAME\") | .status" 2>/dev/null | head -1
}

gh_user auth status >/dev/null 2>&1 || die "GitHub CLI is not logged in for $KIT_USER. HUMAN step: gh auth login -h github.com -p https -w -s workflow   (README Part B)"

unregister() {
  if [ -f "$DIR/.runner" ]; then
    info "Removing runner $NAME from $SLUG"
    [ -n "$(unit_name)" ] && { svc stop || true; svc uninstall || true; }
    tok="$(gh_user api -X POST "repos/$SLUG/actions/runners/remove-token" --jq .token 2>/dev/null || true)"
    if [ -n "$tok" ]; then (cd "$DIR" && as_user ./config.sh remove --token "$tok") || true; fi
    unset tok
    rm -f "$DIR/.runner" "$DIR/.credentials" "$DIR/.credentials_rsaparams" "$DIR/.service"
  fi
}

if [ -n "$REMOVE" ]; then
  unregister
  rm -rf "$DIR"
  pass "Runner removed."
  exit 0
fi

# ---- safety checks --------------------------------------------------------------------
vis="$(gh_user repo view "$SLUG" --json visibility -q .visibility 2>/dev/null)" || die "Cannot see the repo $SLUG. Check GITHUB_OWNER/REPO in kit.env and that gh is logged in as the right account."
[ "$vis" = PRIVATE ] || die "$SLUG is $vis. Self-hosted runners are only safe on PRIVATE repos. Make it private (GitHub -> Settings -> Danger Zone) or stop here."
[ "$(gh_user api "repos/$SLUG" --jq .permissions.admin)" = true ] || die "You need admin rights on $SLUG to register a runner."
pass "$SLUG is private and you are an admin"

if [ -f "$DIR/.runner" ] && [ -z "$FORCE" ]; then
  u="$(unit_name)"
  if [ -n "$u" ] && systemctl is-active --quiet "$u"; then
    pass "Runner already installed and running ($u). Status on GitHub: $(api_status || echo unknown)"
    exit 0
  fi
fi
[ -n "$FORCE" ] && unregister

# ---- download the runner (checksum verified) ---------------------------------------------
case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ARCH=x64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac
read -r URL FILE SHA < <(gh_user api "repos/$SLUG/actions/runners/downloads" \
  --jq ".[] | select(.os==\"linux\" and .architecture==\"$ARCH\") | \"\(.download_url) \(.filename) \(.sha256_checksum)\"") || true
[ -n "${URL:-}" ] || die "Could not get the runner download link from GitHub."
as_user mkdir -p "$BASE" "$DIR"
if [ ! -f "$BASE/$FILE" ]; then
  info "Downloading $FILE"
  as_user curl -fsSL -o "$BASE/$FILE.part" "$URL"
  as_user mv "$BASE/$FILE.part" "$BASE/$FILE"
fi
echo "$SHA  $BASE/$FILE" | sha256sum -c --quiet - || { rm -f "$BASE/$FILE"; die "Checksum mismatch for $FILE (deleted). Run again."; }
if [ ! -f "$DIR/config.sh" ] || [ -n "$FORCE" ]; then
  as_user tar -xzf "$BASE/$FILE" -C "$DIR"
fi
info "Installing runner dependencies"
as_root "$DIR/bin/installdependencies.sh" >/dev/null

# ---- register + install the service ------------------------------------------------------------
info "Registering runner '$NAME' (labels: self-hosted, Linux, $LABEL) for $SLUG"
TOKEN="$(gh_user api -X POST "repos/$SLUG/actions/runners/registration-token" --jq .token)"
(cd "$DIR" && as_user ./config.sh --unattended --url "https://github.com/$SLUG" --token "$TOKEN" \
  --name "$NAME" --labels "$LABEL" --work _work --replace) >/dev/null
unset TOKEN
svc install "$KIT_USER" >/dev/null
svc start >/dev/null
u="$(unit_name)"
systemctl is-active --quiet "$u" || die "The runner service $u did not start: sudo journalctl -u $u --no-pager | tail -50"
pass "Service $u is running"

for _ in $(seq 1 20); do
  st="$(api_status || true)"
  [ "$st" = online ] && break
  sleep 3
done
if [ "${st:-}" = online ]; then
  pass "GitHub sees runner '$NAME' as online."
else
  warn "GitHub shows runner '$NAME' as '${st:-not found}'. Check: gh api repos/$SLUG/actions/runners"
fi
next "Workflows can now use:  runs-on: [self-hosted, $LABEL]"
