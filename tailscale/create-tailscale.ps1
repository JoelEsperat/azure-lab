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
            if ($key) { [System.Environment]::SetEnvironmentVariable($key, $val, "Process") }
        }
    }
}

Import-EnvFile $EnvFile

if (-not $env:ADMIN_SSH_PUBKEY) { throw "ADMIN_SSH_PUBKEY env var required" }
if (-not $env:TS_AUTHKEY)       { throw "TS_AUTHKEY env var required" }
if (-not $env:TS_API_KEY)       { throw "TS_API_KEY env var required" }

$RG       = "rg-lab-network"
$Template = Join-Path $ScriptDir "..\bicep\tailscale.bicep"

Write-Host "-> Deploying Tailscale VM via bicep/tailscale.bicep..."
az deployment group create `
    --resource-group $RG `
    --name tailscale-deploy `
    --template-file $Template `
    --parameters adminSshPubkey="$env:ADMIN_SSH_PUBKEY" tsAuthKey="$env:TS_AUTHKEY" `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Deployment failed" }

$PUBLIC_IP = az network public-ip show --resource-group $RG --name pip-tailscale --query ipAddress -o tsv
Write-Host "  VM deployed (Public IP: $PUBLIC_IP)"

Write-Host "-> Waiting for tailscale to join tailnet (first check in 30s)..."
Start-Sleep -Seconds 30

$headers  = @{ Authorization = "Bearer $env:TS_API_KEY" }
$DEVICE_ID = ""

for ($i = 1; $i -le 20; $i++) {
    try {
        $resp   = Invoke-RestMethod -Uri "https://api.tailscale.com/api/v2/tailnet/-/devices" -Headers $headers -UseBasicParsing
        $device = $resp.devices | Where-Object { $_.hostname -eq "tailscale" } | Sort-Object lastSeen | Select-Object -Last 1
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
