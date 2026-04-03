# DNSSEC: Domain Name System Security Extensions

## The Problem DNSSEC Solves

Without DNSSEC, DNS is vulnerable to:

```
Normal DNS (vulnerable):
Client → asks "What's the IP of shopeasy.com?"
         ↓
     DNS Resolver (could be poisoned!)
         ↓
Attacker injects fake response: "shopeasy.com = 1.2.3.4 (attacker's server)"
         ↓
Client sends credentials to ATTACKER'S server
```

```
With DNSSEC (protected):
Client → asks "What's the IP of shopeasy.com?"
         ↓
     DNS Resolver gets response WITH cryptographic signature
         ↓
Resolver VERIFIES signature against published public key
         ↓
If signature invalid → Response rejected (attacker foiled!)
         ↓
If signature valid → Return trusted IP to client
```

---

## DNSSEC Record Types

| Record | Purpose |
|--------|---------|
| **RRSIG** | Digital signature over a DNS record set |
| **DNSKEY** | Public key used to verify RRSIG signatures |
| **DS** | Hash of a child zone's DNSKEY (stored in parent zone) |
| **NSEC** | Points to next record name; proves record doesn't exist |
| **NSEC3** | Hashed version of NSEC; prevents zone enumeration |

---

## Chain of Trust

```
Root Zone (.)
  └── DNSKEY (root's public key, pre-installed in resolvers)
  └── DS for .com → signs .com zone

.com Zone
  └── DNSKEY (.com's public key)
  └── DS for shopeasy.com → signs shopeasy.com zone

shopeasy.com Zone  ← Your zone in Azure DNS
  └── DNSKEY (your zone's signing key)
  └── RRSIG on every record set
  └── A, MX, TXT, etc. records
```

Every step in the chain is cryptographically verified. If any link breaks, the resolver rejects the response.

---

## DNSSEC Setup Process in Azure

### Step 1: Enable DNSSEC on Azure DNS Zone

```bash
# Linux / macOS
az network dns dnssec-config create \
  --resource-group rg-dns \
  --zone-name shopeasy.example.com

# Check status
az network dns dnssec-config show \
  --resource-group rg-dns \
  --zone-name shopeasy.example.com
```

```powershell
# Windows
# Use Azure Portal or REST API (PowerShell module support varies)
az network dns dnssec-config create `
  --resource-group rg-dns `
  --zone-name shopeasy.example.com
```

### Step 2: Get the DS Record

After enabling DNSSEC, Azure generates key pairs and provides a DS record that must be added to the parent zone.

```bash
# Get DS record details
az network dns dnssec-config show \
  --resource-group rg-dns \
  --zone-name shopeasy.example.com \
  --query "signingKeys[].delegationSignerInfo"
```

Example DS record output:
```
KeyTag: 12345
Algorithm: 13 (ECDSA Curve P-256 with SHA-256)
DigestType: 2 (SHA-256)
Digest: ABC123DEF456...

DS record format for registrar:
shopeasy.example.com. 3600 IN DS 12345 13 2 ABC123DEF456...
```

### Step 3: Add DS Record at Registrar

Log into your domain registrar (GoDaddy, Namecheap, etc.) and add the DS record:

| Field | Value |
|-------|-------|
| Key Tag | 12345 (from above) |
| Algorithm | 13 |
| Digest Type | 2 |
| Digest | ABC123DEF456... |

### Step 4: Verify DNSSEC

```bash
# Verify DNSSEC validation (Linux)
dig +dnssec shopeasy.example.com SOA

# Should show AD flag (Authenticated Data) in response
# ;; flags: qr rd ra ad;    ← 'ad' means DNSSEC validated!

# Test with dnssec-verify tool
dig +sigchase +trusted-key=~/.trusted-key.key shopeasy.example.com A

# Online tools:
# https://dnsviz.net
# https://dnssec-analyzer.verisignlabs.com
# https://www.dnssec-debugger.verisignlabs.com
```

```powershell
# Windows PowerShell
Resolve-DnsName -Name "shopeasy.example.com" -Type A -DnssecOk

# Check RRSIG records
Resolve-DnsName -Name "shopeasy.example.com" -Type RRSIG
```

---

## DNSSEC Key Rollover

Azure manages key rollovers automatically. Types of keys:

| Key | Abbrev | Role | Rollover |
|-----|--------|------|----------|
| Zone Signing Key | ZSK | Signs individual records | Monthly (auto) |
| Key Signing Key | KSK | Signs the DNSKEY record set | Annual (auto) |

---

## Common DNSSEC Mistakes

| Mistake | Consequence | Fix |
|---------|-------------|-----|
| DS record not added to parent | DNSSEC fails for all validating resolvers | Add DS record at registrar |
| DS record added before DNSSEC enabled | Chain of trust broken | Enable DNSSEC first, then add DS |
| Low SOA TTL with DNSSEC | Slow propagation | Set TTL to at least 3600 for DNSKEY/DS records |
| Removing DS before disabling DNSSEC | Resolvers may cache old signed responses | Always disable DNSSEC before removing DS |
