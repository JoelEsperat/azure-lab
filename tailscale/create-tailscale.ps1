# create-tailscale.ps1 - Deploy the Tailscale subnet router VM via Bicep,
# then approve subnet routes via the Tailscale API.

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$EnvFile   = Join-Path $ScriptDir "..\.env"

function Import-EnvFile([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
            $idx = $line.IndexOf('=')
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            if ($key) { [System.Environment]::SetEnvironmentVariable($key, $val, "Process") }
        }
    }
}

Import-EnvFile $EnvFile

if (-not $env:ADMIN_SSH_PUBKEY) { throw "ADMIN_SSH_PUBKEY env var required" }
if (-not $env:TS_API_KEY)       { throw "TS_API_KEY env var required" }

$RG       = "rg-lab-network"
$Template = Join-Path $ScriptDir "..\bicep\tailscale.bicep"

$subscriptionId = az account show --query id -o tsv
$kvName = "kv-lab-" + ($subscriptionId -replace '-', '').Substring(0, 6)

function Invoke-Az([string[]]$AzArgs) {
    az @AzArgs
    if ($LASTEXITCODE -ne 0) { throw "az $($AzArgs[0]) failed (exit $LASTEXITCODE)" }
}

Write-Host "-> Deploying Tailscale VM via bicep/tailscale.bicep..."
Invoke-Az "deployment", "group", "create",
    "--resource-group", $RG,
    "--name", "tailscale-deploy",
    "--template-file", $Template,
    "--parameters", "adminSshPubkey=$env:ADMIN_SSH_PUBKEY",
    "--output", "none"

Write-Host "-> Granting VM managed identity access to Key Vault..."
$vmPrincipalId = az vm identity show --name vm-tailscale --resource-group $RG --query principalId -o tsv
$kvId = az keyvault show --name $kvName --resource-group rg-lab-security --query id -o tsv
$roleSecretsUser = "4633458b-17de-408a-b874-0445c86b69e6"
az role assignment create `
    --role $roleSecretsUser `
    --assignee-object-id $vmPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --scope $kvId `
    --output none 2>$null
Write-Host "  Key Vault Secrets User granted to VM identity"

$PUBLIC_IP = az network public-ip show --resource-group $RG --name pip-tailscale --query ipAddress -o tsv
Write-Host "  VM deployed (Public IP: $PUBLIC_IP)"

Write-Host "-> Waiting for tailscale to join tailnet (first check in 30s)..."
Start-Sleep -Seconds 30

$headers  = @{ Authorization = "Bearer $env:TS_API_KEY" }
$DEVICE_ID = ""

for ($i = 1; $i -le 20; $i++) {
    try {
        $resp   = Invoke-RestMethod -Uri "https://api.tailscale.com/api/v2/tailnet/-/devices" -Headers $headers -UseBasicParsing
        $device = $resp.devices | Where-Object { $_.hostname -eq "azure-gw" } | Sort-Object lastSeen | Select-Object -Last 1
        if ($device) {
            $DEVICE_ID = $device.id
            Write-Host "  Device found: $DEVICE_ID"
            break
        }
    } catch { Write-Host "  API error: $_" }
    Write-Host "  waiting... ($i/20)"
    Start-Sleep -Seconds 15
}

if (-not $DEVICE_ID) {
    Write-Host "Device did not appear within timeout - approve subnet routes manually in the Tailscale admin console"
} else {
    $body = '{"routes":["10.0.0.0/16"]}'
    Invoke-RestMethod -Uri "https://api.tailscale.com/api/v2/device/$DEVICE_ID/routes" `
        -Method Post -Headers $headers -ContentType "application/json" -Body $body -UseBasicParsing | Out-Null
    Write-Host "  Subnet route 10.0.0.0/16 approved"
}
