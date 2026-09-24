#!/usr/bin/env bash
# Start, stop or inspect EVERYTHING this PC hosts, in one command.
# Stacks register themselves the first time you run their scripts/up.sh.
#
#   ~/selfhost-kit/wsl/selfhost.sh up [--build]   start all stacks (databases first)
#   ~/selfhost-kit/wsl/selfhost.sh status         status of all stacks
#   ~/selfhost-kit/wsl/selfhost.sh down           stop all stacks
#   ~/selfhost-kit/wsl/selfhost.sh list           show registered stack folders
#   ~/selfhost-kit/wsl/selfhost.sh add <dir>      register a stack folder by hand
#   ~/selfhost-kit/wsl/selfhost.sh forget <dir>   unregister a stack folder
#   ~/selfhost-kit/wsl/selfhost.sh autostart      used by the Windows logon task
#
# The Windows Desktop shortcuts "Start SelfHost" / "SelfHost Status" / "Stop SelfHost" run this.
set -uo pipefail
# shellcheck source=wsl/lib.sh
source "$(dirname "$0")/lib.sh"
detect_kit_user

cmd="${1:-status}"; shift || true

wait_for_docker() {
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && return 0; sleep 2; done
  fail "Docker is not responding. Try: sudo systemctl restart docker"
  return 1
}

run_all() {  # run_all <script> [args...]
  local script="$1"; shift
  local dirs dir name rc overall=0 results=()
  mapfile -t dirs < <(list_stacks)
  if [ ${#dirs[@]} -eq 0 ]; then
    warn "No stacks registered yet. Run scripts/up.sh once in each stack folder (e.g. ~/apps/<repo>)."
    return 0
  fi
  [ "$script" = down.sh ] && mapfile -t dirs < <(printf '%s\n' "${dirs[@]}" | tac)  # apps before databases
  for dir in "${dirs[@]}"; do
    name="$(basename "$dir")"
    echo; info "$name: scripts/$script $*"
    "$dir/scripts/$script" "$@"; rc=$?
    results+=("$(printf '%-32s %s' "$name" "$( [ $rc = 0 ] && echo OK || { [ $rc = 2 ] && echo 'RUNNING (not public yet)' || echo "FAILED (exit $rc)"; } )")")
    [ $rc = 0 ] || overall=1
  done
  echo; echo "== Summary"
  printf '  %s\n' "${results[@]}"
  return $overall
}

case "$cmd" in
  up)
    wait_for_docker || exit 1
    run_all up.sh "$@" ;;
  status) run_all status.sh ;;
  down) run_all down.sh ;;
  list) list_stacks ;;
  add)
    d="$(cd "${1:?Usage: selfhost.sh add <dir>}" && pwd)"
    kind="$(grep -E '^STACK_KIND=' "$d/scripts/stack.env" 2>/dev/null | cut -d= -f2)"
    [ -n "$kind" ] || die "$d/scripts/stack.env not found: is this a stack folder?"
    register_stack "$kind" "$d"; pass "Registered $d ($kind)" ;;
  forget)
    d="${1:?Usage: selfhost.sh forget <dir>}"; f="$(stacks_file)"
    [ -f "$f" ] && { grep -vE " ${d%/}\$" "$f" > "$f.tmp" || true; mv "$f.tmp" "$f"; }
    pass "Forgot $d" ;;
  autostart)
    log_dir="$KIT_HOME/.local/state/selfhost-kit"; mkdir -p "$log_dir"
    log="$log_dir/autostart.log"
    { echo "==== $(date -Is) autostart"; wait_for_docker && run_all up.sh; } >> "$log" 2>&1
    tail -n 2000 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
    # Keep this WSL instance running after the logon task's window closes.
    if command -v dbus-launch >/dev/null 2>&1; then exec dbus-launch true; fi ;;
  -h|--help|help) sed -n '2,14p' "$0" ;;
  *) die "Unknown command: $cmd (see --help)" ;;
esac
