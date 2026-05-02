# deploy.ps1 - PowerShell equivalent of the Makefile for Windows
# Usage: .\deploy.ps1 <target>
# Example: .\deploy.ps1 deploy-network

param(
    [Parameter(Position = 0)]
    [string]$Target = "help"
)

$ErrorActionPreference = "Stop"

$LOCATION      = "centralus"
$RG_NETWORK    = "rg-lab-network"
$RG_MONITORING = "rg-lab-monitoring"
$RG_SECURITY   = "rg-lab-security"

function Import-EnvFile([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
            $idx = $line.IndexOf('=')
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            if ($key) { [System.Environment]::SetEnvironmentVariable($key, $val, "Process") }
        }
    }
}

Import-EnvFile (Join-Path $PSScriptRoot ".env")

function Assert-EnvVar([string[]]$Names) {
    foreach ($n in $Names) {
        if (-not [System.Environment]::GetEnvironmentVariable($n, "Process")) {
            throw "$n not set (add it to .env or set in shell)"
        }
    }
}

function Get-HomeIp {
    if ($env:HOME_IP) { return $env:HOME_IP }
    return (Invoke-RestMethod -Uri "https://api.ipify.org" -UseBasicParsing).Trim()
}

function Invoke-Az([string[]]$Args) {
    az @Args
    if ($LASTEXITCODE -ne 0) { throw "az $($Args[0]) failed (exit $LASTEXITCODE)" }
}

# ── Targets ──────────────────────────────────────────────────────────────────

function Invoke-Help {
    @"
Azure Lab - Available commands
Usage: .\deploy.ps1 <target>

Bootstrap (one-time setup):
  bootstrap                  Run bootstrap script (prerequisites, SP, providers)

Infrastructure deployment:
  build                      Full baseline (all Bicep layers in order)
  deploy-subscription        Deploy bicep/subscription.bicep (RGs)
  deploy-network             Deploy bicep/network.bicep (VNet + subnets)
  deploy-monitoring          Deploy bicep/monitoring.bicep (action group)
  deploy-policy              Deploy bicep/policy.bicep (defs + assignments)
  deploy-security            Deploy bicep/security.bicep (KV + RBAC + ACL)
  whatif-subscription        Preview subscription.bicep changes
  whatif-network             Preview network.bicep changes
  whatif-monitoring          Preview monitoring.bicep changes
  whatif-policy              Preview policy.bicep changes
  whatif-security            Preview security.bicep changes
  deploy-tailscale           Deploy the Tailscale subnet router VM
  whatif-tailscale           Preview tailscale.bicep changes
  destroy-tailscale          Destroy the Tailscale subnet router VM

Environment:
  env                        Show current environment configuration
  validate                   Validate environment and prerequisites
"@
}

function Invoke-Bootstrap {
    Write-Host "Running bootstrap script..."
    & "$PSScriptRoot\scripts\bootstrap.ps1"
}

function Invoke-DeploySubscription {
    Write-Host "Deploying bicep/subscription.bicep..."
    Invoke-Az "deployment", "sub", "create",
        "--location", $LOCATION,
        "--name", "subscription-baseline",
        "--template-file", "bicep/subscription.bicep",
        "--output", "none"
    Write-Host "  subscription baseline deployed"
}

function Invoke-DeployNetwork {
    Write-Host "Deploying bicep/network.bicep..."
    Invoke-Az "deployment", "group", "create",
        "--resource-group", $RG_NETWORK,
        "--name", "network-baseline",
        "--template-file", "bicep/network.bicep",
        "--output", "none"
    Write-Host "  network baseline deployed"
}

function Invoke-DeployMonitoring {
    Assert-EnvVar "ADMIN_EMAIL"
    Write-Host "Deploying bicep/monitoring.bicep..."
    Invoke-Az "deployment", "group", "create",
        "--resource-group", $RG_MONITORING,
        "--name", "monitoring-baseline",
        "--template-file", "bicep/monitoring.bicep",
        "--parameters", "adminEmail=$env:ADMIN_EMAIL",
        "--output", "none"
    Write-Host "  monitoring baseline deployed"
}

function Invoke-DeployPolicy {
    Write-Host "Deploying bicep/policy.bicep..."
    Invoke-Az "deployment", "sub", "create",
        "--location", $LOCATION,
        "--name", "policy-baseline",
        "--template-file", "bicep/policy.bicep",
        "--output", "none"
    Write-Host "  policy baseline deployed"
}

function Invoke-DeploySecurity {
    Assert-EnvVar "ADMIN_OBJECT_ID", "AUTOMATION_OBJECT_ID"
    $homeIp = Get-HomeIp
    if (-not $homeIp) { throw "Could not detect public IP - set HOME_IP in .env" }
    Write-Host "  Home IP: $homeIp"
    Write-Host "Deploying bicep/security.bicep..."
    Invoke-Az "deployment", "group", "create",
        "--resource-group", $RG_SECURITY,
        "--name", "security-baseline",
        "--template-file", "bicep/security.bicep",
        "--parameters", "homeIp=$homeIp", "adminObjectId=$env:ADMIN_OBJECT_ID", "automationObjectId=$env:AUTOMATION_OBJECT_ID",
        "--output", "none"
    Write-Host "  security baseline deployed"
}

function Invoke-WhatIfSubscription {
    Invoke-Az "deployment", "sub", "what-if",
        "--location", $LOCATION,
        "--template-file", "bicep/subscription.bicep"
}

function Invoke-WhatIfNetwork {
    Invoke-Az "deployment", "group", "what-if",
        "--resource-group", $RG_NETWORK,
        "--template-file", "bicep/network.bicep"
}

function Invoke-WhatIfMonitoring {
    Assert-EnvVar "ADMIN_EMAIL"
    Invoke-Az "deployment", "group", "what-if",
        "--resource-group", $RG_MONITORING,
        "--template-file", "bicep/monitoring.bicep",
        "--parameters", "adminEmail=$env:ADMIN_EMAIL"
}

function Invoke-WhatIfPolicy {
    Invoke-Az "deployment", "sub", "what-if",
        "--location", $LOCATION,
        "--template-file", "bicep/policy.bicep"
}

function Invoke-WhatIfSecurity {
    Assert-EnvVar "ADMIN_OBJECT_ID", "AUTOMATION_OBJECT_ID"
    $homeIp = Get-HomeIp
    Invoke-Az "deployment", "group", "what-if",
        "--resource-group", $RG_SECURITY,
        "--template-file", "bicep/security.bicep",
        "--parameters", "homeIp=$homeIp", "adminObjectId=$env:ADMIN_OBJECT_ID", "automationObjectId=$env:AUTOMATION_OBJECT_ID"
}

function Invoke-Build {
    Invoke-DeploySubscription
    Invoke-DeployPolicy
    Invoke-DeployNetwork
    Invoke-DeployMonitoring
    Invoke-DeploySecurity
    Write-Host "Lab baseline deployed"
}

function Invoke-DeployTailscale {
    Write-Host "Deploying Tailscale subnet router VM..."
    & "$PSScriptRoot\tailscale\create-tailscale.ps1"
}

function Invoke-WhatIfTailscale {
    Assert-EnvVar "ADMIN_SSH_PUBKEY"
    Invoke-Az "deployment", "group", "what-if",
        "--resource-group", $RG_NETWORK,
        "--template-file", "bicep/tailscale.bicep",
        "--parameters", "adminSshPubkey=$env:ADMIN_SSH_PUBKEY", "tsAuthKey=dummy-for-whatif"
}

function Invoke-DestroyTailscale {
    Write-Host "Destroying Tailscale subnet router VM..."
    & "$PSScriptRoot\tailscale\destroy-tailscale.ps1"
}

function Invoke-Env {
    Write-Host "Environment Configuration"
    Write-Host "-------------------------"
    if (Test-Path ".env") {
        Get-Content ".env" | ForEach-Object {
            if ($_ -match 'AUTOMATION_CLIENT_SECRET|TS_AUTHKEY|TS_API_KEY') { return }
            if ($_ -match '=') { Write-Host ($_ -replace '=.*$', '=********') }
        }
    } else {
        Write-Host "  .env file not found"
    }
}

function Invoke-Validate {
    Write-Host "Validating environment..."

    # az CLI present?
    if (Get-Command az -ErrorAction SilentlyContinue) {
        Write-Host "  az CLI installed"
    } else {
        Write-Host "  az CLI not found - https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
        return 1
    }

    # Check login; if not logged in, try interactive login
    try {
        az account show > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Azure CLI logged in"
        } else {
            throw "NotLoggedIn"
        }
    } catch {
        Write-Host "  Azure CLI not authenticated. Attempting interactive 'az login'..."
        try {
            az login
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  az login failed. Please run 'az login' manually and retry."
                return 1
            }
            Write-Host "  Azure CLI logged in"
        } catch {
            Write-Host "  az login failed (exception). Please run 'az login' manually and retry."
            return 1
        }
    }

    if (Test-Path ".env") { Write-Host "  .env file exists" } else { Write-Host "  .env file not found (run .\deploy.ps1 bootstrap first)" }
    Write-Host "Validation complete"
    return 0
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

switch ($Target) {
    "help"                     { Invoke-Help }
    "bootstrap"                { Invoke-Bootstrap }
    "build"                    { Invoke-Build }
    "deploy-subscription"      { Invoke-DeploySubscription }
    "deploy-network"           { Invoke-DeployNetwork }
    "deploy-monitoring"        { Invoke-DeployMonitoring }
    "deploy-policy"            { Invoke-DeployPolicy }
    "deploy-security"          { Invoke-DeploySecurity }
    "whatif-subscription"      { Invoke-WhatIfSubscription }
    "whatif-network"           { Invoke-WhatIfNetwork }
    "whatif-monitoring"        { Invoke-WhatIfMonitoring }
    "whatif-policy"            { Invoke-WhatIfPolicy }
    "whatif-security"          { Invoke-WhatIfSecurity }
    "deploy-tailscale"         { Invoke-DeployTailscale }
    "whatif-tailscale"         { Invoke-WhatIfTailscale }
    "destroy-tailscale"        { Invoke-DestroyTailscale }
    "env"                      { Invoke-Env }
    "validate"                 { Invoke-Validate }
    default                    { Write-Host "Unknown target: $Target"; Invoke-Help }
}
