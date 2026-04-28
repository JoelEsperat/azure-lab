#!/bin/bash

# ─── Azure Lab Bootstrap ──────────────────────────────────────────────────────
# Run ONCE before any infrastructure deployments.
# This script sets up the Azure prerequisites:
#   1. Verify prerequisites (az CLI, jq)
#   2. Set the correct subscription
#   3. Register all required resource providers
#   4. Create the automation service principal
#   5. Initialize the local .env file
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh
#
# Prerequisites:
#   - Azure CLI installed: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
#   - Logged in: az login
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# ─────────────────────────────────────────────────────────────────────────────
header "Step 1 — Prerequisites"
# ─────────────────────────────────────────────────────────────────────────────

# az CLI
if ! command -v az &>/dev/null; then
  fail "Azure CLI not found - https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
fi
ok "Azure CLI: $(az version --query '"azure-cli"' -o tsv)"

# jq (used later for JSON parsing)
if ! command -v jq &>/dev/null; then
  warn "jq not found — https://jqlang.org/download/ (optional but recommended for better output formatting)"
  warn "Some output formatting will be skipped but bootstrap will continue."
  JQ_AVAILABLE=false
else
  ok "jq: $(jq --version)"
  JQ_AVAILABLE=true
fi

# ─────────────────────────────────────────────────────────────────────────────
header "Step 2 — Azure login and subscription"
# ─────────────────────────────────────────────────────────────────────────────

# Check if logged in
if ! az account show &>/dev/null; then
  info "Not logged in. Starting az login..."
  az login
fi

ACCOUNT=$(az account show -o json)
SUBSCRIPTION_ID=$(echo "$ACCOUNT" | grep -o '"id": "[^"]*"' | head -1 | cut -d'"' -f4)
SUBSCRIPTION_NAME=$(echo "$ACCOUNT" | grep -o '"name": "[^"]*"' | head -1 | cut -d'"' -f4)
TENANT_ID=$(echo "$ACCOUNT" | grep -o '"tenantId": "[^"]*"' | head -1 | cut -d'"' -f4)
ADMIN_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

ok "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
ok "Tenant:       $TENANT_ID"
ok "Signed in as: $(az ad signed-in-user show --query userPrincipalName -o tsv)"

echo ""
read -r -p "  Is this the correct subscription? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo ""
  info "Available subscriptions:"
  az account list --query '[].{Name:name, ID:id, State:state}' -o table
  echo ""
  read -r -p "  Enter subscription ID to use: " SUBSCRIPTION_ID
  az account set --subscription "$SUBSCRIPTION_ID"
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  ok "Switched to: $SUBSCRIPTION_ID"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "Step 3 — Register resource providers"
# ─────────────────────────────────────────────────────────────────────────────

PROVIDERS=(
  "microsoft.insights"              # Monitor, Action Groups, alerts
  "microsoft.operationalinsights"   # Log Analytics
  "microsoft.security"              # Defender for Cloud
  "microsoft.keyvault"              # Key Vault
  "microsoft.compute"               # VMs
  "microsoft.network"               # VNet, NSGs, private endpoints
  "microsoft.storage"               # Storage accounts
  "microsoft.web"                   # App Service
  "microsoft.hybridcompute"         # Azure Arc
  "microsoft.guestconfiguration"    # Arc guest configuration policies
  "microsoft.consumption"           # Budgets
  "microsoft.authorization"         # RBAC, Policy
  "microsoft.resources"             # Resource groups, deployments
)

info "Checking ${#PROVIDERS[@]} resource providers..."
echo ""

REGISTERED_IN_BG=false
for provider in "${PROVIDERS[@]}"; do
  STATE=$(az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null || echo "NotFound")
  if [[ "$STATE" == "Registered" ]]; then
    ok "$provider (already registered)"
  else
    az provider register --namespace "$provider" --wait &
    echo -e "  ${YELLOW}⟳${NC} $provider (registering...)"
    REGISTERED_IN_BG=true
  fi
done

# Wait for all background registrations
wait

if [[ "$REGISTERED_IN_BG" == "true" ]]; then
  echo ""
  info "Verifying all providers are registered..."
  ALL_REGISTERED=true
  for provider in "${PROVIDERS[@]}"; do
    STATE=$(az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
    if [[ "$STATE" == "Registered" ]]; then
      ok "$provider"
    else
      warn "$provider — state: $STATE (may still be registering, re-run bootstrap to check)"
      ALL_REGISTERED=false
    fi
  done

  if [[ "$ALL_REGISTERED" == "false" ]]; then
    warn "Some providers are still registering. Wait 60s and re-run if needed."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
header "Step 4 — Create automation service principal"
# ─────────────────────────────────────────────────────────────────────────────

SP_NAME="sp-lab-automation"

# Check if SP already exists
EXISTING_SP=$(az ad sp list --display-name "$SP_NAME" --query '[0].id' -o tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING_SP" ]]; then
  ok "Service principal '$SP_NAME' already exists (object ID: $EXISTING_SP)"
  AUTOMATION_OBJECT_ID="$EXISTING_SP"
  warn "Client secret is not shown for existing SPs."
  warn "If you lost the secret, reset it: az ad sp credential reset --id $EXISTING_SP"
  SP_CLIENT_ID=$(az ad sp show --id "$EXISTING_SP" --query appId -o tsv)
  SP_CLIENT_SECRET=""
else
  info "Creating service principal '$SP_NAME'..."
  SP_OUTPUT=$(az ad sp create-for-rbac \
    --name "$SP_NAME" \
    --skip-assignment \
    --output json)

  SP_CLIENT_ID=$(echo "$SP_OUTPUT" | grep -o '"appId": "[^"]*"' | cut -d'"' -f4)
  SP_CLIENT_SECRET=$(echo "$SP_OUTPUT" | grep -o '"password": "[^"]*"' | cut -d'"' -f4)
  AUTOMATION_OBJECT_ID=$(az ad sp show --id "$SP_CLIENT_ID" --query id -o tsv)

  ok "Created: $SP_NAME"
  ok "Client ID:     $SP_CLIENT_ID"
  ok "Object ID:     $AUTOMATION_OBJECT_ID"
  echo ""
  warn "Client secret shown ONCE — save it now:"
  echo ""
  echo "    $SP_CLIENT_SECRET"
  echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
header "Step 5 — Write .env file"
# ─────────────────────────────────────────────────────────────────────────────

ENV_FILE=".env"

# Always update a key in .env (adds line if missing)
upsert_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i '' "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# Set a key only if it is currently absent or empty (preserves existing values)
init_env() {
  local key="$1" value="$2"
  local existing
  existing=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
  if [[ -z "$existing" ]]; then
    upsert_env "$key" "$value"
  fi
}

if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
AZURE_TENANT_ID=$TENANT_ID
AZURE_LOCATION=eastus

ADMIN_EMAIL=
ADMIN_OBJECT_ID=$ADMIN_OBJECT_ID
ADMIN_SSH_PUBKEY=

AUTOMATION_SP_NAME=$SP_NAME
AUTOMATION_OBJECT_ID=$AUTOMATION_OBJECT_ID
AUTOMATION_CLIENT_ID=${SP_CLIENT_ID:-}
AUTOMATION_CLIENT_SECRET=${SP_CLIENT_SECRET:-}
EOF
  ok "Created: $ENV_FILE"
else
  info "Updating $ENV_FILE (ADMIN_EMAIL and secrets are preserved)..."
  upsert_env "AZURE_SUBSCRIPTION_ID"  "$SUBSCRIPTION_ID"
  upsert_env "AZURE_TENANT_ID"        "$TENANT_ID"
  upsert_env "ADMIN_OBJECT_ID"        "$ADMIN_OBJECT_ID"
  upsert_env "AUTOMATION_SP_NAME"     "$SP_NAME"
  upsert_env "AUTOMATION_OBJECT_ID"   "$AUTOMATION_OBJECT_ID"
  upsert_env "AUTOMATION_CLIENT_ID"   "${SP_CLIENT_ID:-}"
  init_env   "AZURE_LOCATION"         "eastus"
  init_env   "ADMIN_EMAIL"            ""
  init_env   "ADMIN_SSH_PUBKEY"       ""
  # Only write the secret when we just created a new SP; never overwrite an existing one
  if [[ -n "${SP_CLIENT_SECRET:-}" ]]; then
    init_env "AUTOMATION_CLIENT_SECRET" "$SP_CLIENT_SECRET"
  fi
  ok "Updated: $ENV_FILE"
fi

# Add .env to .gitignore if repo exists
if [[ -f ".gitignore" ]]; then
  if ! grep -q "^\.env$" .gitignore; then
    echo ".env" >> .gitignore
    ok "Added .env to .gitignore"
  fi
else
  echo ".env" > .gitignore
  ok "Created .gitignore with .env"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "Bootstrap complete"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "  Summary:"
echo "    Subscription:   $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo "    Tenant:         $TENANT_ID"
echo "    Admin object:   $ADMIN_OBJECT_ID"
echo "    Automation SP:  $SP_NAME ($AUTOMATION_OBJECT_ID)"
echo ""
echo "  Next steps:"
echo "    1. Edit .env and set ADMIN_EMAIL=you@example.com"
echo "    2. Run your infrastructure deployments"
echo ""
if [[ -n "${SP_CLIENT_SECRET:-}" ]]; then
  warn "SP client secret shown above — save it now or reset it later:"
  echo "    az ad sp credential reset --id $AUTOMATION_OBJECT_ID"
  echo ""
fi