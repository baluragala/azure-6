# Architecture: Case Study 4 - Global DNS Management for ShopEasy

## Overview

ShopEasy deploys a multi-region e-commerce platform across three Azure regions. Azure DNS provides both public and private name resolution. Three Traffic Manager profiles handle routing: geographic, performance-based, and priority failover. DNSSEC protects the public zone.

---

## Global DNS Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │          INTERNET CLIENTS                   │
                    │    (Users from US, EU, APAC, Rest of World) │
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
             │  A     @    → 20.10.5.100  (LB East US)          │
             │  A     www  → 20.10.5.100                        │
             │  A     us   → 20.10.5.100  (East US)             │
             │  A     eu   → 52.174.5.200 (West Europe)         │
             │  A     ap   → 20.195.10.50 (Southeast Asia)      │
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
         │  ┌─────────────────────┐   ┌──────────────────────────┐   │
         │  │ tm-shopeasy-geo     │   │ tm-shopeasy-failover     │   │
         │  │ Geographic Routing  │   │ Priority Routing         │   │
         │  │                     │   │                          │   │
         │  │ NA+SA → East US     │   │ P1: East US              │   │
         │  │ EU+AF → W.Europe    │   │ P2: West Europe          │   │
         │  │ AP    → SE Asia     │   │ P3: Southeast Asia       │   │
         │  └────────┬────────────┘   └────────────┬─────────────┘   │
         │           │                             │                  │
         │  ┌────────▼────────────────────────────▼──────────────┐   │
         │  │           tm-shopeasy-perf                         │   │
         │  │           Performance Routing                      │   │
         │  │           (Routes to lowest-latency endpoint)      │   │
         │  └─────────────────────────────────────────────────────┘  │
         └──────────┬────────────────────────┬───────────────┬───────┘
                    │                        │               │
                    ▼                        ▼               ▼
      ┌─────────────────────┐  ┌──────────────────┐  ┌──────────────────┐
      │   EAST US            │  │  WEST EUROPE      │  │  SOUTHEAST ASIA  │
      │   Primary Region     │  │  Secondary Region │  │  APAC Region     │
      │                      │  │                  │  │                  │
      │  pip-lb-us-prod      │  │  pip-lb-eu-prod  │  │  pip-lb-ap-prod  │
      │  20.10.5.100         │  │  52.174.5.200    │  │  20.195.10.50   │
      │                      │  │                  │  │                  │
      │  rg-shopeasy-us      │  │  rg-shopeasy-eu  │  │  rg-shopeasy-ap  │
      └─────────────────────┘  └──────────────────┘  └──────────────────┘
```

---

## Multi-Tier DNS Resolution

```
                EXTERNAL USERS                      INTERNAL SERVICES
                    │                                      │
                    │                                      │
             Public DNS Zone                        Private DNS Zone
         shopeasy.example.com                   corp.shopeasy.internal
                    │                                      │
          ┌─────────┴──────────┐              ┌───────────┴──────────────┐
          │ www → 20.10.5.100  │              │ order-service  → 10.0.2.10│
          │ api → api-gw.FQDN  │              │ product-service → 10.0.2.11│
          │ cdn → azureedge.net│              │ db-master      → 10.0.3.4 │
          │ us  → East US LB   │              │ db-replica     → 10.0.3.5 │
          │ eu  → EU LB        │              │ redis          → 10.0.2.20│
          └────────────────────┘              └───────────────────────────┘
                                                           │
                                              Linked to: vnet-shopeasy-prod
                                              Auto-registration: ON
                                              VMs auto-register A records
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
Europe              → tm-shopeasy-geo         → West Europe (52.174.5.200)
Middle East/Africa  → tm-shopeasy-geo         → West Europe (52.174.5.200)
Asia Pacific        → tm-shopeasy-geo         → SE Asia (20.195.10.50)

All users           → tm-shopeasy-perf        → Lowest latency endpoint
                                                 (measured real-time)

DNS Failure Test    → tm-shopeasy-failover    → P1 East US
                                              → P2 West Europe (if P1 down)
                                              → P3 SE Asia (if P2 down)
```

---

## Resource Map

| Resource | Region | Purpose |
|----------|--------|---------|
| `shopeasy.example.com` (Public DNS) | Global | Internet-facing DNS |
| `corp.shopeasy.internal` (Private DNS) | Global | Internal service discovery |
| `link-shopeasy-vnet` (VNet Link) | East US | Connects private zone to VNet |
| `tm-shopeasy-geo` (Traffic Manager) | Global | Geographic routing |
| `tm-shopeasy-perf` (Traffic Manager) | Global | Performance routing |
| `tm-shopeasy-failover` (Traffic Manager) | Global | Priority failover |
| `pip-lb-us-prod` | East US | East US LB entry |
| `pip-lb-eu-prod` | West Europe | EU LB entry |
| `pip-lb-ap-prod` | Southeast Asia | APAC LB entry |
| DNSSEC Config | Global | Zone signing keys |

---

## DNS Failure Recovery Flow

```
NORMAL:
Client → DNS: "shopeasy.example.com?"
       ← DNS: "20.10.5.100 (East US)" [RRSIG verified ✓]

EAST US FAILURE:
1. Traffic Manager probes East US every 30s
2. After 3 failures (~90s), East US marked degraded
3. Priority failover: next query returns West Europe IP
4. Client connects to West Europe
5. TTL=60s means full propagation in ~60 seconds

AUTO RECOVERY:
1. East US probes succeed again (2 consecutive)
2. Traffic Manager re-enables East US endpoint
3. DNS starts returning East US IP
4. Global users return to East US within 1-2 minutes

BACKUP NAME SERVERS:
   If Azure DNS itself has issues (extremely rare):
   → backup.shopeasy.example.com NS records point to backup DNS
   → Manual CNAME switch to backup.shopeasy.example.com
```
