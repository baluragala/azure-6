// Case Study 4 - Step 2: Traffic Manager with Geographic and Performance Routing
// Implements geo-based DNS routing for global ShopEasy e-commerce

@description('Domain name prefix for Traffic Manager')
param companyPrefix string = 'shopeasy'

@description('East US load balancer resource ID')
param eastUsPublicIpId string

@description('West Europe load balancer resource ID')
param westEuropePublicIpId string

@description('Southeast Asia load balancer resource ID')
param seAsiaPublicIpId string

@description('DNS TTL in seconds')
@minValue(10)
@maxValue(300)
param dnsTtl int = 60

// ─── Geographic Routing Profile ───────────────────────────────────────────────
// Routes users to their nearest regional endpoint based on location

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
          // WORLD covers any unmatched regions (acts as fallback)
          geoMapping: ['GEO-NA', 'GEO-SA']
        }
      }
      {
        name: 'endpoint-west-europe'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: westEuropePublicIpId
          endpointStatus: 'Enabled'
          geoMapping: ['GEO-EU', 'GEO-AF', 'GEO-ME']
        }
      }
      {
        name: 'endpoint-sea'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: seAsiaPublicIpId
          endpointStatus: 'Enabled'
          geoMapping: ['GEO-AP']
        }
      }
    ]
  }
}

// ─── Performance Routing Profile ──────────────────────────────────────────────
// Routes users to the lowest-latency endpoint (independently of geography)

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
        name: 'endpoint-west-europe'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: westEuropePublicIpId
          endpointStatus: 'Enabled'
        }
      }
      {
        name: 'endpoint-sea'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: seAsiaPublicIpId
          endpointStatus: 'Enabled'
        }
      }
    ]
  }
}

// ─── Nested Profile: Priority Failover within each region ─────────────────────
// East US primary → West Europe secondary (if entire US region goes down)

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
        name: 'fallback-west-europe'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: westEuropePublicIpId
          endpointStatus: 'Enabled'
          priority: 2
        }
      }
      {
        name: 'fallback-sea'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: seAsiaPublicIpId
          endpointStatus: 'Enabled'
          priority: 3
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
  geoRouting: 'nslookup ${tmGeoProfile.properties.dnsConfig.fqdn} - routes by geography'
  perfRouting: 'nslookup ${tmPerfProfile.properties.dnsConfig.fqdn} - routes by latency'
  failoverTest: [
    'Step 1: Disable East US endpoint in tm-${companyPrefix}-failover'
    'Step 2: nslookup ${tmFailoverProfile.properties.dnsConfig.fqdn} → should return Europe IP'
    'Step 3: Re-enable East US endpoint'
    'Step 4: nslookup again → should return East US IP'
  ]
}
