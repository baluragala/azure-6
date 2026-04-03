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
Client ──────────────────────────────▶ Endpoint (Azure/AWS/on-prem)
```

---

## Routing Methods

### Priority Routing (for DR Failover)

Routes all traffic to the primary endpoint. Fails over to secondary if primary is unhealthy.

```
Priority 1: AWS Primary Endpoint     ← All traffic here normally
Priority 2: Azure DR Endpoint        ← Only if Priority 1 fails
Priority 3: Azure West US (backup)   ← Last resort
```

**Use case:** CloudInnovate cross-cloud disaster recovery

### Performance Routing

Routes users to the endpoint with the **lowest latency** (closest data center).

```
User in Asia     → Singapore endpoint
User in Europe   → West Europe endpoint
User in US East  → East US endpoint
```

**Use case:** Global SaaS apps where latency is critical

### Geographic Routing

Routes based on the **geographic region** of the DNS query origin.

```
Queries from EU    → eu.shopeasy.com endpoint
Queries from US    → us.shopeasy.com endpoint
Queries from APAC  → ap.shopeasy.com endpoint
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
| **Azure Endpoints** | Azure resources with public IPs | App Service, Cloud Service, Public IP |
| **External Endpoints** | Non-Azure resources | AWS ALB, on-prem server |
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
# Create Traffic Manager profile
az network traffic-manager profile create \
  --resource-group rg-tm \
  --name tm-cloudinn \
  --routing-method Priority \
  --unique-dns-name cloudinn-global \
  --ttl 30 \
  --monitor-protocol HTTPS \
  --monitor-port 443 \
  --monitor-path "/health"

# Add Azure endpoint
az network traffic-manager endpoint create \
  --resource-group rg-tm \
  --profile-name tm-cloudinn \
  --name endpoint-azure-dr \
  --type azureEndpoints \
  --target-resource-id /subscriptions/{sub-id}/resourceGroups/rg-dr/providers/Microsoft.Network/publicIPAddresses/pip-dr \
  --priority 2 \
  --endpoint-status Enabled

# Add External endpoint (for AWS primary)
az network traffic-manager endpoint create \
  --resource-group rg-tm \
  --name endpoint-aws-primary \
  --profile-name tm-cloudinn \
  --type externalEndpoints \
  --target "52.90.100.200" \
  --endpoint-location "East US" \
  --priority 1 \
  --endpoint-status Enabled

# Check endpoint health
az network traffic-manager endpoint show \
  --resource-group rg-tm \
  --profile-name tm-cloudinn \
  --name endpoint-aws-primary \
  --type externalEndpoints \
  --query "properties.endpointMonitorStatus"

# Disable endpoint (simulate failover)
az network traffic-manager endpoint update \
  --resource-group rg-tm \
  --profile-name tm-cloudinn \
  --name endpoint-aws-primary \
  --type externalEndpoints \
  --endpoint-status Disabled

# Verify Traffic Manager DNS
nslookup cloudinn-global.trafficmanager.net
dig cloudinn-global.trafficmanager.net
```

### Windows (PowerShell)

```powershell
# Create Traffic Manager profile
New-AzTrafficManagerProfile `
  -Name "tm-cloudinn" `
  -ResourceGroupName "rg-tm" `
  -TrafficRoutingMethod "Priority" `
  -RelativeDnsName "cloudinn-global" `
  -Ttl 30 `
  -MonitorProtocol "HTTPS" `
  -MonitorPort 443 `
  -MonitorPath "/health"

# Add external endpoint (AWS primary)
New-AzTrafficManagerExternalEndpoint `
  -Name "endpoint-aws-primary" `
  -ProfileName "tm-cloudinn" `
  -ResourceGroupName "rg-tm" `
  -Target "52.90.100.200" `
  -EndpointLocation "East US" `
  -Priority 1

# Add Azure endpoint (DR)
$pip = Get-AzPublicIpAddress -Name "pip-dr" -ResourceGroupName "rg-dr"
New-AzTrafficManagerAzureEndpoint `
  -Name "endpoint-azure-dr" `
  -ProfileName "tm-cloudinn" `
  -ResourceGroupName "rg-tm" `
  -TargetResourceId $pip.Id `
  -Priority 2

# Check endpoint status
Get-AzTrafficManagerEndpoint `
  -Name "endpoint-aws-primary" `
  -ProfileName "tm-cloudinn" `
  -ResourceGroupName "rg-tm" `
  -Type ExternalEndpoints | Select-Object Name, EndpointMonitorStatus

# Disable endpoint (simulate failover)
$ep = Get-AzTrafficManagerEndpoint `
  -Name "endpoint-aws-primary" `
  -ProfileName "tm-cloudinn" `
  -ResourceGroupName "rg-tm" `
  -Type ExternalEndpoints
$ep.EndpointStatus = "Disabled"
Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep

# Test DNS
Resolve-DnsName -Name "cloudinn-global.trafficmanager.net"
```
