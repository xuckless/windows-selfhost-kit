# shellcheck shell=bash
# Exports the kit.env values (GITHUB_OWNER, REPO, SERVICE_NAME, DB_SERVICE_NAME, ...) into
# your Ubuntu shell, so tutorial commands like "cd ~/apps/$REPO" work as written.
# bootstrap.sh adds this line to ~/.profile:
#   [ -f ~/selfhost-kit/wsl/kit-vars.sh ] && . ~/selfhost-kit/wsl/kit-vars.sh
# Safe to source: it never exits your shell and defines no functions.
if [ -f "$HOME/selfhost-kit/kit.env" ]; then
  while IFS= read -r __kv || [ -n "$__kv" ]; do
    __kv="${__kv%$'\r'}"
    case "$__kv" in ''|'#'*) continue ;; esac
    case "${__kv%%=*}" in
      GITHUB_OWNER|REPO|SERVICE_NAME|APP_PORT|JAVA_VERSION|BRANCH|DISTRO|WITH_DB|DB_SERVICE_NAME|WITH_MTLS|RUNNER_LABEL|HEALTH_PATH|MTLS_PORT|WIN_PROJECT_DIR)
        export "${__kv%%=*}=${__kv#*=}" ;;
    esac
  done < "$HOME/selfhost-kit/kit.env"
  unset __kv
  [ -n "${DB_SERVICE_NAME:-}" ] || export DB_SERVICE_NAME="${SERVICE_NAME:-app}-db"
  export KIT="$HOME/selfhost-kit"
fi
