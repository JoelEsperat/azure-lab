# bootstrap.ps1 — Azure Lab bootstrap (one-time setup)
# Run ONCE before any infrastructure deployments.
# Prerequisites:
#   - Azure CLI installed: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
#   - Logged in: az login

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$EnvFile   = Join-Path $ScriptDir "..\.env"

function Write-Ok($msg)   { Write-Host "  [OK] $msg" }
function Write-Info($msg) { Write-Host "  [>>] $msg" }
function Write-Warn($msg) { Write-Host "  [!!] $msg" }
function Write-Fail($msg) { Write-Host "  [XX] $msg"; exit 1 }

function Write-Header($title) {
    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────"
    Write-Host "  $title"
    Write-Host "────────────────────────────────────────────────────────────"
}

# ── Step 1 — Prerequisites ───────────────────────────────────────────────────
Write-Header "Step 1 — Prerequisites"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Fail "Azure CLI not found — https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
}
$azVersion = az version --query '"azure-cli"' -o tsv
Write-Ok "Azure CLI: $azVersion"

# ── Step 2 — Azure login and subscription ────────────────────────────────────
Write-Header "Step 2 — Azure login and subscription"

az account show | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Info "Not logged in. Starting az login..."
    az login
}

$account         = az account show | ConvertFrom-Json
$SUBSCRIPTION_ID   = $account.id
$SUBSCRIPTION_NAME = $account.name
$TENANT_ID         = $account.tenantId
$ADMIN_OBJECT_ID   = (az ad signed-in-user show --query id -o tsv).Trim()

Write-Ok "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
Write-Ok "Tenant:       $TENANT_ID"
Write-Ok "Signed in as: $((az ad signed-in-user show --query userPrincipalName -o tsv).Trim())"

Write-Host ""
$confirm = Read-Host "  Is this the correct subscription? [y/N]"
if ($confirm -notin @('y','Y')) {
    Write-Host ""
    Write-Info "Available subscriptions:"
    az account list --query '[].{Name:name, ID:id, State:state}' -o table
    Write-Host ""
    $SUBSCRIPTION_ID = (Read-Host "  Enter subscription ID to use").Trim()
    az account set --subscription $SUBSCRIPTION_ID
    $SUBSCRIPTION_ID = (az account show --query id -o tsv).Trim()
    Write-Ok "Switched to: $SUBSCRIPTION_ID"
}

# ── Step 3 — Register resource providers ─────────────────────────────────────
Write-Header "Step 3 — Register resource providers"

$PROVIDERS = @(
    "microsoft.insights",
    "microsoft.operationalinsights",
    "microsoft.security",
    "microsoft.keyvault",
    "microsoft.compute",
    "microsoft.network",
    "microsoft.storage",
    "microsoft.web",
    "microsoft.hybridcompute",
    "microsoft.guestconfiguration",
    "microsoft.consumption",
    "microsoft.authorization",
    "microsoft.resources"
)

Write-Info "Checking $($PROVIDERS.Count) resource providers..."
Write-Host ""

$toRegister = @()
foreach ($provider in $PROVIDERS) {
    $state = (az provider show --namespace $provider --query registrationState -o tsv 2>$null).Trim()
    if ($state -eq "Registered") {
        Write-Ok "$provider (already registered)"
    } else {
        Write-Host "  [~] $provider (registering...)"
        $toRegister += $provider
    }
}

foreach ($provider in $toRegister) {
    az provider register --namespace $provider | Out-Null
}

if ($toRegister.Count -gt 0) {
    Write-Host ""
    Write-Info "Waiting for registrations to complete..."
    foreach ($provider in $toRegister) {
        $maxWait = 60
        $waited  = 0
        do {
            Start-Sleep -Seconds 5
            $waited += 5
            $state = (az provider show --namespace $provider --query registrationState -o tsv 2>$null).Trim()
        } while ($state -ne "Registered" -and $waited -lt $maxWait)

        if ($state -eq "Registered") {
            Write-Ok "$provider"
        } else {
            Write-Warn "$provider — state: $state (may still be registering, re-run bootstrap to check)"
        }
    }
}

# ── Step 4 — Create automation service principal ──────────────────────────────
Write-Header "Step 4 — Create automation service principal"

$SP_NAME          = "sp-lab-automation"
$SP_CLIENT_SECRET = ""

$existingSp = (az ad sp list --display-name $SP_NAME --query '[0].id' -o tsv 2>$null).Trim()

if ($existingSp) {
    Write-Ok "Service principal '$SP_NAME' already exists (object ID: $existingSp)"
    $AUTOMATION_OBJECT_ID = $existingSp
    Write-Warn "Client secret is not shown for existing SPs."
    Write-Warn "If you lost the secret, reset it: az ad sp credential reset --id $existingSp"
    $SP_CLIENT_ID = (az ad sp show --id $existingSp --query appId -o tsv).Trim()
} else {
    Write-Info "Creating service principal '$SP_NAME'..."
    $spOutput = az ad sp create-for-rbac --name $SP_NAME --skip-assignment --output json | ConvertFrom-Json
    $SP_CLIENT_ID         = $spOutput.appId
    $SP_CLIENT_SECRET     = $spOutput.password
    $AUTOMATION_OBJECT_ID = (az ad sp show --id $SP_CLIENT_ID --query id -o tsv).Trim()

    Write-Ok "Created: $SP_NAME"
    Write-Ok "Client ID:     $SP_CLIENT_ID"
    Write-Ok "Object ID:     $AUTOMATION_OBJECT_ID"
    Write-Host ""
    Write-Warn "Client secret shown ONCE — save it now:"
    Write-Host ""
    Write-Host "    $SP_CLIENT_SECRET"
    Write-Host ""
}

# ── Step 5 — Write .env file ──────────────────────────────────────────────────
Write-Header "Step 5 — Write .env file"

function Upsert-EnvKey([string]$File, [string]$Key, [string]$Value) {
    $lines = if (Test-Path $File) { Get-Content $File } else { @() }
    $pattern = "^$([regex]::Escape($Key))="
    $newLine  = "$Key=$Value"
    if ($lines -match $pattern) {
        $lines = $lines -replace $pattern, $newLine
    } else {
        $lines += $newLine
    }
    $lines | Set-Content $File -Encoding UTF8
}

function Init-EnvKey([string]$File, [string]$Key, [string]$Value) {
    $lines    = if (Test-Path $File) { Get-Content $File } else { @() }
    $existing = ($lines | Where-Object { $_ -match "^$([regex]::Escape($Key))=" }) -replace "^$([regex]::Escape($Key))=", ""
    if (-not $existing) { Upsert-EnvKey $File $Key $Value }
}

if (-not (Test-Path $EnvFile)) {
    @"
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
AZURE_TENANT_ID=$TENANT_ID
AZURE_LOCATION=centralus

ADMIN_EMAIL=
ADMIN_OBJECT_ID=$ADMIN_OBJECT_ID
ADMIN_SSH_PUBKEY=

AUTOMATION_SP_NAME=$SP_NAME
AUTOMATION_OBJECT_ID=$AUTOMATION_OBJECT_ID
AUTOMATION_CLIENT_ID=$SP_CLIENT_ID
AUTOMATION_CLIENT_SECRET=$SP_CLIENT_SECRET
"@ | Set-Content $EnvFile -Encoding UTF8
    Write-Ok "Created: $EnvFile"
} else {
    Write-Info "Updating $EnvFile (ADMIN_EMAIL and secrets are preserved)..."
    Upsert-EnvKey $EnvFile "AZURE_SUBSCRIPTION_ID"  $SUBSCRIPTION_ID
    Upsert-EnvKey $EnvFile "AZURE_TENANT_ID"        $TENANT_ID
    Upsert-EnvKey $EnvFile "ADMIN_OBJECT_ID"        $ADMIN_OBJECT_ID
    Upsert-EnvKey $EnvFile "AUTOMATION_SP_NAME"     $SP_NAME
    Upsert-EnvKey $EnvFile "AUTOMATION_OBJECT_ID"   $AUTOMATION_OBJECT_ID
    Upsert-EnvKey $EnvFile "AUTOMATION_CLIENT_ID"   $SP_CLIENT_ID
    Init-EnvKey   $EnvFile "AZURE_LOCATION"         "centralus"
    Init-EnvKey   $EnvFile "ADMIN_EMAIL"            ""
    Init-EnvKey   $EnvFile "ADMIN_SSH_PUBKEY"       ""
    if ($SP_CLIENT_SECRET) {
        Init-EnvKey $EnvFile "AUTOMATION_CLIENT_SECRET" $SP_CLIENT_SECRET
    }
    Write-Ok "Updated: $EnvFile"
}

# Ensure .gitignore exists and contains .env
$GitIgnore = Join-Path $ScriptDir "..\.gitignore"
if (Test-Path $GitIgnore) {
    $content = Get-Content $GitIgnore -Raw
    if ($content -notmatch '(?m)^\.env$') {
        Add-Content $GitIgnore "`n.env"
        Write-Ok "Added .env to .gitignore"
    }
} else {
    ".env" | Set-Content $GitIgnore -Encoding UTF8
    Write-Ok "Created .gitignore with .env"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Header "Bootstrap complete"

Write-Host ""
Write-Host "  Summary:"
Write-Host "    Subscription:   $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
Write-Host "    Tenant:         $TENANT_ID"
Write-Host "    Admin object:   $ADMIN_OBJECT_ID"
Write-Host "    Automation SP:  $SP_NAME ($AUTOMATION_OBJECT_ID)"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. Edit .env and set ADMIN_EMAIL=you@example.com"
Write-Host "    2. Set ADMIN_SSH_PUBKEY in .env to your SSH public key"
Write-Host "    3. Run your infrastructure deployments: .\deploy.ps1 build"
Write-Host ""
if ($SP_CLIENT_SECRET) {
    Write-Warn "SP client secret shown above — save it now or reset it later:"
    Write-Host "    az ad sp credential reset --id $AUTOMATION_OBJECT_ID"
    Write-Host ""
}
