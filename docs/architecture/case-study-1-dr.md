# Architecture: Case Study 1 - Azure Dual-Region Disaster Recovery

## Overview

CloudInnovate runs an **active-passive** disaster recovery setup entirely within Azure, using two allowed regions:

- **Primary — East US:** Serves all live traffic under normal conditions
- **DR Standby — East US 2:** Identical infrastructure kept warm on standby; activated automatically by Traffic Manager when East US becomes unhealthy

Both regions use the same VNet address space, subnet layout, NSG rules, and application stack — mirroring each other. Azure Traffic Manager provides DNS-level failover with a ~30-60 second detection and switchover window.

---

## Architecture Diagram

```
                          ┌─────────────────────────────────────┐
                          │         INTERNET USERS              │
                          │     (Global DNS Clients)            │
                          └──────────────┬──────────────────────┘
                                         │
                                         │ DNS Query:
                                         │ cloudinn-global-xxxx.trafficmanager.net
                                         ▼
                    ┌────────────────────────────────────────────┐
                    │         AZURE TRAFFIC MANAGER              │
                    │   (Global resource, in rg-cloudinn-        │
                    │    primary-prod)                           │
                    │                                            │
                    │   Routing : Priority   TTL : 30s          │
                    │   Probe   : HTTPS /health every 10s       │
                    │   Failover: 2 consecutive failures         │
                    └──────────┬─────────────────────┬──────────┘
                               │                     │
                    Priority 1 │           Priority 2│
                    (Healthy)  │              (Standby — only if P1 fails)
                               ▼                     ▼
         ┌──────────────────────────────┐   ┌──────────────────────────────────┐
         │  EAST US — PRIMARY           │   │  EAST US 2 — DR STANDBY         │
         │  rg-cloudinn-primary-prod    │   │  rg-cloudinn-dr-prod             │
         │                              │   │                                  │
         │  ┌──────────────────────┐    │   │  ┌──────────────────────────┐   │
         │  │  Azure Load Balancer │    │   │  │  Azure Load Balancer     │   │
         │  │  pip-lb-prod         │    │   │  │  pip-lb-prod             │   │
         │  │  (Standard, Static)  │    │   │  │  (Standard, Static)      │   │
         │  └──────────┬───────────┘    │   │  └────────────┬─────────────┘   │
         │             │                │   │               │                 │
         │  subnet-web (10.0.1.0/24)    │   │  subnet-web (10.0.1.0/24)       │
         │  NSG: Allow 443/80 Internet  │   │  NSG: Allow 443/80 Internet     │
         │  ┌──────────▼───────────┐    │   │  ┌────────────▼─────────────┐   │
         │  │  vm-web-prod         │    │   │  │  vm-web-prod             │   │
         │  │  Ubuntu 22.04+Nginx  │    │   │  │  Ubuntu 22.04+Nginx      │   │
         │  └──────────┬───────────┘    │   │  └────────────┬─────────────┘   │
         │             │                │   │               │                 │
         │  subnet-app (10.0.2.0/24)    │   │  subnet-app (10.0.2.0/24)       │
         │  NSG: Allow 8080 from web    │   │  NSG: Allow 8080 from web       │
         │  ┌──────────▼───────────┐    │   │  ┌────────────▼─────────────┐   │
         │  │  vm-app-prod         │    │   │  │  vm-app-prod             │   │
         │  │  Ubuntu 22.04        │    │   │  │  Ubuntu 22.04            │   │
         │  └──────────────────────┘    │   │  └──────────────────────────┘   │
         │                              │   │                                  │
         │  Storage: Standard_LRS       │   │  Storage: Standard_LRS          │
         │  (Blob: app-data container)  │   │  (Blob: app-data container)     │
         │                              │   │                                  │
         │  Azure DNS:                  │   │                                  │
         │  ├── Public Zone             │   │                                  │
         │  │   cloudinn-app.example.com│   │                                  │
         │  └── Private Zone            │   │                                  │
         │      internal.cloudinn.azure │   │                                  │
         └──────────────────────────────┘   └──────────────────────────────────┘
```

---

## Failover Sequence

```
NORMAL STATE (East US healthy):
User → DNS Query → Traffic Manager → Returns East US LB IP → User → East US

FAILOVER EVENT (East US outage detected):
1. Traffic Manager probes East US endpoint every 10s via HTTPS /health
2. After 2 consecutive failures (~20s), endpoint marked Degraded
3. Traffic Manager returns East US 2 IP for all new DNS queries
4. TTL = 30s → propagates globally within ~30 seconds
5. New clients connect to East US 2 automatically

FAILBACK (East US recovers):
1. Traffic Manager probes succeed again (2 consecutive)
2. East US endpoint Priority 1 reactivates automatically
3. DNS returns East US IP
4. East US 2 returns to warm standby
```

---

## Region & Resource Group Mapping

| Resource Group | Region | Role | Contains |
|----------------|--------|------|---------|
| `rg-cloudinn-primary-prod` | East US | Primary | VNet, VMs, LB, Storage, DNS zones, Traffic Manager |
| `rg-cloudinn-dr-prod` | East US 2 | DR Standby | VNet, VMs, LB, Storage |

---

## Resource Map

| Resource | Region | Description |
|----------|--------|-------------|
| `cloudinn-vnet-prod` | East US | VNet 10.0.0.0/16 (primary) |
| `cloudinn-vnet-prod` | East US 2 | VNet 10.0.0.0/16 (DR — same CIDR, isolated) |
| `nsg-web-prod` | Both | Allow 443/80 from Internet |
| `nsg-app-prod` | Both | Allow 8080 from web subnet only |
| `nsg-db-prod` | Both | Allow 5432 from app subnet only |
| `lb-web-prod` | Both | Standard Load Balancer |
| `pip-lb-prod` | Both | Static public IP → Traffic Manager endpoint |
| `vm-web-prod` | Both | Ubuntu 22.04 + Nginx (Standard_B2ms) |
| `vm-app-prod` | Both | Ubuntu 22.04 (Standard_B2ms) |
| `stcloudinn*` | Both | Storage Account, Standard_LRS, Blob container |
| `stcloudinn*` | Both | Storage Account Standard_LRS |
| `cloudinn-app.example.com` | Global | Public DNS Zone |
| `internal.cloudinn.azure` | Global | Private DNS Zone (linked to primary VNet) |
| `tm-cloudinn-dr` | Global | Traffic Manager, Priority routing |

---

## Security Layers

```
Layer 1: Network (NSGs)
  ├── Web tier : Only 443 and 80 from Internet
  ├── App tier : Only 8080 from web subnet (10.0.1.0/24)
  └── DB tier  : Only 5432 from app subnet (10.0.2.0/24)

Layer 2: VM Access
  └── VMs have no public IPs — access via Azure Cloud Shell or jump box if needed

Layer 3: Data
  ├── Storage: HTTPS only, TLS 1.2 minimum, no public blob access
  └── Storage:   HTTPS only, allowBlobPublicAccess = false, encryption at rest

Layer 4: DNS
  ├── Public zone: Internet-facing records
  └── Private zone: Internal service discovery within VNet
```

---

## Failover Test Commands

### Linux / macOS
```bash
TM_FQDN=$(az network traffic-manager profile show \
  --resource-group rg-cloudinn-primary-prod \
  --name tm-cloudinn-dr \
  --query dnsConfig.fqdn -o tsv)

# Before failover — should return East US IP
nslookup $TM_FQDN

# Disable East US (simulate outage)
az network traffic-manager endpoint update \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-dr \
  --name endpoint-eastus-primary \
  --type azureEndpoints \
  --endpoint-status Disabled

# Wait ~60s then check — should return East US 2 IP
sleep 60 && nslookup $TM_FQDN

# Re-enable (failback)
az network traffic-manager endpoint update \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-dr \
  --name endpoint-eastus-primary \
  --type azureEndpoints \
  --endpoint-status Enabled
```

### Windows (PowerShell)
```powershell
$tmFqdn = (Get-AzTrafficManagerProfile `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -Name "tm-cloudinn-dr").DnsConfig.Fqdn

# Before failover
Resolve-DnsName -Name $tmFqdn

# Disable East US
$ep = Get-AzTrafficManagerEndpoint -Name "endpoint-eastus-primary" `
  -ProfileName "tm-cloudinn-dr" -ResourceGroupName "rg-cloudinn-primary-prod" `
  -Type AzureEndpoints
$ep.EndpointStatus = "Disabled"
Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep

# Wait and verify failover to East US 2
Start-Sleep -Seconds 60
Resolve-DnsName -Name $tmFqdn

# Re-enable (failback)
$ep.EndpointStatus = "Enabled"
Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep
```
