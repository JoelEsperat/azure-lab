# AWS Homelab Landing Zone — Learning Plan

A parallel to the Azure lab in this repo: single account, single region (`us-east-1`),
budget ≤ $10/month. CloudFormation is the source of truth for all AWS resources (the
Bicep equivalent). Bash scripts handle what CloudFormation can't (IAM users, Tailscale
API calls, CLI prerequisites).

---

## Azure → AWS Concept Map

Before touching any tooling, internalize these mappings. The mental model shift is the
hardest part.

| Azure concept | AWS equivalent | Key difference |
|---|---|---|
| Subscription | AWS Account | In Azure, a subscription is a billing+RBAC boundary inside a tenant. In AWS, the account *is* the boundary — isolation between environments usually means separate accounts. |
| Resource Group | CloudFormation Stack + Tags | Azure RGs are deployment *and* organizational scopes. AWS has neither: stacks are deployment units, Resource Groups are just tag-based views. Tags are the primary org tool. |
| Entra ID (tenant) | AWS IAM (account-scoped) | Entra ID is a separate directory service. IAM lives inside the account — users, roles, and policies are all account-local by default. |
| Managed Identity | IAM Role + Instance Profile | Same idea (no long-lived credentials on the VM), but wiring is explicit: you create a role, attach a policy, then attach an instance profile to the EC2. |
| Azure Policy | AWS Config Rules + SCPs | Azure Policy is account-wide and can block deploys in real time. Config Rules are *detective* (find violations after the fact). Service Control Policies (SCPs) are *preventive* but require AWS Organizations — overkill for a single-account lab. |
| VNet | VPC | Functionally identical, but VPC is more explicit: you must create an Internet Gateway, attach it to the VPC, and add a route table entry `0.0.0.0/0 → igw-xxx`. Azure does this implicitly. |
| Subnet (NSG) | Subnet + Security Group | Security Groups (SGs) are stateful and attached to ENIs (network interfaces), not subnets. NACLs are stateless subnet-level rules — equivalent to Azure's subnet-level NSG, rarely needed. Use SGs. |
| Service Endpoint | VPC Gateway/Interface Endpoint | S3 and DynamoDB: free Gateway endpoints. Everything else (Secrets Manager, etc.): Interface endpoints at $0.01/hour/AZ — expensive for a lab. Skip and use public endpoints with IP restrictions instead. |
| Key Vault | AWS Secrets Manager | Secrets Manager charges $0.40/secret/month. For a lab with one secret, use SSM Parameter Store SecureString instead — free for standard parameters, uses KMS under the hood. |
| Log Analytics Workspace | CloudWatch Logs | CloudWatch Logs is CloudWatch's log storage. First 5 GB ingestion and 5 GB storage are free — a homelab never exceeds that. |
| Action Group | SNS Topic | SNS (Simple Notification Service) sends emails, SMS, HTTP, Lambda, etc. First 1,000 email deliveries/month are free. |
| Activity Log | CloudTrail | CloudTrail records every API call to every AWS service. The first management-event trail is free. Direct equivalent of the Azure Activity Log. |
| Diagnostic Settings | CloudWatch Logs subscription / metric filters | Each AWS service publishes logs to CloudWatch in its own way; there's no single "send everything here" toggle like Diagnostic Settings. |
| ARM / Bicep | CloudFormation (YAML) | Both are declarative, cloud-native, and free. CloudFormation uses Stacks instead of deployments. No modules by default — use nested stacks or include files if needed. |
| GitHub Actions OIDC | GitHub Actions OIDC (same) | The pattern is identical: create an IAM OIDC provider, create an IAM role with a trust policy scoped to the repo, assume that role in the workflow. No stored credentials. |

---

## Architecture

```
AWS Account (us-east-1)
│
├── VPC: vpc-lab  10.0.0.0/16
│   ├── subnet-gateway   10.0.0.0/24   public   (Tailscale router)
│   └── subnet-workloads 10.0.1.0/24   private  (future workloads)
│
├── CloudTrail → CloudWatch Logs (audit trail)
├── CloudWatch Log Group + SNS Topic (monitoring + email alerts)
├── SSM Parameter Store (ts-authkey secret)
├── S3 bucket  s3://lab-backups-<account-id-prefix>
│   └── /backup prefix  (firewall: home IP + VPC endpoint)
│
└── EC2 t4g.nano  (on-demand, Tailscale subnet router)
    ├── IAM Instance Profile → SSM Parameter Store read
    ├── Security Group: outbound-only from internet; SSH from home IP only
    ├── Public IPv4 (needs internet to reach Tailscale coordination server)
    ├── Ubuntu 24.04 ARM64 + cloud-init (fetches ts-authkey, runs tailscale up)
    └── CloudWatch Agent → syslog + perf metrics
```

Tags applied everywhere: `env=lab`

---

## Deployment Layers

Order matters — later layers reference outputs from earlier ones. Run them in sequence.

```
1. network.yaml          → VPC, subnets, IGW, route tables, S3 Gateway endpoint
2. config.yaml           → AWS Config recorder + Config rules (governance)
3. monitoring.yaml       → CloudWatch Log Group, SNS topic, email subscription
4. cloudtrail.yaml       → CloudTrail trail → CloudWatch Logs (must follow monitoring)
5. security.yaml         → SSM Parameter Store placeholder, IAM roles
6. storage.yaml          → S3 bucket with bucket policy
7. tailscale.yaml        → EC2, SG, IAM instance profile, CloudWatch Agent (on-demand)
```

`make build` will run layers 1–6. Layer 7 is on-demand (`make deploy-tailscale` /
`make destroy-tailscale`), matching the Azure pattern.

---

## Layer Details

### 1. `network.yaml`

**Equivalent:** `network.bicep`

Resources:
- `AWS::EC2::VPC` — `10.0.0.0/16`, DNS hostnames enabled
- `AWS::EC2::Subnet` × 2 — gateway (public) and workloads (private)
- `AWS::EC2::InternetGateway` + `AWS::EC2::VPCGatewayAttachment`
- `AWS::EC2::RouteTable` + route `0.0.0.0/0 → IGW` (gateway subnet only)
- `AWS::EC2::SubnetRouteTableAssociation` × 1 (gateway subnet)
- `AWS::EC2::VPCEndpoint` (type: Gateway) for S3 — free, routes S3 traffic inside AWS

**Key AWS-ism:** The private workloads subnet has no route to the internet and no NAT
gateway (too expensive — $32/month). Workloads that need internet access must be in
the gateway subnet or use SSM Session Manager.

### 2. `config.yaml`

**Equivalent:** `policy.bicep`

AWS Config is *detective* (finds violations), not *preventive* (blocks them). For a
single-account lab without AWS Organizations, this is the closest you get to Azure
Policy. Add SCPs later if you graduate to multi-account with AWS Organizations.

Resources:
- `AWS::Config::ConfigurationRecorder` — records all supported resource types
- `AWS::Config::DeliveryChannel` — sends snapshots to an S3 bucket
- `AWS::Config::ConfigRule` × 3:
  - `required-tags` — flags resources missing `env=lab` (audit only, like Azure's DoNotEnforce)
  - `restricted-ssh` — flags Security Groups with SSH open to `0.0.0.0/0`
  - `s3-bucket-public-read-prohibited` — flags S3 buckets with public ACLs

**Cost note:** Config charges $0.003 per configuration item recorded and $0.001 per
rule evaluation. For a small lab (~50–100 resources, 3 rules), expect ~$0.50–0.75/month.

### 3. `monitoring.yaml`

**Equivalent:** `monitoring.bicep`

Resources:
- `AWS::Logs::LogGroup` — `/lab/cloudtrail` (30-day retention)
- `AWS::Logs::LogGroup` — `/lab/ec2/tailscale` (30-day retention)
- `AWS::SNS::Topic` — `lab-alerts`
- `AWS::SNS::Subscription` — email, your address

**Key AWS-ism:** SNS subscriptions require the email address to click a confirmation link
before it activates. There is no equivalent of Azure's "useCommonAlertSchema" — each
CloudWatch alarm formats its own notification.

### 4. `cloudtrail.yaml`

**Equivalent:** `activitylog.bicep`

Resources:
- `AWS::CloudTrail::Trail` — management events, global services, write+read
  - Logs to CloudWatch Logs log group `/lab/cloudtrail`
  - Also delivers to an S3 bucket (required by CloudTrail, even if you don't use it)
- `AWS::S3::Bucket` — `lab-cloudtrail-<account-prefix>` (CloudTrail delivery target)
- `AWS::S3::BucketPolicy` — allows CloudTrail service to write

**Key AWS-ism:** CloudTrail *always* requires an S3 bucket for delivery — there's no
"stream only to CloudWatch Logs" mode. The bucket just accumulates compressed JSON logs;
you can set a 7-day lifecycle rule to minimize storage cost (~$0.00 at lab volumes).

### 5. `security.yaml`

**Equivalent:** `security.bicep`

Using SSM Parameter Store instead of Secrets Manager to stay under the $10 budget.

Resources:
- `AWS::SSM::Parameter` — `/lab/tailscale/authkey` placeholder (value populated manually
  before deploying the Tailscale VM, same pattern as `az keyvault secret set`)
- `AWS::IAM::Role` — `lab-tailscale-ec2-role`
  - Trust policy: `ec2.amazonaws.com` (instance profile)
  - Inline policy: `ssm:GetParameter` on `/lab/tailscale/*`
  - Managed policy: `CloudWatchAgentServerPolicy` (for CloudWatch Agent)
- `AWS::IAM::InstanceProfile` — wraps the role for EC2 attachment

**Key AWS-ism:** IAM roles for EC2 require an *instance profile* wrapper — a small
indirection that Azure Managed Identities don't have. CloudFormation creates both
together. The role trust policy is the equivalent of the Entra ID managed identity
binding.

**SSM vs Secrets Manager:**
| | SSM Parameter Store (SecureString) | Secrets Manager |
|---|---|---|
| Cost | Free (standard tier) | $0.40/secret/month |
| Rotation | Manual | Automatic (Lambda-based) |
| Versioning | Yes | Yes |
| API | `ssm:GetParameter` | `secretsmanager:GetSecretValue` |
| For this lab | Sufficient | Overkill |

### 6. `storage.yaml`

**Equivalent:** `storage.bicep`

Resources:
- `AWS::S3::Bucket` — `lab-backup-<8-char account prefix>`
  - Versioning: enabled
  - Encryption: SSE-S3 (no extra cost; SSE-KMS would add KMS costs)
  - Public access: fully blocked
- `AWS::S3::BucketPolicy` — deny everything except:
  - Home IP via `aws:SourceIp` condition
  - VPC via `aws:SourceVpc` condition (uses the free S3 Gateway endpoint)

**Key AWS-ism:** S3 has no concept of "subnets" in bucket policies — you allow/deny by
VPC ID or by IP. The S3 Gateway endpoint routes traffic from the VPC to S3 privately
without leaving AWS, analogous to Azure's storage service endpoint.

### 7. `tailscale.yaml` (on-demand)

**Equivalent:** `tailscale.bicep`

Resources:
- `AWS::EC2::SecurityGroup` — `sg-tailscale`
  - Inbound: SSH (port 22) from home IP only
  - Outbound: all (Tailscale needs UDP 41641 outbound to coordination server)
- `AWS::EC2::Instance` — `t4g.nano`, Ubuntu 24.04 ARM64 (ap-southeast-1 AMI varies by region — look up latest with SSM `/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp2/ami-id`)
  - `IamInstanceProfile` → `lab-tailscale-ec2-role`
  - `UserData` → cloud-init (fetch SSM param, run `tailscale up`)
  - `NetworkInterfaces` → subnet-gateway, `AssociatePublicIpAddress: true`
- `AWS::CloudWatch::Dashboard` — simple CPU/network panel (optional, free)

The create script (bash):
1. Stores fresh ts-authkey in SSM Parameter Store
2. Deploys the CloudFormation stack
3. Polls Tailscale API until device appears, then approves `10.0.0.0/16` route

The destroy script:
1. Removes device from tailnet (Tailscale API)
2. Deletes the CloudFormation stack

---

## Tooling

### IaC: CloudFormation YAML

CloudFormation is the direct Bicep equivalent:

| Bicep | CloudFormation |
|---|---|
| `targetScope = 'subscription'` | Not needed (single account, no concept of subscription scope) |
| `resource foo '...@version' = { ... }` | `Resources: Foo: Type: AWS::... Properties: ...` |
| `param x string` | `Parameters: X: Type: String` |
| `output y string = ...` | `Outputs: Y: Value: ...` |
| `existing` resource reference | `!ImportValue stack-output-name` (cross-stack) or `!Ref` (same stack) |
| `subscription().subscriptionId` | `!Sub '${AWS::AccountId}'` |
| `make deploy-<layer>` | `aws cloudformation deploy --stack-name lab-network --template-file network.yaml ...` |

### CLI: AWS CLI v2

```bash
# Install
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Configure (uses ~/.aws/credentials or environment variables)
aws configure
# or: use IAM Identity Center (SSO) for MFA-protected access

# Equivalent of `az account show`
aws sts get-caller-identity
```

### Scripts: Bash (Linux/macOS) + PowerShell (Windows)

Same dual-script pattern as the Azure lab. The Makefile will wrap the same targets:
`bootstrap`, `build`, `deploy-<layer>`, `whatif-<layer>`, `deploy-tailscale`,
`destroy-tailscale`.

`whatif` equivalent in CloudFormation:
```bash
aws cloudformation deploy \
  --stack-name lab-network \
  --template-file cloudformation/network.yaml \
  --no-execute-changeset   # creates a changeset but does NOT apply it
```

---

## Repository Layout (proposed)

```
aws-lab/                         ← new sibling repo (or subfolder)
├── CLAUDE.md
├── Makefile
├── deploy.ps1
├── .env.sample
├── cloudformation/
│   ├── network.yaml
│   ├── config.yaml
│   ├── monitoring.yaml
│   ├── cloudtrail.yaml
│   ├── security.yaml
│   ├── storage.yaml
│   └── tailscale.yaml
├── scripts/
│   ├── bootstrap.sh
│   └── bootstrap.ps1
└── tailscale/
    ├── cloud-init.yaml          ← fetches SSM param instead of Key Vault
    ├── create-tailscale.sh
    ├── destroy-tailscale.sh
    ├── create-tailscale.ps1
    └── destroy-tailscale.ps1
```

---

## Cost Breakdown

All prices are us-east-1, May 2026. **Costs marked † are always-on; ‡ are only when the
Tailscale VM is running.**

### Always-on baseline

| Resource | Price | Monthly |
|---|---|---|
| VPC, subnets, IGW, route tables, SGs | Free | $0.00 |
| S3 Gateway VPC Endpoint (S3 routing) | Free | $0.00 |
| CloudTrail (first trail, mgmt events) | Free | $0.00 |
| CloudWatch Logs (ingestion + storage ≤ 5 GB) | Free tier | $0.00 |
| SNS email notifications (≤ 1,000/month) | Free tier | $0.00 |
| SSM Parameter Store (standard, ≤ 10,000) | Free | $0.00 |
| S3 backup bucket (~0.1 GB data) | $0.023/GB | ~$0.01 |
| S3 CloudTrail bucket (compressed logs) | $0.023/GB | ~$0.01 |
| AWS Config recorder + 3 rules (~100 items) | $0.003/item + $0.001/eval | ~$0.55 |
| **Baseline total** | | **~$0.57/month** |

### Tailscale VM (when running)

| Resource | Price | Monthly (24/7) |
|---|---|---|
| EC2 t4g.nano (2 vCPU burst, 512 MB, ARM64) | $0.0042/hr | $3.02 |
| EBS gp3 8 GB root volume | $0.08/GB/month | $0.64 |
| Public IPv4 address (required for outbound) | $0.005/hr | $3.65 |
| Data transfer out (first 100 GB free) | Free tier | $0.00 |
| CloudWatch Agent (metrics/logs ingestion) | Free tier (under 5 GB) | $0.00 |
| **VM subtotal** | | **$7.31/month** |

### Grand total

| Scenario | Monthly cost |
|---|---|
| VM off (baseline only) | **~$0.57** |
| VM on 24/7 | **~$7.88** |
| VM on 50% of the month | **~$4.23** |

Comfortably under the $10/month budget in all scenarios.

### What NOT to add (cost killers for a lab)

| Resource | Monthly cost | Avoid because |
|---|---|---|
| NAT Gateway | ~$32 | Needed for private subnet internet access — use SSM Session Manager or public subnet instead |
| Secrets Manager (1 secret) | $0.40 | Use SSM Parameter Store SecureString (free) |
| Interface VPC Endpoint (per AZ) | $7.20 | Use public endpoints with IP restrictions instead |
| VPC Flow Logs → CloudWatch | ~$0.50+ | Useful but not essential for a basic lab |
| AWS WAF | ~$5+ | Overkill for a homelab |
| GuardDuty | ~$3+ | Nice to have, but pushes budget to the limit |

---

## Prerequisites & One-Time Setup

### 1. AWS account

Create a free AWS account at aws.amazon.com. Use a real email — you'll need it for
billing alerts and SNS subscription confirmations.

Enable MFA on the root account immediately. Then create an IAM user (or use IAM
Identity Center) for day-to-day work — never use root credentials in scripts.

### 2. Set a billing alert

Go to AWS Billing → Budgets → Create budget → "Zero spend budget" (alerts at $0.01)
and a second at $10/month. Do this before deploying anything.

### 3. Install AWS CLI v2

```bash
# Linux x86_64
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install && aws --version
```

### 4. Configure credentials

```bash
aws configure
# AWS Access Key ID: <your key>
# AWS Secret Access Key: <your secret>
# Default region: us-east-1
# Default output format: json
```

Or use IAM Identity Center (SSO) with `aws configure sso` for MFA-gated access — the
more secure option.

### 5. Bootstrap S3 bucket for CloudFormation

CloudFormation needs an S3 bucket to upload large templates. The bootstrap script
creates this once:

```bash
aws s3 mb s3://lab-cfn-$(aws sts get-caller-identity --query Account --output text | cut -c1-8) --region us-east-1
```

### 6. GitHub Actions OIDC (optional)

Same pattern as the Azure lab, just different API calls:

1. Create an IAM OIDC provider for `token.actions.githubusercontent.com`
2. Create an IAM role with a trust policy scoped to your repo + branch
3. Attach `CloudFormationFullAccess` + resource-specific permissions
4. Add `AWS_ACCOUNT_ID`, `AWS_ROLE_ARN` as GitHub repository secrets

---

## Learning Path

Work through these in order. Each builds on the previous.

### Stage 1: Networking (weeks 1–2)
- Deploy `network.yaml` manually via AWS Console first, then delete and redo with CLI
- Understand VPC CIDR, subnets, availability zones, IGW, route tables
- Read: [AWS VPC User Guide](https://docs.aws.amazon.com/vpc/latest/userguide/)
- Lab: add a second subnet in a second AZ (multi-AZ is the AWS default pattern)

### Stage 2: Compute + IAM (weeks 3–4)
- Deploy the Tailscale VM manually in the Console to understand AMIs, key pairs, SGs
- Then redo with `tailscale.yaml` + CloudFormation
- Understand IAM roles, policies, instance profiles, the least-privilege principle
- Read: [IAM User Guide — Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
- Lab: add an IAM policy that denies terminating EC2 instances without a specific tag

### Stage 3: Storage + Secrets (week 5)
- Deploy `storage.yaml` — explore S3 bucket policies, VPC endpoints, presigned URLs
- Use SSM Parameter Store to store and retrieve secrets from the VM
- Read: [S3 Security Best Practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)

### Stage 4: Observability (week 6)
- Deploy `monitoring.yaml` + `cloudtrail.yaml`
- Write a CloudWatch metric filter on CloudTrail logs to alert on console logins without MFA
- Create a CloudWatch alarm for EC2 CPU > 80% → SNS → email
- Read: [CloudWatch Alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html)

### Stage 5: Governance (week 7)
- Deploy `config.yaml` — watch Config detect the "no MFA" finding
- Add a Config rule for `ec2-instance-detailed-monitoring-enabled`
- Read: [AWS Config Managed Rules](https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html)
- Stretch goal: explore AWS Organizations + Service Control Policies for preventive controls

### Stage 6: IaC patterns (week 8)
- Refactor the stacks to use CloudFormation cross-stack references (`Outputs` + `!ImportValue`)
- Add a `make whatif-<layer>` target using `--no-execute-changeset`
- Explore CloudFormation drift detection (`aws cloudformation detect-stack-drift`)

---

## Key Differences to Keep in Mind

1. **IAM is granular by default.** Every permission must be explicitly granted. Azure's
   built-in roles are coarse; AWS inline/managed policies let you scope to individual
   API actions and resources.

2. **There is no "subscription scope."** CloudFormation stacks are region-scoped.
   Account-level governance (SCPs, CloudTrail organization trails) requires AWS
   Organizations.

3. **AZs matter from day one.** Azure often hides availability zones. AWS forces you to
   pick a subnet (= AZ) for every resource. For a lab, one AZ is fine; in production,
   always span at least two.

4. **Public IPv4 now costs money.** Since February 2024, AWS charges $0.005/hour for
   every public IPv4, whether attached to a running instance or not. IPv6 is free but
   requires IPv6-capable services end-to-end.

5. **No "resource groups" as a deployment scope.** If you want to delete everything in a
   logical group, use CloudFormation stacks — `aws cloudformation delete-stack` removes
   all resources the stack created. Tags alone won't help you delete resources.

6. **CloudTrail is retroactive, not real-time.** Logs appear in CloudWatch Logs within
   ~5 minutes, not instantly. For real-time alerting on API calls, use CloudTrail +
   CloudWatch metric filters + CloudWatch alarms.
