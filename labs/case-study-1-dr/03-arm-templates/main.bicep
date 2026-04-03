// Case Study 1 - Step 3: Core Application Infrastructure (VM, Storage, SQL)
// ARM-equivalent Bicep template for rapid DR deployment

@description('Azure region')
param location string = resourceGroup().location

@description('Environment name')
param environment string = 'prod'

@description('Subnet ID for web tier VMs')
param subnetWebId string

@description('Subnet ID for app tier VMs')
param subnetAppId string

@description('Subnet ID for database tier')
param subnetDbId string

@description('Admin username for VMs')
param adminUsername string = 'azureadmin'

@description('Admin password for VMs (use Key Vault in production)')
@secure()
param adminPassword string

@description('VM size for web and app tier')
@allowed(['Standard_B2ms', 'Standard_B1ms', 'Standard_B4ms', 'Standard_D2_v3', 'Standard_DS1_v2'])
param vmSize string = 'Standard_B2ms'

@description('Storage account SKU')
@allowed(['Standard_LRS', 'Premium_LRS'])
param storageSkuName string = 'Standard_LRS'

// ─── Variables ────────────────────────────────────────────────────────────────

var prefix = 'cloudinn-${environment}'
var webVmName = 'vm-web-${environment}'
var appVmName = 'vm-app-${environment}'
var storageAccountName = 'stcloudinn${uniqueString(resourceGroup().id)}'
var lbName = 'lb-web-${environment}'
var lbPipName = 'pip-lb-${environment}'

// ─── Storage Account ──────────────────────────────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: storageSkuName
  }
  tags: {
    environment: environment
    purpose: 'disaster-recovery'
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    encryption: {
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource appDataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'app-data'
  properties: {
    publicAccess: 'None'
  }
}

// ─── Load Balancer ────────────────────────────────────────────────────────────

resource lbPip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: lbPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${prefix}-lb'
    }
  }
}

resource lb 'Microsoft.Network/loadBalancers@2023-04-01' = {
  name: lbName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend'
        properties: {
          publicIPAddress: {
            id: lbPip.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'web-backend-pool'
      }
    ]
    probes: [
      {
        name: 'https-probe'
        properties: {
          protocol: 'Https'
          port: 443
          requestPath: '/health'
          intervalInSeconds: 15
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'https-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'web-backend-pool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'https-probe')
          }
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

// ─── Web Tier VM ──────────────────────────────────────────────────────────────

resource webVmNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'nic-${webVmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig-web'
        properties: {
          subnet: {
            id: subnetWebId
          }
          privateIPAllocationMethod: 'Dynamic'
          loadBalancerBackendAddressPools: [
            {
              id: '${lb.id}/backendAddressPools/web-backend-pool'
            }
          ]
        }
      }
    ]
  }
}

resource webVm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: webVmName
  location: location
  tags: {
    tier: 'web'
    environment: environment
    role: 'disaster-recovery'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: webVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: webVmNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// Nginx install via custom script extension
resource webVmExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  parent: webVm
  name: 'install-nginx'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      script: base64('''#!/bin/bash
apt-get update -y
apt-get install -y nginx
cat > /etc/nginx/sites-available/default << 'NGINX'
server {
    listen 80;
    server_name _;
    location /health {
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
    location / {
        return 200 "CloudInnovate DR - Azure Failover Active\n";
        add_header Content-Type text/plain;
    }
}
NGINX
systemctl enable nginx
systemctl restart nginx
''')
    }
  }
}

// ─── App Tier VM ──────────────────────────────────────────────────────────────

resource appVmNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'nic-${appVmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig-app'
        properties: {
          subnet: {
            id: subnetAppId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.2.4'
        }
      }
    ]
  }
}

resource appVm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: appVmName
  location: location
  tags: {
    tier: 'app'
    environment: environment
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: appVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: appVmNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

// ─── Azure SQL Database ───────────────────────────────────────────────────────

resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: 'sql-${prefix}-${uniqueString(resourceGroup().id)}'
  location: location
  tags: {
    environment: environment
    tier: 'database'
  }
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent: sqlServer
  name: 'db-cloudinn-${environment}'
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648
    requestedBackupStorageRedundancy: 'Local'
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output lbPublicIpId string = lbPip.id
output lbPublicIp string = lbPip.properties.ipAddress
output lbPublicFqdn string = lbPip.properties.dnsSettings.fqdn
output webVmName string = webVm.name
output appVmName string = appVm.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
