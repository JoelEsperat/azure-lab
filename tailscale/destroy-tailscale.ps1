# destroy-tailscale.ps1 - Delete the Tailscale subnet router VM and its resources,
# and remove the device from the Tailscale tailnet.

$ErrorActionPreference = "SilentlyContinue"   # most deletes are best-effort

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

$RG       = "rg-lab-network"
$VM_NAME  = "vm-tailscale"
$NIC_NAME = "nic-tailscale"
$PIP_NAME = "pip-tailscale"
$NSG_NAME = "nsg-tailscale"

Write-Host "-> Removing device from Tailscale tailnet..."
if ($env:TS_API_KEY) {
    $headers = @{ Authorization = "Bearer $env:TS_API_KEY" }
    try {
        $resp    = Invoke-RestMethod -Uri "https://api.tailscale.com/api/v2/tailnet/-/devices" -Headers $headers -UseBasicParsing
        $devices = $resp.devices | Where-Object { $_.hostname -eq "azure" }
        if ($devices) {
            foreach ($device in $devices) {
                try {
                    Invoke-RestMethod -Uri "https://api.tailscale.com/api/v2/device/$($device.id)" `
                        -Method Delete -Headers $headers -UseBasicParsing | Out-Null
                    Write-Host "  device $($device.id) removed"
                } catch {
                    Write-Host "  failed to remove device $($device.id)"
                }
            }
        } else {
            Write-Host "  - no device found (already removed)"
        }
    } catch {
        Write-Host "  - failed to query Tailscale API"
    }
} else {
    Write-Host "  - TS_API_KEY not set, skipping"
}

Write-Host "-> Deleting VM and OS disk..."
az vm delete --resource-group $RG --name $VM_NAME --yes --output none
if ($LASTEXITCODE -eq 0) { Write-Host "  $VM_NAME deleted" } else { Write-Host "  - $VM_NAME (not found)" }

$DISK_NAME = az disk list --resource-group $RG --query "[?starts_with(name, '${VM_NAME}_OsDisk')].name" -o tsv
if ($DISK_NAME) {
    az disk delete --resource-group $RG --name $DISK_NAME --yes --output none
    if ($LASTEXITCODE -eq 0) { Write-Host "  $DISK_NAME deleted" } else { Write-Host "  - disk delete failed" }
}

Write-Host "-> Deleting NIC..."
az network nic delete --resource-group $RG --name $NIC_NAME --output none
if ($LASTEXITCODE -eq 0) { Write-Host "  $NIC_NAME deleted" } else { Write-Host "  - $NIC_NAME (not found)" }

Write-Host "-> Deleting public IP..."
az network public-ip delete --resource-group $RG --name $PIP_NAME --output none
if ($LASTEXITCODE -eq 0) { Write-Host "  $PIP_NAME deleted" } else { Write-Host "  - $PIP_NAME (not found)" }

Write-Host "-> Deleting NSG..."
az network nsg delete --resource-group $RG --name $NSG_NAME --output none
if ($LASTEXITCODE -eq 0) { Write-Host "  $NSG_NAME deleted" } else { Write-Host "  - $NSG_NAME (not found)" }

Write-Host ""
Write-Host "Tailscale VM destroyed. vnet-lab and rg-lab-network are intact."
