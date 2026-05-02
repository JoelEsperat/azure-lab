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
| `TS_AUTHKEY` | `deploy-tailscale` |
| `TS_API_KEY` | `deploy-tailscale`, `destroy-tailscale` |
| `HOME_IP` | `deploy-security` (auto-detected via `api.ipify.org` if unset) |

## Deployment order

Order matters — later layers depend on resource groups from earlier ones:

```
1. subscription.bicep   → creates resource groups (sub scope)
2. policy.bicep         → assignments (sub scope); must follow subscription
3. network.bicep        → VNet + subnets in rg-lab-network
4. monitoring.bicep     → Log Analytics workspace + action group in rg-lab-monitoring
5. activitylog.bicep    → subscription Activity Log diagnostic settings (sub scope); must follow monitoring
6. security.bicep       → Key Vault + RBAC in rg-lab-security
```

`make build` / `.\deploy.ps1 build` runs all five in order.

The Tailscale subnet router (`tailscale.bicep`) is deployed on-demand outside the baseline — create/destroy as needed to control costs.

## Architecture notes

**Policy constraints** — four subscription-scope assignments in `policy.bicep`:
- Allowed locations: `centralus` only
- Allowed VM SKUs: `standard_b1s`, `standard_b2pts_v2` (policy matching is case-insensitive; the Bicep param uses title case)
- Require tag `env=lab` (audit only, non-blocking)
- Deny public IPs (custom policy) — enforced everywhere **except** `rg-lab-network` (notScope exception allows the Tailscale VM's public IP)

Any new VM SKU must be added to `allowedVmSkus` in `policy.bicep` before deploying resources that use it.

**Tailscale subnet router** — `tailscale.bicep` loads `tailscale/cloud-init.yaml` at Bicep compile time via `loadTextContent()`, substituting `${TS_AUTHKEY}` before base64-encoding it as `customData`. The VM hostname `tailscale` is hardcoded in both `cloud-init.yaml` and the create/destroy scripts (used to identify the tailnet device via Tailscale API).

The create script deploys Bicep then polls the Tailscale API until the device appears, then approves the `10.0.0.0/16` route. The destroy script removes the tailnet device before deleting Azure resources.

**Key Vault naming** — `security.bicep` derives the vault name deterministically: `kv-lab-` + first 6 chars of subscription ID (hyphens stripped). This avoids naming conflicts while keeping it reproducible.

**No Bicep modules or parameter files** — each `.bicep` file is self-contained with defaults. Parameters are passed inline via `--parameters` on the CLI.
