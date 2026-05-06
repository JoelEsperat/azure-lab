# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal Azure homelab landing zone: single subscription, single region (`centralus`), budget ≤ $10/month. Bicep is the source of truth for all ARM resources. Shell/PowerShell scripts handle what Bicep can't (Entra ID service principals, CLI prerequisites, Tailscale API calls).

## Running commands

Two equivalent toolsets exist — pick based on OS:

**Linux/macOS (bash + make):**
```bash
make bootstrap                   # one-time setup
make build                       # deploy all Bicep layers in order
make deploy-<layer>              # deploy a single layer
make whatif-<layer>              # dry-run a single layer
make deploy-tailscale            # spin up Tailscale VM
make destroy-tailscale           # tear down Tailscale VM
```

**Windows (PowerShell — no WSL required):**
```powershell
.\deploy.ps1 bootstrap
.\deploy.ps1 build
.\deploy.ps1 deploy-<layer>
.\deploy.ps1 whatif-<layer>
.\deploy.ps1 deploy-tailscale
.\deploy.ps1 destroy-tailscale
```

## Environment setup

Copy `.env.sample` → `.env` and populate. The `.env` file is sourced by both the Makefile and the PS1 scripts at runtime. Required variables:

| Variable | When needed |
|---|---|
| `ADMIN_EMAIL` | `deploy-monitoring` |
| `ADMIN_OBJECT_ID` | `deploy-security` |
| `AUTOMATION_OBJECT_ID` | `deploy-security` |
| `ADMIN_SSH_PUBKEY` | `deploy-tailscale` |
| `TS_API_KEY` | `deploy-tailscale`, `destroy-tailscale` |
| `HOME_IP` | `deploy-security`, `deploy-storage` (auto-detected via `api.ipify.org` if unset) |

**GitHub Actions (optional, any OS):**

Trigger manually from the Actions tab or GitHub CLI:
```bash
gh workflow run tailscale-create.yml
gh workflow run tailscale-destroy.yml
```
The workflows call the same bash scripts and authenticate via Azure OIDC (no stored client secret). Required one-time setup — see below.

## GitHub Actions setup (one-time)

1. Create an app registration in Entra ID and note its **client ID** and your **tenant ID**.
2. Add a federated credential on the app:
   - Issuer: `https://token.actions.githubusercontent.com`
   - Subject: `repo:<org>/<repo>:ref:refs/heads/main`
   - Audience: `api://AzureADTokenExchange`
3. Assign the app the **Contributor** role on `rg-lab-network` only.
4. Add these repository secrets (Settings → Secrets → Actions):

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| `ADMIN_SSH_PUBKEY` | SSH public key for VM admin |
| `TS_API_KEY` | Tailscale API key |

`TS_AUTHKEY` is no longer a required secret — store it manually in Key Vault before triggering the workflow (see Tailscale auth key section below).

## Deployment order

Order matters — later layers depend on resource groups from earlier ones:

```
1. subscription.bicep   → creates resource groups (sub scope)
2. policy.bicep         → assignments (sub scope); must follow subscription
3. network.bicep        → VNet + subnets in rg-lab-network
4. monitoring.bicep     → Log Analytics workspace + action group in rg-lab-monitoring
5. activitylog.bicep    → subscription Activity Log diagnostic settings (sub scope); must follow monitoring
6. security.bicep       → Key Vault + RBAC in rg-lab-security
7. storage.bicep        → blob storage account in rg-lab-workloads; must follow network (snet-workloads)
```

`make build` / `.\deploy.ps1 build` runs all seven in order.

The Tailscale subnet router (`tailscale.bicep`) is deployed on-demand outside the baseline — create/destroy as needed to control costs.

## Architecture notes

**Policy constraints** — four subscription-scope assignments in `policy.bicep`:
- Allowed locations: `centralus` only
- Allowed VM SKUs: `standard_b1s`, `standard_b2pts_v2` (policy matching is case-insensitive; the Bicep param uses title case)
- Require tag `env=lab` (audit only, non-blocking)
- Deny public IPs (custom policy) — enforced everywhere **except** `rg-lab-network` (notScope exception allows the Tailscale VM's public IP)

Any new VM SKU must be added to `allowedVmSkus` in `policy.bicep` before deploying resources that use it.

**Tailscale subnet router** — `tailscale.bicep` loads `tailscale/cloud-init.yaml` at Bicep compile time via `loadTextContent()`, substituting the Key Vault name (`${KV_NAME}`) before base64-encoding it as `customData`. The VM is given a system-assigned managed identity. The create script grants the identity **Key Vault Secrets User** on the KV after deployment. At boot, `cloud-init.yaml` fetches the `ts-authkey` secret from Key Vault via the IMDS token endpoint and passes it to `tailscale up` — the auth key never appears in VM metadata or ARM deployment history.

The Tailscale hostname `azure` is hardcoded in both `cloud-init.yaml` (via `--hostname=azure`) and the create/destroy scripts (used to identify the tailnet device via Tailscale API). The Azure VM OS hostname (`computerName`) matches.

The create script deploys Bicep, creates the KV role assignment, then polls the Tailscale API until the device appears, then approves the `10.0.0.0/16` route. The destroy script removes the tailnet device before deleting Azure resources.

**Tailscale auth key** — store the key in Key Vault before deploying the VM (the VM fetches it at boot; redeploys need a fresh key stored before triggering):
```bash
KV_NAME="kv-lab-$(az account show --query id -o tsv | tr -d '-' | cut -c1-6)"
az keyvault secret set --vault-name "$KV_NAME" --name ts-authkey --value "<authkey>"
```

**Key Vault naming** — `security.bicep` derives the vault name deterministically: `kv-lab-` + first 6 chars of subscription ID (hyphens stripped). This avoids naming conflicts while keeping it reproducible.

**Storage account naming** — `storage.bicep` uses the same pattern: `stlab` + first 8 chars of subscription ID (hyphens stripped). Storage account names cannot contain hyphens.

**Storage network access** — Standard_LRS StorageV2 in `rg-lab-workloads`. Firewall: `defaultAction: Deny`, home IP allowlisted, `snet-workloads` (10.0.1.0/24) allowlisted via service endpoint. Access from tailnet laptop uses the home IP rule (storage resolves to a public IP; Tailscale only routes 10.0.0.0/16).

**No Bicep modules or parameter files** — each `.bicep` file is self-contained with defaults. Parameters are passed inline via `--parameters` on the CLI.
