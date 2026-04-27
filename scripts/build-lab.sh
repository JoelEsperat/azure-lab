#!/usr/bin/env bash
# build-lab.sh — Idempotently recreates the azure-lab infrastructure baseline.
#
# Scope: resource groups, custom policies, policy assignments, VNet, action group.
#
# Prerequisites:
#   - bootstrap.sh has been run at least once
#   - az login completed and subscription is set
#
# Usage:
#   chmod +x scripts/build-lab.sh && ./scripts/build-lab.sh

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
info() { echo -e "${BLUE}  ▶${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
fail() { echo -e "${RED}  ✗${NC} $1"; exit 1; }
header() {
  echo ""
  echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
}

# ── Config ────────────────────────────────────────────────────────────────────
SUBSCRIPTION_ID="f7d47002-d661-4931-a1cc-f7161c7448f6"
LOCATION="eastus"
ADMIN_EMAIL="joel.esperat@outlook.com"
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
RG_NET="rg-lab-networking"

az account set --subscription "$SUBSCRIPTION_ID" --output none
ok "Subscription: azure-lab ($SUBSCRIPTION_ID)"

# ── Resource Groups ───────────────────────────────────────────────────────────
header "Resource Groups"

az group create --name rg-lab-networking --location "$LOCATION" --tags env=lab --output none
ok "rg-lab-networking ($LOCATION)"

az group create --name rg-lab-monitoring --location "$LOCATION" --tags env=lab --output none
ok "rg-lab-monitoring ($LOCATION)"

# ── Custom Policy Definitions ─────────────────────────────────────────────────
header "Custom Policy Definitions"

DENY_PUBLIC_IP_NAME="deny-public-ips"

if az policy definition show \
     --name "$DENY_PUBLIC_IP_NAME" \
     --subscription "$SUBSCRIPTION_ID" \
     --output none 2>/dev/null; then
  ok "Deny public IPs — already exists"
else
  az policy definition create \
    --name "$DENY_PUBLIC_IP_NAME" \
    --display-name "Deny public IPs" \
    --description "Deny public IPs" \
    --mode All \
    --rules '{
      "if": {
        "field": "type",
        "equals": "Microsoft.Network/publicIPAddresses"
      },
      "then": { "effect": "Deny" }
    }' \
    --subscription "$SUBSCRIPTION_ID" \
    --output none
  ok "Deny public IPs — created"
fi

DENY_PUBLIC_IP_DEF_ID="${SCOPE}/providers/Microsoft.Authorization/policyDefinitions/${DENY_PUBLIC_IP_NAME}"

# ── Policy Assignments ────────────────────────────────────────────────────────
header "Policy Assignments"

policy_assigned() {
  local def_id="$1"
  local count
  count=$(az policy assignment list \
    --scope "$SCOPE" \
    --query "[?policyDefinitionId=='${def_id}'] | length(@)" \
    --output tsv 2>/dev/null)
  [[ "${count:-0}" -gt 0 ]]
}

# 1. Allowed VM SKUs — enforced (Deny)
DEF_ALLOWED_SKUS="/providers/Microsoft.Authorization/policyDefinitions/cccc23c7-8427-4f53-ad12-b6a63eb452b3"
if policy_assigned "$DEF_ALLOWED_SKUS"; then
  ok "Allowed VM SKUs — already assigned"
else
  az policy assignment create \
    --display-name "Allowed virtual machine size SKUs" \
    --policy "cccc23c7-8427-4f53-ad12-b6a63eb452b3" \
    --scope "$SCOPE" \
    --enforcement-mode Default \
    --params '{"listOfAllowedSKUs":{"value":["standard_b1s","standard_b1ms","standard_b2s"]}}' \
    --output none
  ok "Allowed VM SKUs — assigned (standard_b1s, standard_b1ms, standard_b2s)"
fi

# 2. Require tag env=lab — audit only, needs system identity for remediation
DEF_TAG="/providers/Microsoft.Authorization/policyDefinitions/1e30110a-5ceb-460c-a204-c1c3969c6d62"
if policy_assigned "$DEF_TAG"; then
  ok "Require tag env=lab — already assigned"
else
  az policy assignment create \
    --display-name "Require a tag and its value on resources" \
    --policy "1e30110a-5ceb-460c-a204-c1c3969c6d62" \
    --scope "$SCOPE" \
    --enforcement-mode DoNotEnforce \
    --location "$LOCATION" \
    --mi-system-assigned \
    --params '{"tagName":{"value":"env"},"tagValue":{"value":"lab"}}' \
    --output none
  ok "Require tag env=lab — assigned (DoNotEnforce)"
fi

# 3. Deny public IPs (custom, Deny effect) — rg-lab-networking excluded so Tailscale VM can have a PIP
if az policy assignment show --name "pol-deny-public-ips" --scope "$SCOPE" --output none 2>/dev/null; then
  ok "Deny public IPs — already assigned"
else
  az policy assignment create \
    --name "pol-deny-public-ips" \
    --display-name "Deny public IPs" \
    --policy "$DENY_PUBLIC_IP_DEF_ID" \
    --scope "$SCOPE" \
    --enforcement-mode Default \
    --not-scopes "${SCOPE}/resourceGroups/${RG_NET}" \
    --output none
  ok "Deny public IPs — assigned (Deny, except ${RG_NET})"
fi

# 4. Allowed locations — enforced (Deny)
DEF_LOCATIONS="/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
if policy_assigned "$DEF_LOCATIONS"; then
  ok "Allowed locations — already assigned"
else
  az policy assignment create \
    --display-name "Allowed locations" \
    --policy "e56962a6-4747-49cd-b67b-bf8b01975c4c" \
    --scope "$SCOPE" \
    --enforcement-mode Default \
    --params '{"listOfAllowedLocations":{"value":["eastus"]}}' \
    --output none
  ok "Allowed locations — assigned (eastus only)"
fi

# ── Virtual Network ───────────────────────────────────────────────────────────
header "Virtual Network"

if az network vnet show \
     --name vnet-lab \
     --resource-group "$RG_NET" \
     --output none 2>/dev/null; then
  ok "vnet-lab — already exists"
else
  az network vnet create \
    --resource-group "$RG_NET" \
    --name vnet-lab \
    --location "$LOCATION" \
    --address-prefix 10.10.0.0/16 \
    --tags env=lab \
    --output none
  ok "vnet-lab — created (10.10.0.0/16)"
fi

# ── Monitoring ────────────────────────────────────────────────────────────────
header "Monitoring"

if az monitor action-group show \
     --name ag-lab-alerts \
     --resource-group rg-lab-monitoring \
     --output none 2>/dev/null; then
  ok "ag-lab-alerts — already exists"
else
  az monitor action-group create \
    --name ag-lab-alerts \
    --resource-group rg-lab-monitoring \
    --short-name "lab-alerts" \
    --location "$LOCATION" \
    --action email email-admin "$ADMIN_EMAIL" \
    --tags env=lab \
    --output none
  ok "ag-lab-alerts — created (email: $ADMIN_EMAIL)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
header "Rebuild complete"

echo ""
echo "  Infrastructure baseline:"
echo "    RGs:      rg-lab-networking, rg-lab-monitoring  (both eastus)"
echo "    Policies: Allowed SKUs | Require tag | Deny public IPs (except rg-lab-networking) | Allowed locations"
echo "    VNet:     vnet-lab 10.10.0.0/16  (rg-lab-networking)"
echo "    Monitor:  ag-lab-alerts → $ADMIN_EMAIL"
echo ""
echo "  RGs created on demand (not yet provisioned):"
echo "    rg-lab-workloads  — workload VMs, NICs, disks"
echo "    rg-lab-security   — Key Vault, managed identities"
echo "    rg-lab-storage    — Storage accounts"
echo ""
