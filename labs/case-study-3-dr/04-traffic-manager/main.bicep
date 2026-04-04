// Case Study 3 - Step 4: Traffic Manager for Azure dual-region DR failover
// Routes traffic between East US (primary) and East US 2 (DR standby)

@description('Company prefix for unique DNS naming')
param companyPrefix string = 'cloudinn'

@description('Unique suffix for Traffic Manager DNS name')
param uniqueSuffix string = uniqueString(resourceGroup().id)

@description('Azure Load Balancer public IP resource ID in East US (primary)')
param primaryPublicIpId string

@description('Azure Load Balancer public IP resource ID in East US 2 (DR standby)')
param drPublicIpId string

@description('TTL in seconds - lower = faster failover but more DNS queries')
@minValue(10)
@maxValue(300)
param dnsTtl int = 30

@description('Health probe path')
param probePath string = '/health'

// ─── Traffic Manager Profile ──────────────────────────────────────────────────

resource tmProfile 'Microsoft.Network/trafficManagerProfiles@2022-04-01' = {
  name: 'tm-${companyPrefix}-dr'
  location: 'global'
  tags: {
    purpose: 'azure-dual-region-disaster-recovery'
    primaryRegion: 'East US'
    drRegion: 'East US 2'
    managedBy: 'bicep'
  }
  properties: {
    profileStatus: 'Enabled'
    trafficRoutingMethod: 'Priority'
    dnsConfig: {
      relativeName: '${companyPrefix}-global-${uniqueSuffix}'
      ttl: dnsTtl
    }
    monitorConfig: {
      protocol: 'HTTPS'
      port: 443
      path: probePath
      intervalInSeconds: 10
      timeoutInSeconds: 5
      // 2 consecutive failures before marking unhealthy (~20-30s detection)
      toleratedNumberOfFailures: 2
    }
    endpoints: [
      {
        // East US primary — receives all traffic when healthy
        name: 'endpoint-eastus-primary'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: primaryPublicIpId
          endpointStatus: 'Enabled'
          priority: 1
        }
      }
      {
        // East US 2 DR standby — receives traffic only if primary fails
        name: 'endpoint-eastus2-dr'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: drPublicIpId
          endpointStatus: 'Enabled'
          priority: 2
        }
      }
    ]
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output trafficManagerFqdn string = tmProfile.properties.dnsConfig.fqdn
output trafficManagerId string = tmProfile.id
output trafficManagerProfileStatus string = tmProfile.properties.profileStatus
