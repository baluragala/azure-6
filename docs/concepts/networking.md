# Azure Networking Concepts

## Azure Virtual Network (VNet)

A **Virtual Network (VNet)** is the fundamental building block for private networking in Azure. It enables Azure resources (VMs, databases, etc.) to securely communicate with each other, the internet, and on-premises networks.

### Key Properties

| Property | Description |
|----------|-------------|
| **Address Space** | CIDR range assigned to the VNet (e.g., `10.0.0.0/16`) |
| **Subnets** | Subdivisions within the VNet with their own CIDR ranges |
| **Region** | VNets are regional resources; use VNet peering for cross-region |
| **Isolation** | VNets are logically isolated from each other by default |

---

## Subnets

Subnets segment the VNet's address space into smaller ranges. Each subnet:
- Must be within the VNet address space
- Cannot overlap with other subnets
- Azure reserves the first 4 and last 1 IP in each subnet

### Example CIDR Planning (Azure dual-region DR lab)

```
VNet: 10.0.0.0/16  (65,536 addresses)
├── subnet-web     10.0.1.0/24   (256 addresses) - Web tier
├── subnet-app     10.0.2.0/24   (256 addresses) - Application tier
├── subnet-db      10.0.3.0/24   (256 addresses) - Database tier
└── subnet-gateway 10.0.4.0/27   (32 addresses)  - VPN/ExpressRoute GW
```

---

## Network Security Groups (NSGs)

NSGs act as **layer-3/4 firewalls** for subnets and NICs. They contain inbound and outbound security rules.

### Rule Properties

| Field | Description | Example |
|-------|-------------|---------|
| Priority | 100–4096; lower = higher priority | `100` |
| Source | IP, CIDR, or Service Tag | `Internet` |
| Destination | IP, CIDR, or Service Tag | `10.0.1.0/24` |
| Protocol | TCP, UDP, ICMP, or Any | `TCP` |
| Port Range | Single, range, or `*` | `443` |
| Action | Allow or Deny | `Allow` |

### Common Service Tags

| Tag | Meaning |
|-----|---------|
| `Internet` | All internet IPs |
| `VirtualNetwork` | All VNet address space |
| `AzureLoadBalancer` | Azure infrastructure health probes |
| `Storage` | Azure Storage endpoints |
| `AzureActiveDirectory` | Azure AD endpoints |

---

## Application Security Groups (ASGs)

ASGs allow you to group VMs logically and apply NSG rules to the group — rather than to specific IPs. This simplifies rule management as VMs scale.

```
ASG: asg-webservers → NSG Rule: Allow 443 from Internet to asg-webservers
ASG: asg-appservers → NSG Rule: Allow 8080 from asg-webservers to asg-appservers
ASG: asg-dbservers  → NSG Rule: Allow 5432 from asg-appservers to asg-dbservers
```

---

## VNet Peering

Connects two VNets (same or different regions) with low-latency, high-bandwidth traffic over Microsoft backbone.

- **Local Peering:** Same region, very low latency
- **Global Peering:** Cross-region, slightly higher latency
- Traffic does NOT flow through internet; stays on Microsoft network

---

## Azure Bastion

A managed PaaS service for secure RDP/SSH access to VMs without exposing public IPs.

- Requires a dedicated subnet named `AzureBastionSubnet` with `/27` minimum
- Connects via browser-based client (no client software needed)
- Logs sessions to Azure Monitor

> **Lab note:** Azure Bastion is not deployed in this hands-on lab to keep deployment time short (~2 min vs ~15 min). To access VMs for troubleshooting, use Azure Cloud Shell or enable JIT VM Access in Microsoft Defender for Cloud.

---

## Key CLI Commands

### Linux / macOS (Azure CLI)

```bash
# Create resource group
az group create --name rg-network --location eastus

# Create VNet
az network vnet create \
  --resource-group rg-network \
  --name vnet-cloudinn \
  --address-prefix 10.0.0.0/16 \
  --location eastus

# Create subnet
az network vnet subnet create \
  --resource-group rg-network \
  --vnet-name vnet-cloudinn \
  --name subnet-web \
  --address-prefix 10.0.1.0/24

# Create NSG
az network nsg create \
  --resource-group rg-network \
  --name nsg-web

# Add NSG rule - allow HTTPS
az network nsg rule create \
  --resource-group rg-network \
  --nsg-name nsg-web \
  --name allow-https \
  --priority 100 \
  --protocol Tcp \
  --destination-port-range 443 \
  --access Allow \
  --direction Inbound

# Associate NSG with subnet
az network vnet subnet update \
  --resource-group rg-network \
  --vnet-name vnet-cloudinn \
  --name subnet-web \
  --network-security-group nsg-web

# List VNets
az network vnet list --resource-group rg-network --output table
```

### Windows (PowerShell)

```powershell
# Create resource group
New-AzResourceGroup -Name "rg-network" -Location "eastus"

# Create VNet with subnet
$subnetConfig = New-AzVirtualNetworkSubnetConfig `
  -Name "subnet-web" `
  -AddressPrefix "10.0.1.0/24"

New-AzVirtualNetwork `
  -ResourceGroupName "rg-network" `
  -Location "eastus" `
  -Name "vnet-cloudinn" `
  -AddressPrefix "10.0.0.0/16" `
  -Subnet $subnetConfig

# Create NSG with rule
$nsgRule = New-AzNetworkSecurityRuleConfig `
  -Name "allow-https" `
  -Protocol Tcp `
  -Direction Inbound `
  -Priority 100 `
  -SourceAddressPrefix * `
  -SourcePortRange * `
  -DestinationAddressPrefix * `
  -DestinationPortRange 443 `
  -Access Allow

New-AzNetworkSecurityGroup `
  -ResourceGroupName "rg-network" `
  -Location "eastus" `
  -Name "nsg-web" `
  -SecurityRules $nsgRule

# List VNets
Get-AzVirtualNetwork -ResourceGroupName "rg-network" | Select-Object Name, Location
```
