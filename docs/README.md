# Introduction to Azure - II: Hands-On Training

## Session Overview

**Module:** Introduction to Azure - II  
**Duration:** 120 minutes  
**Level:** Intermediate  

---

## Learning Objectives

By the end of this session, learners will be able to:

1. Deploy and configure **Azure Virtual Networks (VNet)** with subnets
2. Manage **Azure DNS** for both public and private name resolution
3. Deploy infrastructure using **ARM Templates** and **Bicep**
4. Configure **Azure Traffic Manager** for global traffic distribution and failover
5. Implement **dual-region disaster recovery** (East US → East US 2 failover)
6. Secure DNS with **DNSSEC** and geo-based routing

---

## Agenda

| Part | Topic | Duration |
|------|-------|----------|
| Part I | Introduction & Overview | 10 mins |
| Part II | Case Studies (Hands-On) | 100 mins |
| Part III | Summary & Doubt Resolution | 10 mins |

---

## Case Studies

### Case Study 3: Azure Dual-Region Disaster Recovery

**Scenario:** CloudInnovate (a global SaaS company) needs a dual-region DR setup across East US (primary) and East US 2 (standby) with automatic failover.

**Hands-On Tasks:**
- Deploy Azure VNet with subnets in both regions
- Configure Azure DNS (public and private zones)
- Deploy ARM/Bicep templates for VMs, Load Balancer, and Storage
- Implement Azure Traffic Manager for priority-based failover
- Perform a live failover test

📁 Lab files: `labs/case-study-3-dr/`

---

### Case Study 4: Scalable and Secure DNS Management for a Global Enterprise

**Scenario:** ShopEasy (a multinational e-commerce company) needs highly available, globally distributed DNS with DNSSEC protection.

**Hands-On Tasks:**
- Register and host a custom domain in Azure DNS
- Configure public and private DNS zones
- Implement geo-based routing via Traffic Manager
- Enable DNSSEC for DNS spoofing protection
- Simulate DNS failure and test automatic recovery

📁 Lab files: `labs/case-study-4-dns/`

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Azure Subscription | Free tier or Pay-as-you-go |
| Azure CLI | v2.50+ |
| Azure PowerShell | Az module v10+ |
| Bicep CLI | v0.20+ |
| VS Code | With Bicep & Azure extensions |
| Access | Owner or Contributor role on subscription |

---

## Quick Start

### Linux / macOS
```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Install Bicep
az bicep install

# Login
az login

# Run setup
chmod +x scripts/linux/setup.sh
./scripts/linux/setup.sh
```

### Windows (PowerShell)
```powershell
# Install Azure PowerShell
Install-Module -Name Az -Repository PSGallery -Force

# Install Azure CLI
winget install Microsoft.AzureCLI

# Login
Connect-AzAccount

# Run setup
.\scripts\windows\setup.ps1
```

---

## Concepts Covered

| Concept | Documentation |
|---------|---------------|
| Azure VNet & Subnets | [docs/concepts/networking.md](concepts/networking.md) |
| Azure DNS | [docs/concepts/dns.md](concepts/dns.md) |
| ARM Templates & Bicep | [docs/concepts/iac.md](concepts/iac.md) |
| Traffic Manager | [docs/concepts/traffic-manager.md](concepts/traffic-manager.md) |
| Disaster Recovery | [docs/concepts/disaster-recovery.md](concepts/disaster-recovery.md) |
| DNSSEC | [docs/concepts/dnssec.md](concepts/dnssec.md) |

---

## Presentation Slides

- [Case Study 3 - DR Slides](slides/case-study-3.html) (open in browser)
- [Case Study 4 - DNS Slides](slides/case-study-4.html) (open in browser)

## Architecture Diagrams

- [Case Study 3 - DR Architecture](architecture/case-study-3-dr.md)
- [Case Study 4 - DNS Architecture](architecture/case-study-4-dns.md)

---

## File Structure

```
azure-6/
├── docs/
│   ├── README.md                      ← You are here
│   ├── slides/                        ← HTML presentation slides
│   ├── architecture/                  ← Architecture diagrams
│   └── concepts/                      ← Concept documentation
├── labs/
│   ├── case-study-3-dr/               ← Disaster Recovery lab
│   │   ├── 01-vnet/                   ← VNet & Subnet deployment
│   │   ├── 02-dns/                    ← DNS zones setup
│   │   ├── 03-arm-templates/          ← VM, LB, Storage templates
│   │   └── 04-traffic-manager/        ← Traffic Manager config
│   └── case-study-4-dns/              ← DNS Management lab
│       ├── 01-dns-zones/              ← Public & Private DNS zones
│       ├── 02-traffic-manager/        ← Geo-routing config
│       └── 03-dnssec/                 ← DNSSEC configuration
└── scripts/
    ├── linux/                         ← Bash scripts
    └── windows/                       ← PowerShell scripts
```
