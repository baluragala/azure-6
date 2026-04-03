// Case Study 4 - Step 1: DNS Zones for ShopEasy e-commerce
// Deploys public and private DNS zones with multi-tier resolution
// Regions: East US (primary) and East US 2 (DR/secondary) only

@description('Your public domain name (must be registered)')
param domainName string = 'shopeasy.example.com'

@description('Environment name')
param environment string = 'prod'

@description('VNet ID for private DNS zone linking')
param vnetId string

@description('VNet ID for East US 2 VNet (optional secondary link)')
param eastUs2VnetId string = ''

@description('Load balancer IP for main website (East US)')
param lbPublicIp string

@description('IP of East US app servers (primary)')
param eastUsLbIp string = '20.10.5.100'

@description('IP of East US 2 app servers (DR / secondary)')
param eastUs2LbIp string = '20.40.5.100'

// ─── Public DNS Zone (internet-facing) ───────────────────────────────────────

resource publicZone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: domainName
  location: 'global'
  tags: {
    environment: environment
    tier: 'public'
    purpose: 'ecommerce'
  }
  properties: {
    zoneType: 'Public'
  }
}

// Apex domain → Load balancer (East US primary)
resource apexRecord 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: publicZone
  name: '@'
  properties: {
    TTL: 300
    ARecords: [
      {
        ipv4Address: lbPublicIp
      }
    ]
  }
}

// www subdomain → primary region
resource wwwRecord 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: publicZone
  name: 'www'
  properties: {
    TTL: 300
    ARecords: [
      {
        ipv4Address: lbPublicIp
      }
    ]
  }
}

// East US primary subdomain
resource usRecord 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: publicZone
  name: 'us'
  properties: {
    TTL: 60
    ARecords: [
      {
        ipv4Address: eastUsLbIp
      }
    ]
  }
}

// East US 2 DR subdomain (secondary endpoint)
resource drRecord 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: publicZone
  name: 'dr'
  properties: {
    TTL: 60
    ARecords: [
      {
        ipv4Address: eastUs2LbIp
      }
    ]
  }
}

// API subdomain → CNAME to API gateway
resource apiRecord 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: publicZone
  name: 'api'
  properties: {
    TTL: 300
    CNAMERecord: {
      cname: 'api-gw.${domainName}'
    }
  }
}

// CDN subdomain
resource cdnRecord 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: publicZone
  name: 'cdn'
  properties: {
    TTL: 3600
    CNAMERecord: {
      // Replace with your Azure CDN endpoint
      cname: 'shopeasy.azureedge.net'
    }
  }
}

// Mail records
resource mxRecord 'Microsoft.Network/dnsZones/MX@2018-05-01' = {
  parent: publicZone
  name: '@'
  properties: {
    TTL: 3600
    MXRecords: [
      {
        preference: 10
        exchange: 'mail.protection.outlook.com'
      }
    ]
  }
}

// SPF record for email authentication
resource spfRecord 'Microsoft.Network/dnsZones/TXT@2018-05-01' = {
  parent: publicZone
  name: '@'
  properties: {
    TTL: 3600
    TXTRecords: [
      {
        value: ['v=spf1 include:spf.protection.outlook.com -all']
      }
    ]
  }
}

// CAA record (limits which CAs can issue SSL certs for this domain)
resource caaRecord 'Microsoft.Network/dnsZones/CAA@2018-05-01' = {
  parent: publicZone
  name: '@'
  properties: {
    TTL: 3600
    caaRecords: [
      {
        flags: 0
        tag: 'issue'
        value: 'letsencrypt.org'
      }
      {
        flags: 0
        tag: 'issue'
        value: 'digicert.com'
      }
      {
        flags: 0
        tag: 'iodef'
        value: 'mailto:security@shopeasy.example.com'
      }
    ]
  }
}

// Backup NS records (manual DNS failover)
resource backupNsRecord 'Microsoft.Network/dnsZones/NS@2018-05-01' = {
  parent: publicZone
  name: 'backup'
  properties: {
    TTL: 3600
    NSRecords: [
      {
        nsdname: 'ns1.backup-dns.shopeasy.example.com'
      }
      {
        nsdname: 'ns2.backup-dns.shopeasy.example.com'
      }
    ]
  }
}

// ─── Private DNS Zone (internal corporate services) ───────────────────────────

resource privateZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'corp.shopeasy.internal'
  location: 'global'
  tags: {
    environment: environment
    tier: 'private'
  }
}

// Link to primary VNet (East US)
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateZone
  name: 'link-shopeasy-vnet-eastus'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: true
  }
}

// Link to East US 2 VNet if provided
resource eastUs2VnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (!empty(eastUs2VnetId)) {
  parent: privateZone
  name: 'link-shopeasy-vnet-eastus2'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: eastUs2VnetId
    }
    registrationEnabled: false
  }
}

// Internal service records
resource orderServiceRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateZone
  name: 'order-service'
  properties: {
    ttl: 60
    aRecords: [
      {
        ipv4Address: '10.0.2.10'
      }
    ]
  }
}

resource productServiceRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateZone
  name: 'product-service'
  properties: {
    ttl: 60
    aRecords: [
      {
        ipv4Address: '10.0.2.11'
      }
    ]
  }
}

resource dbMasterRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateZone
  name: 'db-master'
  properties: {
    ttl: 30
    aRecords: [
      {
        ipv4Address: '10.0.3.4'
      }
    ]
  }
}

resource dbReplicaRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateZone
  name: 'db-replica'
  properties: {
    ttl: 30
    aRecords: [
      {
        ipv4Address: '10.0.3.5'
      }
    ]
  }
}

resource redisRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateZone
  name: 'redis'
  properties: {
    ttl: 60
    aRecords: [
      {
        ipv4Address: '10.0.2.20'
      }
    ]
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output publicZoneId string = publicZone.id
output publicZoneName string = publicZone.name
output nameServers array = publicZone.properties.nameServers
output privateZoneId string = privateZone.id
output privateZoneName string = privateZone.name

output instructionsForRegistrar string = 'Log into your domain registrar and update NS records to: ${join(publicZone.properties.nameServers, ', ')}'
