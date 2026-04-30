# Azure Lab

This document describes the architecture of my Azure lab. The goal is to build a minimal Azure landing zone, using best pratices, for a low budget, to support a few Azure workloads. 

---

## Design Principles

- **Budget** under $10/month
- **Single subscription** and **single region** (East US)
- **Governance** — policies enforce allowed SKU, location, and tagging
- **Private connectivity** - the Azure VNet is an extension of my home network - no internet exposure
- **Zero-trust hybrid connectivity** — the Azure VNet is connected to my Tailscale tailnet, providing zero trust networking - the only component with internet connectivity is the Tailscale subnet router VM - to keep the cost low the subnet router VM and the public IPv4 are provisioned only when needed
- **Infrastructure as code**

---

## Subscription Layout

```
Subscription: azure-lab
│
├── Governance (subscription-scoped)
│   ├── Policy: Allowed locations → eastus
│   ├── Policy: Allowed VM SKUs  → B1s, B1ms, B2s
│   ├── Policy: Require tag      → env=lab (audit)
│   └── Policy: Deny public IPs  → enforce
│
├── rg-lab-monitoring   ← Action groups, alert rules, budgets
├── rg-lab-network   ← VNet, NSGs, subnets, Tailscale subnet router
├── rg-lab-security     ← Key Vault, managed identities
└── rg-lab-workloads    ← Workloads (compute and storage)
```

---

## Network Topology

```
vnet-lab  10.10.0.0/16   (rg-lab-network, eastus)
│
├── snet-gateway    10.10.0.0/24   hybrid connectivity (Tailscale VM)
└── snet-pes        10.10.1.0/24   private endpoints
└── snet-workloads  10.10.2.0/24   workloads
```

The Tailscale subnet router is the only ingress path into the VNet. It is much cheaper than a VPN Gateway and sufficient for my homelab, and it provides zero trust networking. 

---

## Hybrid Connectivity (Tailscale)

Connectivity with my home network and devices is provided through Tailscale using a lightweight Ubuntu VM that joins the tailnet and advertises the entire Azure subnet `10.10.0.0/16`

```
Home devices ──── Tailscale tailnet ──── vm-ts-subnet-router (Azure, snet-gateway)
                                               │
                                         vnet-lab 10.10.0.0/16
                                               │
                                         Azure workloads
```

| Property | Value |
|---|---|
| VM name | `vm-ts-subnet-router` |
| Resource group | `rg-lab-network` |
| Size | `Standard_B1s` |
| Image | Ubuntu 24.04 |
| Subnet | `snet-gateway` (10.10.0.0/24) |
| Public IP | Standard Static (required for internet connectivity) |
| NSG | Empty (no inbound rules) |
| IP forwarding | Enabled via cloud-init (`net.ipv4.ip_forward=1`) |
| Tailscale | Enabled via cloud-init - advertises `10.10.0.0/16` on my tailnet |

Deployed and destroyed via `ts-subnet-router/create-ts-subnet-router.sh` / `ts-subnet-router/destroy-ts-subnet-router.sh`.

---

## Policies

Scope: subscription scope

| Policy | Effect | Purpose |
|---|---|---|
| Allowed locations | Deny | Single region: `eastus` |
| Allowed VM SKUs | Deny | Prevent accidental use of expensive SKUs |
| Require tag `env=lab` | Audit | Visibility; not blocking |
| Deny public IPs (custom) | Deny | Block public IPs except for the Tailscale VM |

---

## Monitoring

| Resource | Purpose |
|---|---|
| `ag-lab-alerts` (Action Group) | Email for all alert rules |

---

## Security

| Resource | Purpose |
|---|---|
| Key Vault | Store SP credentials, secrets |
| `sp-lab-automation` | Non-interactive deployments |

No Defender for Cloud plans enabled — default free tier only.

---

## Scripts

```
1. bootstrap.sh (one-time: prerequisites, service principal, resource providers)
2. build-lab.sh (baseline: RGs, policies, VNet, action group) - idempotent
```

To keep the costs down, the Tailscale VM is created on-demand: `ts-subnet-router/create-ts-subnet-router.sh` / `ts-subnet-router/destroy-ts-subnet-router.sh`.

