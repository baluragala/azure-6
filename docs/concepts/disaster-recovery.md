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

## Cross-Cloud DR Architecture (AWS → Azure)

```
                    ┌─────────────────────────────────────────┐
                    │         Azure Traffic Manager           │
                    │    (Priority Routing, TTL: 30s)         │
                    │    cloudinn.trafficmanager.net          │
                    └──────────┬──────────────────┬───────────┘
                               │                  │
                    Priority 1 │         Priority 2│
                               ▼                  ▼
              ┌────────────────────┐   ┌──────────────────────┐
              │   AWS Primary      │   │   Azure DR           │
              │   us-east-1        │   │   East US            │
              │                    │   │                      │
              │  ┌──────────────┐  │   │  ┌────────────────┐ │
              │  │  Web Tier    │  │   │  │  Web Tier      │ │
              │  │  (EC2/ALB)   │  │   │  │  (VMs/LB)      │ │
              │  └──────┬───────┘  │   │  └────────┬───────┘ │
              │         │          │   │           │         │
              │  ┌──────▼───────┐  │   │  ┌────────▼───────┐ │
              │  │  App Tier    │  │   │  │  App Tier      │ │
              │  │  (EC2)       │  │   │  │  (VMs)         │ │
              │  └──────┬───────┘  │   │  └────────┬───────┘ │
              │         │          │   │           │         │
              │  ┌──────▼───────┐  │   │  ┌────────▼───────┐ │
              │  │  DB Tier     │  │   │  │  DB Tier       │ │
              │  │  (RDS)       │◄─┼───┼──►  (Azure SQL)   │ │
              │  └──────────────┘  │   │  └────────────────┘ │
              │                    │   │                      │
              │  Route53           │   │  Azure DNS           │
              │  internal.corp     │   │  internal.azure      │
              └────────────────────┘   └──────────────────────┘
                                              │
                                   ┌──────────▼──────────┐
                                   │  ARM Templates       │
                                   │  (Auto-deploy DR     │
                                   │   on failover)       │
                                   └─────────────────────┘
```

---

## Failover Sequence

### Normal Operation
1. Users hit `cloudinn-global.trafficmanager.net`
2. Traffic Manager returns AWS endpoint (Priority 1, healthy)
3. Users connect to AWS directly

### During Failover
1. AWS endpoint goes unhealthy (outage detected)
2. Traffic Manager probes fail (after ~90s detection window)
3. Traffic Manager returns Azure DR endpoint (Priority 2)
4. Users connect to Azure DR instead
5. DNS TTL (30s) ensures quick propagation

### After Recovery
1. AWS endpoint becomes healthy again
2. Traffic Manager detects health restored
3. Automatically fails back to AWS (Priority 1)
4. Azure DR remains on standby

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
  --resource-group rg-dr \
  --name vault-cloudinn-dr \
  --location eastus

# Simulate failover: Disable AWS endpoint in Traffic Manager
az network traffic-manager endpoint update \
  --resource-group rg-tm \
  --profile-name tm-cloudinn \
  --name endpoint-aws-primary \
  --type externalEndpoints \
  --endpoint-status Disabled

# Check that Azure DR endpoint is now active
az network traffic-manager endpoint show \
  --resource-group rg-tm \
  --profile-name tm-cloudinn \
  --name endpoint-azure-dr \
  --type azureEndpoints \
  --query "properties.endpointMonitorStatus"

# Verify DNS now returns Azure IP
nslookup cloudinn-global.trafficmanager.net

# Re-enable AWS endpoint (simulate recovery)
az network traffic-manager endpoint update \
  --resource-group rg-tm \
  --profile-name tm-cloudinn \
  --name endpoint-aws-primary \
  --type externalEndpoints \
  --endpoint-status Enabled
```

### Windows (PowerShell)

```powershell
# Create backup vault
New-AzRecoveryServicesVault `
  -Name "vault-cloudinn-dr" `
  -ResourceGroupName "rg-dr" `
  -Location "eastus"

# Simulate failover
$ep = Get-AzTrafficManagerEndpoint `
  -Name "endpoint-aws-primary" `
  -ProfileName "tm-cloudinn" `
  -ResourceGroupName "rg-tm" `
  -Type ExternalEndpoints
$ep.EndpointStatus = "Disabled"
Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep

# Verify DNS resolves to Azure
Resolve-DnsName -Name "cloudinn-global.trafficmanager.net"

# Check Azure endpoint health
Get-AzTrafficManagerEndpoint `
  -Name "endpoint-azure-dr" `
  -ProfileName "tm-cloudinn" `
  -ResourceGroupName "rg-tm" `
  -Type AzureEndpoints | Select-Object Name, EndpointMonitorStatus

# Re-enable after testing
$ep.EndpointStatus = "Enabled"
Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep
```
