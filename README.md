# Azure Lab

This document describes the architecture of my Azure lab. The goal is to build a minimal Azure landing zone, using best pratices, for a low budget, to support a few lab workloads. 

---

## Design Principles

- **Budget** under $10/month
- **Single subscription** and **single region** (Central US)
- **Governance** — policies enforce allowed SKU, location, and tagging
- **Private connectivity** - the Azure VNet is an extension of my home network - no internet exposure
- **Zero-trust hybrid connectivity** — the Azure VNet is connected to my Tailscale tailnet - the only component with internet connectivity is a Tailscale VM acting as a subnet router to my tailnet - to keep the cost low the VM and the public IPv4 are provisioned only when needed
- **Infrastructure as code**

---

## Subscription Layout

```
Subscription: azure-lab
│
├── Governance (subscription-scoped)
│   ├── Policy: Allowed locations → centralus
│   ├── Policy: Allowed VM SKUs  → B1s, B2pts_v2
│   ├── Policy: Require tag      → env=lab (audit)
│   └── Policy: Deny public IPs  → enforce
│
├── rg-lab-monitoring   ← Log Analytics workspace, action groups, alert rules
├── rg-lab-network   ← VNet, NSGs, subnets, Tailscale subnet router
├── rg-lab-security     ← Key Vault, managed identities
└── rg-lab-workloads    ← Workloads (compute, storage, AI)
```

---

## Network Topology

```
vnet-lab  10.0.0.0/16   (rg-lab-network, centralus)
│
├── snet-gateway    10.0.0.0/24   hybrid connectivity (Tailscale VM)
└── snet-pes        10.0.1.0/24   private endpoints
└── snet-workloads  10.0.2.0/24   workloads
```

The Tailscale subnet router is the only ingress path into the VNet. It is much cheaper than a VPN Gateway and sufficient for my homelab, and it provides zero trust networking. 

---

## Hybrid Connectivity (Tailscale)

Connectivity with my home network and devices is provided through Tailscale using a lightweight Ubuntu VM that joins the tailnet and advertises the entire Azure subnet `10.0.0.0/16`.

```
Home devices ──── Tailscale tailnet ──── vm-tailscale (Azure, snet-gateway)
                                               │
                                         vnet-lab 10.0.0.0/16
                                               │
                                         Azure workloads
```

| Property | Value |
|---|---|
| VM name | `vm-tailscale` |
| Resource group | `rg-lab-network` |
| Size | `Standard_B2pts_v2` |
| Image | Ubuntu 24.04 |
| Subnet | `snet-gateway` (10.0.0.0/24) |
| Public IP | Standard Static (required for internet connectivity) |
| NSG | SSH from VNet only |
| IP forwarding | Enabled via cloud-init (`net.ipv4.ip_forward=1`) |
| Tailscale | Enabled via cloud-init - advertises `10.0.0.0/16` on my tailnet |

Deployed via `bicep/tailscale.bicep`, wrapped by `tailscale/create-tailscale.sh` (which also approves the subnet route via the Tailscale API). Destroyed via `tailscale/destroy-tailscale.sh`.

The deployment also installs the Azure Monitor Agent, attaches a Data Collection Rule that forwards syslogs and performance counters to the Log Analytics workspace, and forwards NSG diagnostic logs to the workspace.

---

## Policies

Scope: subscription scope

| Policy | Effect | Purpose |
|---|---|---|
| Allowed locations | Deny | Single region: `centralus` |
| Allowed VM SKUs | Deny | Prevent accidental use of expensive SKUs |
| Require tag `env=lab` | Audit | Visibility; not blocking |
| Deny public IPs (custom) | Deny | Block public IPs except for the Tailscale VM |

---

## Monitoring

### Workspace

A single Log Analytics workspace is the central sink for all diagnostics. The free tier (first 5 GB/month of ingestion, 30 days retention) is sufficient for my lab.

### Diagnostic sources

| Source | Data | Table(s) |
|---|---|---|
| Subscription Activity Log | Resources lifecycle (create/update/delete), policy evaluations, security alerts, service health, resource health | `AzureActivity` |
| Key Vault | `AuditEvent` — all secret/key access and operations | `AzureDiagnostics` |
| NSG (`nsg-tailscale`) | `NetworkSecurityGroupEvent`, `NetworkSecurityGroupRuleCounter` | `AzureDiagnostics` |
| Tailscale VM | `auth`/`authpriv` syslog (Info), `daemon`/`kern`/`syslog` (Warning) | `Syslog` |
| Tailscale VM | CPU %, available memory MB, disk % free, network bytes in/out (every min) | `Perf` |
| Tailscale VM | Heartbeat (every min) | `Heartbeat` |

### Alerting

| Resource | Purpose |
|---|---|
| `ag-lab-alerts` (Action Group) | Email receiver for all alert rules |

---

## Security

| Resource | Purpose |
|---|---|
| Key Vault | SP credentials, secrets |
| `sp-lab-automation` | Non-interactive deployments |

Key Vault `AuditEvent` diagnostic logs are forwarded to the Log Analytics workspace. No Defender for Cloud plans enabled — default free tier only.

---

## Infrastructure as Code

Bicep is the source of truth for all ARM resources. Bash (or Powershell) is reserved for what Bicep can't manage (Entra ID service principal, CLI prerequisites).

### Layout

```
bicep/
├── subscription.bicep   ← sub scope: resource groups
├── policy.bicep         ← sub scope: custom defs + assignments
├── network.bicep        ← rg-lab-network: vnet-lab + snet-gateway
├── monitoring.bicep     ← rg-lab-monitoring: Log Analytics workspace + action group
├── activitylog.bicep    ← sub scope: subscription Activity Log → workspace
├── security.bicep       ← rg-lab-security: Key Vault + RBAC + ACL + KV diagnostics
└── tailscale.bicep      ← rg-lab-network: Tailscale VM + NIC + NSG + PIP + AMA + DCR (on-demand)

scripts/
└── bootstrap.sh         ← one-time: prerequisites, service principal, providers

tailscale/
├── cloud-init.yaml          ← VM configuration (loaded by tailscale.bicep)
├── create-tailscale.sh      ← runs the Bicep deployment and approves the tailnet route
└── destroy-tailscale.sh     ← destroy the VM and its dependencies
```

### Deployment order

```bash
# One-time
make bootstrap

# Deploy the landing zone (idempotent)
make build                  # all Bicep layers in order

# Or deploy individual layers (idempotent)
make deploy-subscription    # bicep/subscription.bicep — resource groups
make deploy-policy          # bicep/policy.bicep — definitions + assignments
make deploy-network         # bicep/network.bicep — VNet + subnets
make deploy-monitoring      # bicep/monitoring.bicep — Log Analytics workspace + action group
make deploy-activitylog     # bicep/activitylog.bicep — subscription Activity Log → workspace
make deploy-security        # bicep/security.bicep — Key Vault + RBAC + ACL

# Preview before applying (one per layer)
make whatif-subscription
make whatif-policy
make whatif-network
make whatif-monitoring
make whatif-activitylog
make whatif-security
```

**Windows:** replace `make <target>` with `.\deploy.ps1 <target>`.

### On-demand resources

To keep costs down (VM, public IP, disk), the Tailscale VM is created on-demand:

```bash
make deploy-tailscale    # bicep/tailscale.bicep + tailnet route approval
make whatif-tailscale    # dry run
make destroy-tailscale   # destroy VM and remove from tailnet
```

The deployment installs the Azure Monitor Agent and creates a Data Collection Rule.
