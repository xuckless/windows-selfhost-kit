#!/usr/bin/env bash
# Create a private certificate authority (CA) and one certificate per service, for
# service-to-service mutual TLS over the tailnet.
#
#   mtls/gen-certs.sh orders-svc billing-svc        # CA (first time only) + 2 service certs
#   mtls/gen-certs.sh --force orders-svc            # re-issue an existing service cert
#   mtls/gen-certs.sh --rotate-ca a b c             # NEW CA: every service must get new certs
#
# Output: ~/selfhost-ca/ (or --out DIR): ca.crt ca.key <svc>.crt <svc>.key
# Each service cert: CN and DNS name = the service name, valid for both server and
# client use, EC P-256, PKCS#8 key (the PEM format Spring Boot expects).
#
# KEEP ca.key SECRET: anyone who has it can create a trusted service identity. After
# issuing certs, back it up somewhere offline (README Part G).
set -euo pipefail

OUT="$HOME/selfhost-ca"; CA_CN="Selfhost Service CA"; FORCE=; ROTATE=
CA_DAYS="${CA_DAYS:-3650}"; LEAF_DAYS="${LEAF_DAYS:-730}"
SERVICES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?}"; shift ;;
    --ca-cn) CA_CN="${2:?}"; shift ;;
    --force) FORCE=1 ;;
    --rotate-ca) ROTATE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) SERVICES+=("$1") ;;
  esac
  shift
done
[ ${#SERVICES[@]} -gt 0 ] || { echo "Usage: $0 [--out DIR] [--force] [--rotate-ca] service-name..." >&2; exit 1; }
for s in "${SERVICES[@]}"; do
  [[ "$s" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "Bad service name: $s" >&2; exit 1; }
done

umask 077
mkdir -p "$OUT"; chmod 700 "$OUT"
cd "$OUT"

if [ -f ca.key ] && [ -z "$ROTATE" ]; then
  echo "==> using the existing CA in $OUT"
else
  if [ -f ca.key ]; then
    ts="$(date +%Y%m%d-%H%M%S)"; mv ca.key "ca.key.old-$ts"; mv ca.crt "ca.crt.old-$ts"
    echo "==> old CA moved to ca.*.old-$ts; creating a new CA"
    FORCE=1
  else
    echo "==> creating a new CA"
  fi
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days "$CA_DAYS" -out ca.crt \
    -subj "/CN=$CA_CN" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

for svc in "${SERVICES[@]}"; do
  if [ -f "$svc.crt" ] && [ -z "$FORCE" ]; then
    echo "==> $svc: certificate exists, keeping it (use --force to re-issue)"
    continue
  fi
  echo "==> issuing certificate for $svc"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$svc.key"
  openssl req -new -key "$svc.key" -out "$svc.csr" -subj "/CN=$svc"
  ext="$(mktemp)"
  cat > "$ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:$svc
EOF
  openssl x509 -req -in "$svc.csr" -CA ca.crt -CAkey ca.key \
    -set_serial "0x$(openssl rand -hex 16)" -sha256 -days "$LEAF_DAYS" \
    -extfile "$ext" -out "$svc.crt"
  rm -f "$svc.csr" "$ext"
done

chmod 600 ./*.key
chmod 644 ./*.crt
echo
for svc in "${SERVICES[@]}"; do
  printf '%-30s %s   expires %s\n' "$svc" "$(openssl verify -CAfile ca.crt "$svc.crt" | sed 's/.*: //')" \
    "$(openssl x509 -in "$svc.crt" -noout -enddate | cut -d= -f2)"
done
echo
echo "Next: copy each service's files into its stack:"
for svc in "${SERVICES[@]}"; do
  echo "  mtls/install-certs.sh $svc ~/apps/<repo-of-$svc>"
done
echo "Then back up $OUT/ca.key somewhere offline (README Part G)."
