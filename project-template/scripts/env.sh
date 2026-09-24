#!/usr/bin/env bash
# Manage this stack's .env file without ever showing secret values.
#
#   scripts/env.sh check                       which keys are set / EMPTY / MISSING
#   scripts/env.sh set KEY VALUE               set a NON-secret value (AI agents use this)
#   scripts/env.sh secret KEY                  HUMAN: paste a secret (input is hidden)
#   scripts/env.sh secret KEY --generate       create a random password
#   scripts/env.sh secret KEY --from FILE      copy KEY from another .env (e.g. the DB stack's)
#
# .env is created from .env.example if it doesn't exist yet, and is kept at mode 600.
source "$(dirname "$0")/_lib.sh"

SECRET_RE='(AUTHKEY|PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE|_KEY$)'

ensure_env() {
  if [ ! -f .env ]; then
    [ -f .env.example ] || die ".env.example is missing in $STACK_DIR"
    cp .env.example .env
    info "Created .env from .env.example"
  fi
  normalize_env
}

# write_env KEY VALUE: replace or append, atomically, mode 600.
write_env() {
  local tmp
  tmp="$(mktemp "$STACK_DIR/.env.XXXXXX")"
  __K="$1" __V="$2" awk '
    BEGIN { k = ENVIRON["__K"]; v = ENVIRON["__V"]; done = 0 }
    $0 ~ "^[[:space:]]*" k "=" { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' .env > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" .env
}

check_value() {  # values must survive docker compose's .env parsing unchanged
  case "$2" in
    *[[:space:]]*|*'#'*|*'$'*|*'"'*|*"'"*|*'\'*)
      die "The value for $1 contains spaces or one of  # \$ \" ' \\  which break .env files. Use a different value (for passwords: --generate)." ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  check)
    [ -f .env ] || die ".env does not exist yet. Create it: cp .env.example .env"
    normalize_env
    bad=0
    printf '%-24s %-8s %s\n' KEY STATE NOTE
    while IFS= read -r key; do
      state="$(env_state "$key")"; note=optional
      case "$key" in
        TS_AUTHKEY)
          if docker volume inspect "$STATE_VOLUME" >/dev/null 2>&1; then note="optional (already logged in)"
          else note=required; fi ;;
        POSTGRES_PASSWORD|DB_HOST|APP_UID|POSTGRES_DB|POSTGRES_USER) note=required ;;
      esac
      if [ "$note" = required ] && [ "$state" != set ]; then bad=1; fi
      printf '%-24s %-8s %s\n' "$key" "$state" "$note"
    done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' .env.example | tr -d '=' | awk '!seen[$0]++')
    [ "$bad" = 0 ] && pass "All required keys are set." || { fail "Some required keys are not set (see above)."; exit 1; }
    ;;
  set)
    key="${1:-}"; val="${2-}"
    [ -n "$key" ] && [ $# -eq 2 ] || die "Usage: scripts/env.sh set KEY VALUE"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Invalid key name: $key"
    if printf '%s' "$key" | grep -Eq "$SECRET_RE"; then
      die "$key is a secret. A human must set it with: scripts/env.sh secret $key"
    fi
    check_value "$key" "$val"
    ensure_env
    write_env "$key" "$val"
    pass "$key = $val"
    ;;
  secret)
    key="${1:-}"; shift || true
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Usage: scripts/env.sh secret KEY [--generate | --from FILE]"
    ensure_env
    case "${1:-}" in
      --generate)
        val="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
        [ "${#val}" -ge 24 ] || die "Could not generate a random value (is openssl installed?)" ;;
      --from)
        src="${2:?Usage: --from /path/to/other/.env}"
        [ -f "$src" ] || die "No such file: $src"
        val="$(grep -E "^[[:space:]]*$key=" "$src" | tail -n1 | cut -d= -f2- | tr -d '\r')" || true
        [ -n "$val" ] || die "$key is not set in $src" ;;
      "")
        [ -t 0 ] || die "This is a HUMAN step: run it yourself in an Ubuntu terminal so you can paste the value privately."
        read -rsp "Paste the value for $key (typing is hidden), then press Enter: " val; echo
        val="$(printf '%s' "$val" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$val" ] || die "Nothing was pasted." ;;
      *) die "Unknown option: $1" ;;
    esac
    if [ "$key" = TS_AUTHKEY ] && [[ "$val" != tskey-auth-* ]]; then
      die "That is not a Tailscale auth key (it must start with tskey-auth-). Generate one at https://login.tailscale.com/admin/settings/keys"
    fi
    check_value "$key" "$val"
    write_env "$key" "$val"
    pass "$key saved to $STACK_DIR/.env (${#val} characters, not shown)."
    ;;
  *)
    sed -n '2,10p' "$0"; exit 1 ;;
esac
