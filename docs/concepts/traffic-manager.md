# Azure Traffic Manager

## What is Traffic Manager?

Azure Traffic Manager is a **DNS-based global traffic load balancer**. It distributes traffic across multiple Azure regions or external endpoints based on configurable routing methods and health probe monitoring.

> **Key concept:** Traffic Manager operates at the **DNS layer** — it does NOT proxy or inspect traffic. It simply tells clients which endpoint IP to use. The client then connects directly to that endpoint.

---

## How Traffic Manager Works

```
1. Client queries DNS for myapp.trafficmanager.net
2. Traffic Manager evaluates:
   - Health of all endpoints (from probes)
   - Routing method (priority/performance/geographic/etc.)
3. Traffic Manager returns IP of the best endpoint
4. Client connects DIRECTLY to that endpoint

Client ──DNS Query──▶ Traffic Manager
       ◀──Returns IP──
Client ──────────────────────────────▶ Endpoint (Azure Public IP / LB)
```

---

## Routing Methods

### Priority Routing (for DR Failover)

Routes all traffic to the primary endpoint. Fails over to secondary if primary is unhealthy.

```
Priority 1: East US (Primary)        ← All traffic here normally
Priority 2: East US 2 (DR)           ← Only if Priority 1 fails
```

**Use case:** CloudInnovate dual-region disaster recovery

### Performance Routing

Routes users to the endpoint with the **lowest latency** (closest data center).

```
User in US East  → East US endpoint
User in US South → East US 2 endpoint
```

**Use case:** Global SaaS apps where latency is critical

### Geographic Routing

Routes based on the **geographic region** of the DNS query origin.

```
Queries from NA/SA → East US endpoint
Queries from WORLD → East US 2 endpoint
```

**Use case:** Data sovereignty requirements, regional compliance

### Weighted Routing

Distributes traffic across endpoints by **weight percentage**.

```
Endpoint A: weight 80 → receives ~80% of traffic
Endpoint B: weight 20 → receives ~20% of traffic (canary deploy)
```

**Use case:** Canary deployments, A/B testing, gradual migration

### Multivalue Routing

Returns **all healthy endpoints** in a single DNS response. Client picks one.

**Use case:** When you want clients to choose from multiple IPs

### Subnet Routing

Routes based on the **client's IP address range**.

```
10.0.0.0/8     → Internal testing endpoint
0.0.0.0/0      → Production endpoint
```

**Use case:** Internal vs external user routing

---

## Endpoints

Traffic Manager supports three endpoint types:

| Type | Description | Example |
|------|-------------|---------|
| **Azure Endpoints** | Azure resources with public IPs | Public IP, Load Balancer |
| **External Endpoints** | Non-Azure resources | On-prem server, third-party CDN |
| **Nested Endpoints** | Another Traffic Manager profile | Combine routing methods |

---

## Health Monitoring

Traffic Manager probes each endpoint at regular intervals:

| Setting | Description | Default |
|---------|-------------|---------|
| Protocol | HTTP, HTTPS, or TCP | HTTP |
| Port | Port to probe | 80 |
| Path | URL path for HTTP/HTTPS | `/` |
| Interval | Seconds between probes | 30s |
| Timeout | Seconds before marking as failed | 10s |
| Failures | Consecutive failures before degraded | 3 |

An endpoint is considered **unhealthy** when it exceeds the failure threshold. Traffic Manager stops routing to it immediately.

---

## TTL and Failover Speed

Traffic Manager DNS responses have a **TTL (Time-to-Live)**. Lower TTL = faster failover, but more DNS queries.

```
Endpoint goes unhealthy
    ↓
Traffic Manager detects after: [probe interval × failure threshold]
= 30s × 3 = ~90 seconds worst case

Client DNS TTL expires: default 60s
    ↓
Client re-queries DNS
    ↓
New endpoint IP returned
    ↓
Traffic rerouted
```

**For critical DR:** Set TTL to 20–30 seconds, interval to 10s, failures to 2.

---

## Key CLI Commands

### Linux / macOS (Azure CLI)

```bash
# Create Traffic Manager profile (priority failover)
az network traffic-manager profile create \
  --resource-group rg-cloudinn-primary-prod \
  --name tm-cloudinn-priority \
  --routing-method Priority \
  --unique-dns-name cloudinn-failover \
  --ttl 30 \
  --monitor-protocol HTTPS \
  --monitor-port 443 \
  --monitor-path "/health"

# Add East US primary endpoint (Priority 1)
az network traffic-manager endpoint create \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-priority \
  --name endpoint-primary \
  --type azureEndpoints \
  --target-resource-id /subscriptions/{sub-id}/resourceGroups/rg-cloudinn-primary-prod/providers/Microsoft.Network/publicIPAddresses/pip-lb-prod \
  --priority 1 \
  --endpoint-status Enabled

# Add East US 2 DR endpoint (Priority 2)
az network traffic-manager endpoint create \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-priority \
  --name endpoint-dr \
  --type azureEndpoints \
  --target-resource-id /subscriptions/{sub-id}/resourceGroups/rg-cloudinn-dr-prod/providers/Microsoft.Network/publicIPAddresses/pip-lb-prod \
  --priority 2 \
  --endpoint-status Enabled

# Check endpoint health
az network traffic-manager endpoint show \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-priority \
  --name endpoint-primary \
  --type azureEndpoints \
  --query "endpointMonitorStatus"

# Disable primary (simulate failover to East US 2)
az network traffic-manager endpoint update \
  --resource-group rg-cloudinn-primary-prod \
  --profile-name tm-cloudinn-priority \
  --name endpoint-primary \
  --type azureEndpoints \
  --endpoint-status Disabled \
  --output none

# Verify Traffic Manager DNS
nslookup cloudinn-failover.trafficmanager.net
```

### Windows (PowerShell)

```powershell
# Create Traffic Manager profile (priority failover)
New-AzTrafficManagerProfile `
  -Name "tm-cloudinn-priority" `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -TrafficRoutingMethod "Priority" `
  -RelativeDnsName "cloudinn-failover" `
  -Ttl 30 `
  -MonitorProtocol "HTTPS" `
  -MonitorPort 443 `
  -MonitorPath "/health"

# Add East US primary endpoint (Priority 1)
$pipPrimary = Get-AzPublicIpAddress -Name "pip-lb-prod" -ResourceGroupName "rg-cloudinn-primary-prod"
New-AzTrafficManagerAzureEndpoint `
  -Name "endpoint-primary" `
  -ProfileName "tm-cloudinn-priority" `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -TargetResourceId $pipPrimary.Id `
  -Priority 1

# Add East US 2 DR endpoint (Priority 2)
$pipDr = Get-AzPublicIpAddress -Name "pip-lb-prod" -ResourceGroupName "rg-cloudinn-dr-prod"
New-AzTrafficManagerAzureEndpoint `
  -Name "endpoint-dr" `
  -ProfileName "tm-cloudinn-priority" `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -TargetResourceId $pipDr.Id `
  -Priority 2

# Check endpoint status
Get-AzTrafficManagerEndpoint `
  -Name "endpoint-primary" `
  -ProfileName "tm-cloudinn-priority" `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -Type AzureEndpoints | Select-Object Name, EndpointMonitorStatus

# Disable primary (simulate failover)
$ep = Get-AzTrafficManagerEndpoint `
  -Name "endpoint-primary" `
  -ProfileName "tm-cloudinn-priority" `
  -ResourceGroupName "rg-cloudinn-primary-prod" `
  -Type AzureEndpoints
$ep.EndpointStatus = "Disabled"
Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep

# Test DNS
Resolve-DnsName -Name "cloudinn-failover.trafficmanager.net"
```
