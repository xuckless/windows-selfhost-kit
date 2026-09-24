#!/usr/bin/env bash
# Test a service's mTLS port from inside its own network, the way a peer would call it.
#
#   mtls/check-mtls.sh <stack-dir> <caller-service-name> [--ca-dir ~/selfhost-ca]
#   e.g. mtls/check-mtls.sh ~/apps/orders-svc billing-svc
#
# 1) with the caller's certificate   -> expect HTTP 200
# 2) with no certificate             -> want mode: 200 (logged); need mode: TLS handshake refused
set -euo pipefail
dir="${1:?Usage: check-mtls.sh <stack-dir> <caller-service-name> [--ca-dir DIR]}"
caller="${2:?Usage: check-mtls.sh <stack-dir> <caller-service-name> [--ca-dir DIR]}"
ca_dir="$HOME/selfhost-ca"; [ "${3:-}" = --ca-dir ] && ca_dir="${4:?}"
get() { grep -E "^$1=" "$dir/scripts/stack.env" | cut -d= -f2- | tr -d '\r'; }
svc="$(get SERVICE_NAME)"; port="$(get MTLS_PORT)"; port="${port:-8443}"; path="$(get HEALTH_PATH)"; path="${path:-/actuator/health}"
for f in ca.crt "$caller.crt" "$caller.key"; do
  [ -f "$ca_dir/$f" ] || { echo "Missing $ca_dir/$f (run mtls/gen-certs.sh $caller)" >&2; exit 1; }
done

run_curl() {
  docker run --rm --user "$(id -u):$(id -g)" --network "container:$svc-ts" -v "$ca_dir:/c:ro" \
    curlimages/curl:latest -sS -o /dev/null -w '%{http_code}' -m 10 --cacert /c/ca.crt \
    --resolve "$svc:$port:127.0.0.1" "$@" "https://$svc:$port$path" 2>/dev/null || true
}
echo "Calling https://$svc:$port$path"
with="$(run_curl --cert "/c/$caller.crt" --key "/c/$caller.key")"
echo "  as $caller (with certificate): $with"
without="$(run_curl)"
[ "$without" = 000 ] && without="refused (TLS handshake)"
echo "  without a certificate:        $without"
if [ "$with" = 200 ]; then
  echo "OK: mTLS works for $caller."
  case "$without" in
    200) echo "Note: calls without a certificate are still allowed (MTLS_CLIENT_AUTH=want, log-only mode)." ;;
    *) echo "Calls without a certificate are refused (MTLS_CLIENT_AUTH=need, enforcing)." ;;
  esac
else
  echo "FAILED. Check: SPRING_PROFILES_ACTIVE includes mtls, certs/ installed (mtls/install-certs.sh),"
  echo "MTLS_ALLOWED_CLIENTS includes $caller, and: docker compose logs app" ; exit 1
fi
