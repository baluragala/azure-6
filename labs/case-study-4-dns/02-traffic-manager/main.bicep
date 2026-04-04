// Case Study 4 - Step 2: Traffic Manager with Geographic and Performance Routing
// Implements DNS routing for ShopEasy e-commerce across two allowed Azure regions:
//   - East US   (primary)
//   - East US 2 (DR / secondary)

@description('Domain name prefix for Traffic Manager')
param companyPrefix string = 'shopeasy'

@description('East US load balancer resource ID (primary)')
param eastUsPublicIpId string

@description('East US 2 load balancer resource ID (DR / secondary)')
param eastUs2PublicIpId string

@description('DNS TTL in seconds')
@minValue(10)
@maxValue(300)
param dnsTtl int = 60

// ─── Geographic Routing Profile ───────────────────────────────────────────────
// Routes users based on geography. With two endpoints:
//   - East US  : North/South America (nearest region)
//   - East US 2: WORLD (all other regions — Europe, Asia, etc.)

resource tmGeoProfile 'Microsoft.Network/trafficManagerProfiles@2022-04-01' = {
  name: 'tm-${companyPrefix}-geo'
  location: 'global'
  tags: {
    purpose: 'geo-routing'
    company: companyPrefix
  }
  properties: {
    profileStatus: 'Enabled'
    trafficRoutingMethod: 'Geographic'
    dnsConfig: {
      relativeName: '${companyPrefix}-geo-${uniqueString(resourceGroup().id)}'
      ttl: dnsTtl
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/health'
      intervalInSeconds: 30
      timeoutInSeconds: 10
      toleratedNumberOfFailures: 3
    }
    endpoints: [
      {
        name: 'endpoint-east-us'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: eastUsPublicIpId
          endpointStatus: 'Enabled'
          // North + South America → East US
          geoMapping: ['GEO-NA', 'GEO-SA']
        }
      }
      {
        name: 'endpoint-east-us2'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: eastUs2PublicIpId
          endpointStatus: 'Enabled'
          // WORLD = all unmatched regions (Europe, Asia, Africa, etc.)
          geoMapping: ['WORLD']
        }
      }
    ]
  }
}

// ─── Performance Routing Profile ──────────────────────────────────────────────
// Routes users to the lowest-latency endpoint (measured in real-time by Azure)

resource tmPerfProfile 'Microsoft.Network/trafficManagerProfiles@2022-04-01' = {
  name: 'tm-${companyPrefix}-perf'
  location: 'global'
  tags: {
    purpose: 'performance-routing'
    company: companyPrefix
  }
  properties: {
    profileStatus: 'Enabled'
    trafficRoutingMethod: 'Performance'
    dnsConfig: {
      relativeName: '${companyPrefix}-perf-${uniqueString(resourceGroup().id)}'
      ttl: dnsTtl
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/health'
      intervalInSeconds: 30
      timeoutInSeconds: 10
      toleratedNumberOfFailures: 3
    }
    endpoints: [
      {
        name: 'endpoint-east-us'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: eastUsPublicIpId
          endpointStatus: 'Enabled'
        }
      }
      {
        name: 'endpoint-east-us2'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: eastUs2PublicIpId
          endpointStatus: 'Enabled'
        }
      }
    ]
  }
}

// ─── Priority Failover Profile ────────────────────────────────────────────────
// East US primary (P1) → East US 2 DR standby (P2)
// Mirrors the DR strategy from Case Study 3

resource tmFailoverProfile 'Microsoft.Network/trafficManagerProfiles@2022-04-01' = {
  name: 'tm-${companyPrefix}-failover'
  location: 'global'
  tags: {
    purpose: 'regional-failover'
  }
  properties: {
    profileStatus: 'Enabled'
    trafficRoutingMethod: 'Priority'
    dnsConfig: {
      relativeName: '${companyPrefix}-failover-${uniqueString(resourceGroup().id)}'
      ttl: 30
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: '/health'
      intervalInSeconds: 10
      timeoutInSeconds: 5
      toleratedNumberOfFailures: 2
    }
    endpoints: [
      {
        name: 'primary-east-us'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: eastUsPublicIpId
          endpointStatus: 'Enabled'
          priority: 1
        }
      }
      {
        name: 'fallback-east-us2'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: eastUs2PublicIpId
          endpointStatus: 'Enabled'
          priority: 2
        }
      }
    ]
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output geoProfileFqdn string = tmGeoProfile.properties.dnsConfig.fqdn
output perfProfileFqdn string = tmPerfProfile.properties.dnsConfig.fqdn
output failoverProfileFqdn string = tmFailoverProfile.properties.dnsConfig.fqdn

output testInstructions object = {
  geoRouting: 'nslookup ${tmGeoProfile.properties.dnsConfig.fqdn} - routes by geography (NA/SA → East US, WORLD → East US 2)'
  perfRouting: 'nslookup ${tmPerfProfile.properties.dnsConfig.fqdn} - routes to lowest-latency endpoint'
  failoverTest: [
    'Step 1: Disable East US endpoint in tm-${companyPrefix}-failover'
    'Step 2: nslookup ${tmFailoverProfile.properties.dnsConfig.fqdn} → should return East US 2 IP'
    'Step 3: Re-enable East US endpoint'
    'Step 4: nslookup again → should return East US IP'
  ]
}
