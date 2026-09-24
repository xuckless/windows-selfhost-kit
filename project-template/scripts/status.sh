#!/usr/bin/env bash
# Show what is running for this stack: containers, tailnet identity, public URL,
# health, deployed revision and the GitHub runner. Safe to run any time.
source "$(dirname "$0")/_lib.sh"
require_docker

echo "== $SERVICE_NAME ($STACK_KIND stack in $STACK_DIR)"
docker ps -a --filter "label=com.docker.compose.project=$SERVICE_NAME" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

echo
echo "== Tailscale"
json="$(ts_json)"
if [ -z "$json" ]; then
  echo "  sidecar not running (start with scripts/up.sh)"
else
  printf '%s' "$json" | jq -r '
    "  state:       \(.BackendState)",
    "  machine:     \(.Self.DNSName // "?" | rtrimstr("."))",
    "  tailnet IP:  \(.Self.TailscaleIPs[0] // "?")",
    "  key expiry:  \(.Self.KeyExpiry // "disabled (good)")",
    "  HTTPS certs: \(if ((.CertDomains // []) | length) > 0 then "enabled" else "OFF (admin console -> DNS -> Enable HTTPS)" end)",
    "  Funnel:      \(if ((.Self.CapMap // {}) | any(keys[]; test("funnel"))) then "allowed" else "NOT allowed (admin console -> Access controls -> Add Funnel to policy)" end)"'
  if [ "$STACK_KIND" = app ]; then
    dns="$(printf '%s' "$json" | jq -r '.Self.DNSName // empty')"
    echo "  public URL:  https://${dns%.}"
    echo "  funnel status:"
    dc exec -T tailscale tailscale funnel status 2>/dev/null | sed 's/^/    /' || true
  fi
fi

echo
echo "== Health"
if [ "$STACK_KIND" = app ]; then
  "$STACK_DIR/scripts/healthcheck.sh" --timeout 5 >/dev/null 2>&1 && echo "  UP" || echo "  NOT UP (details: scripts/healthcheck.sh --timeout 5)"
  rev="$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$SERVICE_NAME" 2>/dev/null || true)"
  head="$(git rev-parse HEAD 2>/dev/null || true)"
  echo "  running revision: ${rev:-unknown}"
  [ -n "$head" ] && echo "  folder revision:  $head"
else
  echo "  postgres: $(container_health "$SERVICE_NAME")"
fi

if command -v systemctl >/dev/null 2>&1 && [ "$STACK_KIND" = app ]; then
  echo
  echo "== GitHub runners on this PC"
  systemctl list-units --type=service --all --no-legend 'actions.runner.*' 2>/dev/null | awk '{print "  " $1 "  " $3 "/" $4}' || true
fi
