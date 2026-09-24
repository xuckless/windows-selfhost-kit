#!/usr/bin/env bash
# Copy the CA certificate and ONE service's own certificate + key into that
# service's stack folder (certs/ is git-ignored and mounted read-only at /certs).
#
#   mtls/install-certs.sh <service-name> <stack-dir> [--ca-dir ~/selfhost-ca]
#   e.g. mtls/install-certs.sh orders-svc ~/apps/orders-svc
set -euo pipefail
svc="${1:?Usage: install-certs.sh <service-name> <stack-dir> [--ca-dir DIR]}"
dir="${2:?Usage: install-certs.sh <service-name> <stack-dir> [--ca-dir DIR]}"
ca_dir="$HOME/selfhost-ca"
[ "${3:-}" = --ca-dir ] && ca_dir="${4:?}"

for f in ca.crt "$svc.crt" "$svc.key"; do
  [ -f "$ca_dir/$f" ] || { echo "Missing $ca_dir/$f. Run: mtls/gen-certs.sh $svc" >&2; exit 1; }
done
[ -f "$dir/docker-compose.yml" ] || { echo "$dir does not look like a stack folder (no docker-compose.yml)" >&2; exit 1; }

uid="$(id -u)"
if [ -f "$dir/.env" ]; then
  v="$(grep -E '^APP_UID=' "$dir/.env" | tail -n1 | cut -d= -f2 | tr -d '\r' || true)"
  [ -n "$v" ] && uid="$v"
fi

mkdir -p "$dir/certs"
install -m 644 "$ca_dir/ca.crt" "$dir/certs/ca.crt"
install -m 644 "$ca_dir/$svc.crt" "$dir/certs/$svc.crt"
install -m 600 "$ca_dir/$svc.key" "$dir/certs/$svc.key"
if [ "$(stat -c %u "$dir/certs/$svc.key")" != "$uid" ]; then
  sudo chown "$uid" "$dir/certs/$svc.key"
fi
echo "Installed into $dir/certs:"
ls -l "$dir/certs" | sed 's/^/  /'
echo "The app container runs as uid $uid and can read the key. Restart the app to load it:"
echo "  cd $dir && docker compose up -d --no-deps --force-recreate app"
