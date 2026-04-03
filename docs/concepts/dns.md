# Azure DNS Concepts

## What is Azure DNS?

Azure DNS is a **hosting service** for DNS domains. It uses Microsoft's global network of name servers to provide ultra-fast DNS resolution. Azure DNS does NOT sell domain names — you register domains through domain registrars (GoDaddy, Namecheap, etc.) and then delegate DNS management to Azure.

---

## DNS Zone Types

### Public DNS Zones

Used for **internet-facing** domain resolution. Anyone on the internet can resolve records in a public zone.

```
Public Zone: shopeasy.com
├── A     @          → 20.10.5.100   (apex domain → load balancer IP)
├── A     www        → 20.10.5.100   (www subdomain)
├── CNAME api        → api-lb.shopeasy.com
├── MX    @          → mail.shopeasy.com (10)
└── TXT   @          → "v=spf1 include:spf.protection.outlook.com ~all"
```

### Private DNS Zones

Used for **internal** resolution within Azure VNets. Not accessible from the internet. Ideal for microservices, databases, and internal applications.

```
Private Zone: internal.shopeasy.local
├── A     db-primary  → 10.0.3.4
├── A     db-replica  → 10.0.3.5
├── A     cache       → 10.0.2.10
└── CNAME api         → api-svc.internal.shopeasy.local
```

---

## DNS Record Types

| Record Type | Purpose | Example |
|-------------|---------|---------|
| **A** | IPv4 address mapping | `www → 20.10.5.100` |
| **AAAA** | IPv6 address mapping | `www → 2001:db8::1` |
| **CNAME** | Alias to another domain | `api → api.azurewebsites.net` |
| **MX** | Mail exchange server | `@ → mail.shopeasy.com (10)` |
| **TXT** | Text verification (SPF, DKIM) | `"v=spf1 include:..."` |
| **NS** | Name server delegation | Azure auto-generates these |
| **SOA** | Start of authority | Auto-managed by Azure |
| **SRV** | Service locator | `_http._tcp → 10 0 80 host` |
| **PTR** | Reverse DNS | `100.5.10.20.in-addr.arpa → vm1.shopeasy.com` |
| **CAA** | CA authorization | `0 issue "letsencrypt.org"` |

---

## DNS Delegation to Azure

When you move DNS to Azure, you must update the **NS records** at your domain registrar to point to Azure's name servers.

```
Step 1: Create DNS Zone in Azure
         → Azure assigns 4 name servers (e.g., ns1-01.azure-dns.com)

Step 2: At your registrar (GoDaddy, Namecheap, etc.)
         → Replace existing NS records with Azure's 4 NS records

Step 3: DNS propagation (5 min – 48 hours)
         → Global DNS resolvers learn about the new NS records
```

---

## Private DNS Zone Linking

Private zones must be **linked** to VNets before they resolve for resources in those VNets.

```
Private Zone: internal.shopeasy.local
  └── VNet Link → vnet-cloudinn (auto-registration: enabled)
      └── VMs in vnet-cloudinn auto-register their A records
```

With **auto-registration enabled:**
- VMs get their hostnames automatically registered in the private zone
- Records update when VM IP changes

---

## Azure Traffic Manager with DNS

Traffic Manager is a **DNS-based** global load balancer. It returns different IP addresses based on configured routing policies:

| Routing Method | Behavior |
|----------------|---------|
| **Priority** | Always send to primary endpoint; failover to secondary |
| **Weighted** | Distribute traffic by weight (e.g., 70/30) |
| **Performance** | Route to lowest-latency endpoint |
| **Geographic** | Route by user's geographic location |
| **Multivalue** | Return all healthy endpoints (for A/AAAA records) |
| **Subnet** | Route based on client IP address range |

Traffic Manager works at **DNS level** — it doesn't proxy traffic, just influences DNS resolution. The client connects directly to the endpoint.

---

## DNSSEC

**Domain Name System Security Extensions (DNSSEC)** adds cryptographic signatures to DNS responses, protecting against:

- **DNS Spoofing / Cache Poisoning:** Attackers injecting fake DNS responses
- **Man-in-the-Middle attacks:** Redirecting traffic to malicious servers

### How DNSSEC Works

```
1. Zone Signing:
   DNS zone is signed with a private key (ZSK - Zone Signing Key)
   
2. Key Publishing:
   Public key (DNSKEY record) published in the zone
   
3. Chain of Trust:
   Parent zone (e.g., .com) signs a DS record pointing to child zone's key
   
4. Validation:
   Resolvers verify signatures before returning results
   
RRSIG  → Signature over record set
DNSKEY → Public key used to verify signatures
DS     → Hash of child zone's key (in parent zone)
NSEC   → Proves non-existence of records
```

> **Note:** Azure DNS supports DNSSEC for public zones. As of 2024, it's available in preview. Private zones do not support DNSSEC as they're only accessible within trusted VNets.

---

## Key CLI Commands

### Linux / macOS (Azure CLI)

```bash
# Create public DNS zone
az network dns zone create \
  --resource-group rg-dns \
  --name shopeasy.com

# List Azure name servers for the zone
az network dns zone show \
  --resource-group rg-dns \
  --name shopeasy.com \
  --query nameServers \
  --output table

# Add A record
az network dns record-set a add-record \
  --resource-group rg-dns \
  --zone-name shopeasy.com \
  --record-set-name www \
  --ipv4-address 20.10.5.100

# Add CNAME record
az network dns record-set cname set-record \
  --resource-group rg-dns \
  --zone-name shopeasy.com \
  --record-set-name api \
  --cname api-lb.shopeasy.com

# Create private DNS zone
az network private-dns zone create \
  --resource-group rg-dns \
  --name internal.shopeasy.local

# Link private zone to VNet (with auto-registration)
az network private-dns link vnet create \
  --resource-group rg-dns \
  --zone-name internal.shopeasy.local \
  --name link-cloudinn-vnet \
  --virtual-network vnet-cloudinn \
  --registration-enabled true

# List DNS records
az network dns record-set list \
  --resource-group rg-dns \
  --zone-name shopeasy.com \
  --output table

# Test DNS resolution
nslookup www.shopeasy.com ns1-01.azure-dns.com
dig www.shopeasy.com @ns1-01.azure-dns.com
```

### Windows (PowerShell)

```powershell
# Create public DNS zone
New-AzDnsZone -Name "shopeasy.com" -ResourceGroupName "rg-dns"

# Get name servers
(Get-AzDnsZone -Name "shopeasy.com" -ResourceGroupName "rg-dns").NameServers

# Add A record
New-AzDnsRecordSet `
  -Name "www" `
  -RecordType A `
  -ZoneName "shopeasy.com" `
  -ResourceGroupName "rg-dns" `
  -Ttl 3600 `
  -DnsRecords (New-AzDnsRecordConfig -IPv4Address "20.10.5.100")

# Add CNAME record
New-AzDnsRecordSet `
  -Name "api" `
  -RecordType CNAME `
  -ZoneName "shopeasy.com" `
  -ResourceGroupName "rg-dns" `
  -Ttl 3600 `
  -DnsRecords (New-AzDnsRecordConfig -Cname "api-lb.shopeasy.com")

# Create private DNS zone
New-AzPrivateDnsZone -Name "internal.shopeasy.local" -ResourceGroupName "rg-dns"

# Link private zone to VNet
$vnet = Get-AzVirtualNetwork -Name "vnet-cloudinn" -ResourceGroupName "rg-network"
New-AzPrivateDnsVirtualNetworkLink `
  -ZoneName "internal.shopeasy.local" `
  -ResourceGroupName "rg-dns" `
  -Name "link-cloudinn-vnet" `
  -VirtualNetworkId $vnet.Id `
  -EnableRegistration

# Test DNS with PowerShell
Resolve-DnsName -Name "www.shopeasy.com" -Server "ns1-01.azure-dns.com"
```
