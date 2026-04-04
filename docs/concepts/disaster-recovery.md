# Azure Disaster Recovery Concepts

## Key DR Metrics

| Metric | Definition | Example |
|--------|------------|---------|
| **RPO** (Recovery Point Objective) | Maximum acceptable data loss in time | 15 minutes: "we can lose 15 min of data" |
| **RTO** (Recovery Time Objective) | Maximum acceptable downtime | 1 hour: "must be back online within 1 hour" |

Lower RPO/RTO = better DR but higher cost.

---

## DR Strategy Tiers

```
┌─────────────────────────────────────────────────────────┐
│  TIER 1: Hot Standby (Active-Active)                    │
│  RPO: ~0s, RTO: ~0s                                     │
│  Cost: Highest (double infrastructure running)          │
│  Method: Active-Active with Traffic Manager             │
├─────────────────────────────────────────────────────────┤
│  TIER 2: Warm Standby (Active-Passive, pre-provisioned) │
│  RPO: minutes, RTO: minutes                             │
│  Cost: High (standby infra pre-deployed)                │
│  Method: Traffic Manager + Azure Site Recovery          │
├─────────────────────────────────────────────────────────┤
│  TIER 3: Cold Standby (Backup & Restore)                │
│  RPO: hours, RTO: hours                                 │
│  Cost: Low (just backups, no running infra)             │
│  Method: ARM templates + Azure Backup                   │
└─────────────────────────────────────────────────────────┘
```

---

## Azure Dual-Region DR Architecture (East US → East US 2)

```
                    ┌─────────────────────────────────────────┐
                    │         Azure Traffic Manager           │
                    │    (Priority Routing, TTL: 30s)         │
                    │    cloudinn.trafficmanager.net          │
                    └──────────┬──────────────────┬───────────┘
                               │                  │
                    Priority 1 │         Priority 2│
                    (Active)   │          (Standby)│
                               ▼                  ▼
              ┌────────────────────┐   ┌──────────────────────┐
              │   East US          │   │   East US 2           │
              │   (Primary)        │   │   (DR Standby)        │
              │                    │   │                       │
              │  ┌──────────────┐  │   │  ┌────────────────┐  │
              │  │  Web Tier    │  │   │  │  Web Tier      │  │
              │  │  (VMs/LB)    │  │   │  │  (VMs/LB)      │  │
              │  └──────┬───────┘  │   │  └────────┬───────┘  │
              │         │          │   │           │          │
              │  ┌──────▼───────┐  │   │  ┌────────▼───────┐  │
              │  │  App Tier    │  │   │  │  App Tier      │  │
              │  │  (VMs)       │  │   │  │  (VMs)         │  │
              │  └──────────────┘  │   │  └────────────────┘  │
              │                    │   │                       │
              │  Storage (LRS)     │   │  Storage (LRS)        │
              │  Azure DNS         │   │                       │
              │  internal.azure    │   │                       │
              └────────────────────┘   └───────────────────────┘
```

---

## Failover Sequence

### Normal Operation
1. Users hit `cloudinn.trafficmanager.net`
2. Traffic Manager returns East US endpoint (Priority 1, healthy)
3. Users connect to East US Load Balancer

### During Failover
1. East US endpoint goes unhealthy (outage detected)
2. Traffic Manager probes fail (after ~90s detection window)
3. Traffic Manager returns East US 2 DR endpoint (Priority 2)
4. Users connect to East US 2 instead
5. DNS TTL (30s) ensures quick propagation

### After Recovery
1. East US endpoint becomes healthy again
2. Traffic Manager detects health restored
3. Automatically fails back to East US (Priority 1)
4. East US 2 remains on standby

---

## Azure Site Recovery (ASR)

For **VM-level replication**, Azure Site Recovery continuously replicates on-prem or cross-region VMs.

| Feature | Details |
|---------|---------|
| RPO | As low as 30 seconds for Azure-to-Azure |
| Supported sources | Azure VMs, VMware, Hyper-V, Physical servers |
| Target | Azure regions |
| Cost model | Per protected instance/month |

---

## Disaster Recovery Testing

> **Critical:** DR that is never tested is DR that doesn't work.

```bash
# Test failover checklist:
1. Notify stakeholders (schedule maintenance window)
2. Create recovery point (snapshot)
3. Initiate test failover (doesn't affect production)
4. Validate:
   - Application accessible at Azure DR endpoint
   - Data is consistent
   - Performance acceptable
5. Clean up test failover resources
6. Document results and RTO/RPO achieved
```

---

## Key CLI Commands

### Linux / macOS (Azure CLI)

```bash
# Create recovery vault (for ASR/Backup)
az backup vault create \
  --resource-group rg-cloudinn-primary-prod \
  --name vault-cloudinn-dr \
  --location eastus

# Simulate failover: Disable East US primary endpoint
az network traffic-manager endpoint update \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-priority \
  --name endpoint-primary \
  --type azureEndpoints \
  --endpoint-status Disabled \
  --output none

# Check that East US 2 DR endpoint is now active
az network traffic-manager endpoint show \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-priority \
  --name endpoint-dr \
  --type azureEndpoints \
  --query "endpointMonitorStatus"

# Verify DNS now returns East US 2 IP
nslookup cloudinn.trafficmanager.net

# Re-enable East US endpoint (simulate recovery)
az network traffic-manager endpoint update \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-priority \
  --name endpoint-primary \
  --type azureEndpoints \
  --endpoint-status Enabled \
  --output none
```

### Windows (PowerShell)

```powershell
# Create backup vault
New-AzRecoveryServicesVault `
  -Name "vault-cloudinn-dr" `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -Location "eastus"

# Simulate failover: Disable East US primary endpoint
$ep = Get-AzTrafficManagerEndpoint `
  -Name "endpoint-primary" `
  -ProfileName "tm-cloudinn-priority" `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -Type AzureEndpoints
$ep.EndpointStatus = "Disabled"
Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep

# Verify DNS resolves to East US 2
Resolve-DnsName -Name "cloudinn.trafficmanager.net"

# Check East US 2 DR endpoint health
Get-AzTrafficManagerEndpoint `
  -Name "endpoint-dr" `
  -ProfileName "tm-cloudinn-priority" `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -Type AzureEndpoints | Select-Object Name, EndpointMonitorStatus

# Re-enable after testing
$ep.EndpointStatus = "Enabled"
Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep
```
