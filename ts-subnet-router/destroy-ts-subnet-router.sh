#!/bin/bash
# destroy-ts-subnet-router.sh — Delete the Tailscale subnet router VM and its resources (IPv4, disks, NSG, etc),
# and remove the device from the Tailscale tailnet.
# Usage:
#   chmod +x ts-subnet-router/destroy-ts-subnet-router.sh && ./ts-subnet-router/destroy-ts-subnet-router.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

RG="rg-lab-network"
VM_NAME="vm-ts-subnet-router"
NIC_NAME="nic-tailscale"
PIP_NAME="pip-tailscale"
NSG_NAME="nsg-tailscale"
VNET="vnet-lab"
SUBNET="snet-gateway"
TS_API_KEY="${TS_API_KEY:-}"

echo "→ Removing device from Tailscale tailnet..."
if [[ -n "$TS_API_KEY" ]]; then
  DEVICE_IDS=$(curl -sf \
    -H "Authorization: Bearer ${TS_API_KEY}" \
    "https://api.tailscale.com/api/v2/tailnet/-/devices" \
    | jq -r '.devices[] | select(.hostname == "azure-subnet-router") | .id' 2>/dev/null || true)
  if [[ -n "$DEVICE_IDS" ]]; then
    while IFS= read -r id; do
      curl -sf -X DELETE \
        -H "Authorization: Bearer ${TS_API_KEY}" \
        "https://api.tailscale.com/api/v2/device/${id}" > /dev/null 2>&1 || true
      echo "  ✓ device $id removed"
    done <<< "$DEVICE_IDS"
  else
    echo "  – no device found (already removed)"
  fi
else
  echo "  – TS_API_KEY not set, skipping"
fi

echo "→ Deleting VM and OS disk..."
az vm delete --resource-group "$RG" --name "$VM_NAME" --yes --output none 2>/dev/null \
  && echo "  ✓ $VM_NAME" || echo "  – $VM_NAME (not found)"

# Belt-and-suspenders: delete any orphaned OS disk (pre-existing VMs had deleteOption=Detach)
DISK_NAME=$(az disk list --resource-group "$RG" \
  --query "[?starts_with(name, '${VM_NAME}_OsDisk')].name" -o tsv 2>/dev/null || true)
if [[ -n "$DISK_NAME" ]]; then
  az disk delete --resource-group "$RG" --name "$DISK_NAME" --yes --output none 2>/dev/null \
    && echo "  ✓ $DISK_NAME" || echo "  – disk delete failed"
fi

echo "→ Deleting NIC..."
az network nic delete --resource-group "$RG" --name "$NIC_NAME" --output none 2>/dev/null \
  && echo "  ✓ $NIC_NAME" || echo "  – $NIC_NAME (not found)"

echo "→ Deleting public IP..."
az network public-ip delete --resource-group "$RG" --name "$PIP_NAME" --output none 2>/dev/null \
  && echo "  ✓ $PIP_NAME" || echo "  – $PIP_NAME (not found)"

echo "→ Deleting NSG..."
az network nsg delete --resource-group "$RG" --name "$NSG_NAME" --output none 2>/dev/null \
  && echo "  ✓ $NSG_NAME" || echo "  – $NSG_NAME (not found)"

echo ""
echo "✅ Tailscale VM destroyed. vnet-lab and rg-lab-network are intact."
