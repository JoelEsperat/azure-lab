#!/bin/bash
# create-ts-subnet-router.sh — Deploy the Tailscale subnet router VM via Bicep,
# then approve subnet routes via the Tailscale API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

RG="rg-lab-network"
TEMPLATE="${SCRIPT_DIR}/../bicep/subnet-router.bicep"
ADMIN_SSH_PUBKEY="${ADMIN_SSH_PUBKEY:?ADMIN_SSH_PUBKEY env var required}"
TS_AUTHKEY="${TS_AUTHKEY:?TS_AUTHKEY env var required}"
TS_API_KEY="${TS_API_KEY:?TS_API_KEY env var required}"

echo "→ Deploying subnet router via bicep/subnet-router.bicep..."
az deployment group create \
  --resource-group "$RG" \
  --name subnet-router-deploy \
  --template-file "$TEMPLATE" \
  --parameters adminSshPubkey="$ADMIN_SSH_PUBKEY" tsAuthKey="$TS_AUTHKEY" \
  --output none

PUBLIC_IP=$(az network public-ip show --resource-group "$RG" --name pip-tailscale --query ipAddress -o tsv)
echo "  ✓ VM deployed (Public IP: $PUBLIC_IP)"

echo "→ Waiting for azure-subnet-router to join tailnet (first check in 30s)..."
sleep 30
DEVICE_ID=""
for i in $(seq 1 20); do
  DEVICE_ID=$(curl -sf \
    -H "Authorization: Bearer ${TS_API_KEY}" \
    "https://api.tailscale.com/api/v2/tailnet/-/devices" \
    | jq -r '([.devices[] | select(.hostname == "azure-subnet-router")] | sort_by(.lastSeen) | last | .id) // empty' 2>/dev/null || true)
  if [[ -n "$DEVICE_ID" ]]; then
    echo "  ✓ Device found: $DEVICE_ID"
    break
  fi
  echo "  waiting... ($i/20)"
  sleep 15
done

if [[ -z "$DEVICE_ID" ]]; then
  echo "⚠ Device did not appear within timeout — approve subnet routes manually in the Tailscale admin console"
else
  curl -sf -X POST \
    -H "Authorization: Bearer ${TS_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"routes":["10.10.0.0/16"]}' \
    "https://api.tailscale.com/api/v2/device/${DEVICE_ID}/routes" > /dev/null
  echo "  ✓ Subnet route 10.10.0.0/16 approved"
fi
