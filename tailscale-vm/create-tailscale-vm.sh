#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# ─── Config ───────────────────────────────────────────────
RG="rg-lab-networking"
LOCATION="eastus"
VM_NAME="vm-tailscale"
VNET="vnet-lab"
SUBNET="snet-gateway"
NIC_NAME="nic-tailscale"
PIP_NAME="pip-tailscale"
NSG_NAME="nsg-tailscale"
VM_SIZE="Standard_B1s"
VM_IMAGE="Ubuntu2404"
ADMIN_USER="azureuser"
ADMIN_SSH_PUBKEY="${ADMIN_SSH_PUBKEY:?ADMIN_SSH_PUBKEY env var required}"
TS_AUTHKEY="${TS_AUTHKEY:?TS_AUTHKEY env var required}"
TS_API_KEY="${TS_API_KEY:?TS_API_KEY env var required}"
# ──────────────────────────────────────────────────────────

echo "→ Generating cloud-init..."
CLOUD_INIT=$(mktemp)
sed \
  -e "s|\${TS_AUTHKEY}|${TS_AUTHKEY}|g" \
  "${SCRIPT_DIR}/cloud-init.yaml" > "$CLOUD_INIT"

echo "→ Creating public IP..."
az network public-ip create \
  --resource-group "$RG" \
  --name "$PIP_NAME" \
  --sku Standard \
  --allocation-method Static \
  --output none

echo "→ Creating NSG..."
az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_NAME" \
  --output none

az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_NAME" \
  --name "AllowSSH-VNet" \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes VirtualNetwork \
  --destination-address-prefixes "10.10.0.10" \
  --destination-port-ranges 22 \
  --output none

echo "→ Creating NIC..."
az network nic create \
  --resource-group "$RG" \
  --name "$NIC_NAME" \
  --vnet-name "$VNET" \
  --subnet "$SUBNET" \
  --private-ip-address 10.10.0.10 \
  --public-ip-address "$PIP_NAME" \
  --network-security-group "$NSG_NAME" \
  --output none

echo "→ Creating VM..."
az vm create \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --nics "$NIC_NAME" \
  --image "$VM_IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$ADMIN_SSH_PUBKEY" \
  --custom-data "@$CLOUD_INIT" \
  --storage-sku Standard_LRS \
  --os-disk-delete-option Delete \
  --output none

rm "$CLOUD_INIT"

PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RG" \
  --name "$PIP_NAME" \
  --query ipAddress -o tsv)

echo ""
echo "✅ VM deployed"
echo "   Public IP : $PUBLIC_IP"
echo ""

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
