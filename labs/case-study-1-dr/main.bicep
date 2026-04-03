// Case Study 1: Azure Dual-Region Disaster Recovery
// Primary: East US  |  DR Standby: East US 2
// Master orchestration template - deploys all components in order

targetScope = 'subscription'

@description('Primary Azure region')
@allowed(['eastus', 'eastus2'])
param locationPrimary string = 'eastus'

@description('DR standby Azure region')
@allowed(['eastus', 'eastus2'])
param locationDr string = 'eastus2'

@description('Environment name')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

@description('Company prefix for resource naming')
param companyPrefix string = 'cloudinn'

@description('VM admin username')
param adminUsername string = 'azureadmin'

@description('VM admin password')
@secure()
param adminPassword string

// ─── Resource Groups ──────────────────────────────────────────────────────────

resource rgPrimary 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${companyPrefix}-primary-${environment}'
  location: locationPrimary
  tags: {
    environment: environment
    role: 'primary'
    region: locationPrimary
    purpose: 'disaster-recovery'
    caseStudy: 'azure-dual-region-dr'
  }
}

resource rgDr 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${companyPrefix}-dr-${environment}'
  location: locationDr
  tags: {
    environment: environment
    role: 'dr-standby'
    region: locationDr
    purpose: 'disaster-recovery'
    caseStudy: 'azure-dual-region-dr'
  }
}

// ─── PRIMARY REGION: East US ──────────────────────────────────────────────────

module vnetPrimary './01-vnet/main.bicep' = {
  name: 'deploy-vnet-primary'
  scope: rgPrimary
  params: {
    location: locationPrimary
    environment: environment
    companyPrefix: companyPrefix
  }
}

module dnsPrimary './02-dns/main.bicep' = {
  name: 'deploy-dns-primary'
  scope: rgPrimary
  dependsOn: [vnetPrimary]
  params: {
    location: locationPrimary
    environment: environment
    vnetId: vnetPrimary.outputs.vnetId
    privateDnsZoneName: 'internal.${companyPrefix}.azure'
    publicDnsZoneName: '${companyPrefix}-app.example.com'
  }
}

module infraPrimary './03-arm-templates/main.bicep' = {
  name: 'deploy-infra-primary'
  scope: rgPrimary
  dependsOn: [vnetPrimary]
  params: {
    location: locationPrimary
    environment: environment
    subnetWebId: vnetPrimary.outputs.subnetWebId
    subnetAppId: vnetPrimary.outputs.subnetAppId
    subnetDbId: vnetPrimary.outputs.subnetDbId
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
}

// ─── DR REGION: East US 2 ─────────────────────────────────────────────────────

module vnetDr './01-vnet/main.bicep' = {
  name: 'deploy-vnet-dr'
  scope: rgDr
  params: {
    location: locationDr
    environment: environment
    companyPrefix: companyPrefix
  }
}

module infraDr './03-arm-templates/main.bicep' = {
  name: 'deploy-infra-dr'
  scope: rgDr
  dependsOn: [vnetDr]
  params: {
    location: locationDr
    environment: environment
    subnetWebId: vnetDr.outputs.subnetWebId
    subnetAppId: vnetDr.outputs.subnetAppId
    subnetDbId: vnetDr.outputs.subnetDbId
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
}

// ─── TRAFFIC MANAGER: Priority routing East US → East US 2 ───────────────────
// Lives in primary resource group (global resource)

module trafficManager './04-traffic-manager/main.bicep' = {
  name: 'deploy-traffic-manager'
  scope: rgPrimary
  dependsOn: [infraPrimary, infraDr]
  params: {
    companyPrefix: companyPrefix
    primaryPublicIpId: infraPrimary.outputs.lbPublicIpId
    drPublicIpId: infraDr.outputs.lbPublicIpId
    dnsTtl: 30
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output primaryResourceGroup string = rgPrimary.name
output drResourceGroup string = rgDr.name

output primaryVnetId string = vnetPrimary.outputs.vnetId
output drVnetId string = vnetDr.outputs.vnetId

output primaryLbIp string = infraPrimary.outputs.lbPublicIp
output primaryLbFqdn string = infraPrimary.outputs.lbPublicFqdn

output drLbIp string = infraDr.outputs.lbPublicIp
output drLbFqdn string = infraDr.outputs.lbPublicFqdn

output trafficManagerFqdn string = trafficManager.outputs.trafficManagerFqdn
output dnsNameServers array = dnsPrimary.outputs.publicZoneNameServers

output deploymentSummary object = {
  architecture: 'Azure Dual-Region Active-Passive DR'
  primaryRegion: locationPrimary
  drRegion: locationDr
  vnetAddressSpace: '10.0.0.0/16 (same CIDR in both regions)'
  subnets: ['subnet-web (10.0.1.0/24)', 'subnet-app (10.0.2.0/24)', 'subnet-db (10.0.3.0/24)']
  trafficManagerFqdn: trafficManager.outputs.trafficManagerFqdn
  primaryLbIp: infraPrimary.outputs.lbPublicIp
  drLbIp: infraDr.outputs.lbPublicIp
  instructions: [
    '1. Update NS records at registrar with: ${dnsPrimary.outputs.publicZoneNameServers}'
    '2. Test normal: nslookup ${trafficManager.outputs.trafficManagerFqdn} → should return East US IP'
    '3. Test failover: Disable endpoint-eastus-primary in Traffic Manager'
    '4. Re-run nslookup → should return East US 2 IP'
    '5. Re-enable endpoint-eastus-primary to fail back'
  ]
}
