// Case Study 1 - Step 2: DNS Zones for DR failover
// Creates Azure DNS zones for internal name resolution during failover

@description('Azure region for deployment')
param location string = resourceGroup().location

@description('Environment name')
param environment string = 'prod'

@description('VNet resource ID to link private DNS zone')
param vnetId string

@description('Private DNS zone name for internal services')
param privateDnsZoneName string = 'internal.cloudinn.azure'

@description('Public DNS zone name (requires domain ownership)')
param publicDnsZoneName string = 'cloudinn-dr.example.com'

// ─── Public DNS Zone ──────────────────────────────────────────────────────────
// NOTE: After deploying, update NS records at your domain registrar
// with the name servers shown in the outputs

resource publicDnsZone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: publicDnsZoneName
  location: 'global'
  tags: {
    environment: environment
    purpose: 'disaster-recovery'
  }
  properties: {
    zoneType: 'Public'
  }
}

// Health check endpoint record (used by Traffic Manager probes)
resource healthRecord 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: publicDnsZone
  name: 'health'
  properties: {
    TTL: 60
    ARecords: [
      {
        // Placeholder - will be updated after VM deployment
        ipv4Address: '10.0.1.4'
      }
    ]
  }
}

// ─── Private DNS Zone ─────────────────────────────────────────────────────────

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: {
    environment: environment
    purpose: 'disaster-recovery-internal'
  }
}

// Link private zone to the VNet with auto-registration
// Auto-registration automatically adds A records for VMs in the VNet
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'link-cloudinn-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    // Auto-register VMs in this zone when they're created in the linked VNet
    registrationEnabled: true
  }
}

// Pre-defined internal records for key services
resource dbRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: 'db-primary'
  properties: {
    ttl: 300
    aRecords: [
      {
        // DB VM IP in subnet-db (10.0.3.0/24)
        ipv4Address: '10.0.3.4'
      }
    ]
  }
}

resource cacheRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: 'cache'
  properties: {
    ttl: 60
    aRecords: [
      {
        ipv4Address: '10.0.2.10'
      }
    ]
  }
}

resource apiRecord 'Microsoft.Network/privateDnsZones/CNAME@2020-06-01' = {
  parent: privateDnsZone
  name: 'api'
  properties: {
    ttl: 300
    cnameRecord: {
      cname: 'app-server.${privateDnsZoneName}'
    }
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output publicZoneId string = publicDnsZone.id
output publicZoneName string = publicDnsZone.name
output publicZoneNameServers array = publicDnsZone.properties.nameServers
output privateZoneId string = privateDnsZone.id
output privateZoneName string = privateDnsZone.name
output vnetLinkId string = vnetLink.id
