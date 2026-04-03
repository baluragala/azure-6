# Architecture: Case Study 4 - Global DNS Management for ShopEasy

## Overview

ShopEasy deploys a dual-region e-commerce platform across two allowed Azure regions:

- **East US** — Primary region, serves all live traffic
- **East US 2** — DR / secondary region, activated by Traffic Manager failover

Azure DNS provides both public and private name resolution. Three Traffic Manager profiles handle routing: geographic, performance-based, and priority failover. DNSSEC protects the public zone.

---

## Global DNS Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │          INTERNET CLIENTS                   │
                    │    (Users from any location worldwide)      │
                    └────────────────┬────────────────────────────┘
                                     │
                                     │ Query: shopeasy.example.com
                                     ▼
                    ┌────────────────────────────────────────────┐
                    │         DOMAIN REGISTRAR                   │
                    │   (GoDaddy / Namecheap / Google Domains)   │
                    │   NS Records → ns1-XX.azure-dns.com        │
                    └────────────────┬───────────────────────────┘
                                     │ Delegates to
                                     ▼
             ┌───────────────────────────────────────────────────┐
             │         AZURE DNS - PUBLIC ZONE                   │
             │           shopeasy.example.com                    │
             │                                                   │
             │  A     @    → 20.10.5.100  (LB East US primary)  │
             │  A     www  → 20.10.5.100                        │
             │  A     us   → 20.10.5.100  (East US primary)     │
             │  A     dr   → 20.40.5.100  (East US 2 DR)        │
             │  CNAME api  → api-gw.shopeasy.example.com        │
             │  CNAME cdn  → shopeasy.azureedge.net             │
             │  MX    @    → mail.protection.outlook.com         │
             │  TXT   @    → "v=spf1 include:..."               │
             │  CAA   @    → issue "letsencrypt.org"            │
             │                                                   │
             │  🔐 DNSSEC: Zone signed with ECDSA P-256         │
             │     RRSIG on every record set                     │
             └────────────────┬──────────────────────────────────┘
                              │ CNAME for geo.shopeasy.example.com
                              ▼
         ┌─────────────────────────────────────────────────────────────┐
         │              AZURE TRAFFIC MANAGER                         │
         │                                                             │
         │  ┌──────────────────────────┐  ┌──────────────────────┐   │
         │  │ tm-shopeasy-geo          │  │ tm-shopeasy-failover  │   │
         │  │ Geographic Routing       │  │ Priority Routing      │   │
         │  │                          │  │                       │   │
         │  │ NA+SA  → East US         │  │ P1: East US           │   │
         │  │ WORLD  → East US 2       │  │ P2: East US 2         │   │
         │  └────────┬─────────────────┘  └───────────┬───────────┘   │
         │           │                                │                │
         │  ┌────────▼────────────────────────────────▼───────────┐   │
         │  │           tm-shopeasy-perf                          │   │
         │  │           Performance Routing                       │   │
         │  │           (Routes to lowest-latency endpoint)       │   │
         │  └──────────────────────────────────────────────────────┘  │
         └──────────────────┬──────────────────────┬──────────────────┘
                            │                      │
                            ▼                      ▼
         ┌──────────────────────────┐  ┌──────────────────────────────┐
         │   EAST US — PRIMARY      │  │  EAST US 2 — DR STANDBY      │
         │   rg-shopeasy-us         │  │  rg-shopeasy-eastus2          │
         │                          │  │                               │
         │   pip-lb-us-prod         │  │  pip-lb-eastus2-prod          │
         │   20.10.5.100            │  │  20.40.5.100                  │
         │                          │  │                               │
         │   vnet-shopeasy-prod     │  │  vnet-shopeasy-dr             │
         │   (Private DNS linked)   │  │  (Private DNS linked)         │
         └──────────────────────────┘  └──────────────────────────────┘
```

---

## Multi-Tier DNS Resolution

```
                EXTERNAL USERS                      INTERNAL SERVICES
                    │                                      │
             Public DNS Zone                        Private DNS Zone
         shopeasy.example.com                   corp.shopeasy.internal
                    │                                      │
          ┌─────────┴──────────┐              ┌───────────┴──────────────┐
          │ www → 20.10.5.100  │              │ order-service  → 10.0.2.10│
          │ us  → East US LB   │              │ product-service → 10.0.2.11│
          │ dr  → East US 2 LB │              │ db-master      → 10.0.3.4 │
          │ api → api-gw.FQDN  │              │ db-replica     → 10.0.3.5 │
          │ cdn → azureedge.net│              │ redis          → 10.0.2.20│
          └────────────────────┘              └───────────────────────────┘
                                                           │
                                              Linked to: vnet-shopeasy-prod (East US)
                                              Also linked: vnet-shopeasy-dr (East US 2)
                                              Auto-registration: ON (East US)
```

---

## DNSSEC Chain of Trust

```
ROOT ZONE (.)
    │
    │ DS record (signed by root)
    ▼
.COM ZONE
    │
    │ DS record (signed by .com)
    ▼
shopeasy.example.com   ← Your zone in Azure DNS
    │
    ├── DNSKEY: Azure's signing key (published publicly)
    ├── RRSIG:  Signature on every record set
    │            e.g., RRSIG(A www. ECDSA SHA-256 ...)
    │
    └── Resolver validates:
        1. Fetch DNSKEY from Azure DNS
        2. Verify RRSIG matches DNSKEY
        3. Verify DNSKEY matches DS in parent (.com)
        4. ✓ Chain of trust validated → Return result
           ✗ Mismatch → Reject (SERVFAIL)
```

---

## Traffic Routing by User Location

```
User Location       → Traffic Manager Profile → Azure Region Endpoint
─────────────────────────────────────────────────────────────────────
North America       → tm-shopeasy-geo         → East US (20.10.5.100)
South America       → tm-shopeasy-geo         → East US (20.10.5.100)
Europe / Asia /     → tm-shopeasy-geo         → East US 2 (20.40.5.100)
  Africa / APAC       (WORLD geo mapping)

All users           → tm-shopeasy-perf        → Lowest latency endpoint
                                                 (measured real-time between
                                                  East US and East US 2)

DNS Failure Test    → tm-shopeasy-failover    → P1 East US
                                              → P2 East US 2 (if P1 down)
```

---

## Resource Map

| Resource | Region | Purpose |
|----------|--------|---------|
| `shopeasy.example.com` (Public DNS) | Global | Internet-facing DNS |
| `corp.shopeasy.internal` (Private DNS) | Global | Internal service discovery |
| `link-shopeasy-vnet-eastus` (VNet Link) | East US | Connects private zone to primary VNet |
| `link-shopeasy-vnet-eastus2` (VNet Link) | East US 2 | Connects private zone to DR VNet |
| `tm-shopeasy-geo` (Traffic Manager) | Global | Geographic routing (NA/SA → East US, WORLD → East US 2) |
| `tm-shopeasy-perf` (Traffic Manager) | Global | Performance routing |
| `tm-shopeasy-failover` (Traffic Manager) | Global | Priority failover (P1 East US, P2 East US 2) |
| `pip-lb-us-prod` | East US | East US primary endpoint |
| `pip-lb-eastus2-prod` | East US 2 | East US 2 DR endpoint |
| DNSSEC Config | Global | Zone signing keys |

---

## DNS Failure Recovery Flow

```
NORMAL:
Client → DNS: "shopeasy.example.com?"
       ← DNS: "20.10.5.100 (East US)" [RRSIG verified ✓]

EAST US FAILURE:
1. Traffic Manager probes East US endpoint every 10s
2. After 2 failures (~20s), East US marked degraded
3. Priority failover: next query returns East US 2 IP
4. Client connects to East US 2 (20.40.5.100)
5. TTL=30s means full propagation in ~30 seconds

AUTO RECOVERY:
1. East US probes succeed again (2 consecutive)
2. Traffic Manager re-enables East US endpoint
3. DNS starts returning East US IP
4. Global users return to East US within ~60 seconds

BACKUP NAME SERVERS:
   If Azure DNS itself has issues (extremely rare):
   → backup.shopeasy.example.com NS records point to backup DNS
   → Manual CNAME switch to backup.shopeasy.example.com
```

---

## Failover Test Commands

### Linux / macOS

```bash
TM_FQDN=$(az network traffic-manager profile show \
  --resource-group rg-shopeasy-dns \
  --name tm-shopeasy-failover \
  --query dnsConfig.fqdn -o tsv)

# Before failover — should return East US IP
nslookup $TM_FQDN

# Disable East US (simulate outage)
az network traffic-manager endpoint update \
  --resource-group rg-shopeasy-dns \
  --profile-name tm-shopeasy-failover \
  --name primary-east-us \
  --type azureEndpoints \
  --endpoint-status Disabled

# Wait ~60s then check — should return East US 2 IP
sleep 60 && nslookup $TM_FQDN

# Re-enable (failback)
az network traffic-manager endpoint update \
  --resource-group rg-shopeasy-dns \
  --profile-name tm-shopeasy-failover \
  --name primary-east-us \
  --type azureEndpoints \
  --endpoint-status Enabled
```

### Windows (PowerShell)

```powershell
$tmFqdn = (Get-AzTrafficManagerProfile `
  -ResourceGroupName "rg-shopeasy-dns" `
  -Name "tm-shopeasy-failover").DnsConfig.Fqdn

# Before failover
Resolve-DnsName -Name $tmFqdn

# Disable East US
$ep = Get-AzTrafficManagerEndpoint -Name "primary-east-us" `
  -ProfileName "tm-shopeasy-failover" -ResourceGroupName "rg-shopeasy-dns" `
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
