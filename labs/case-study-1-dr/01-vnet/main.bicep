// Case Study 1 - Step 1: Virtual Network deployment
// Deploys a VNet with 3-tier subnet layout for DR failover

@description('Azure region for deployment')
param location string = resourceGroup().location

@description('Environment (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

@description('Company prefix for resource naming')
param companyPrefix string = 'cloudinn'

// ─── Variables ────────────────────────────────────────────────────────────────

var vnetName = '${companyPrefix}-vnet-${environment}'
var nsgWebName = 'nsg-web-${environment}'
var nsgAppName = 'nsg-app-${environment}'
var nsgDbName = 'nsg-db-${environment}'

var addressSpace = '10.0.0.0/16'
var subnets = {
  web: '10.0.1.0/24'
  app: '10.0.2.0/24'
  db: '10.0.3.0/24'
  gateway: '10.0.4.0/27'
}

// ─── NSGs ─────────────────────────────────────────────────────────────────────

resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgWebName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-https-inbound'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: subnets.web
          destinationPortRange: '443'
          description: 'Allow HTTPS from internet to web tier'
        }
      }
      {
        name: 'allow-http-inbound'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: subnets.web
          destinationPortRange: '80'
          description: 'Allow HTTP (redirect to HTTPS)'
        }
      }
      {
        name: 'deny-all-inbound'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all other inbound'
        }
      }
    ]
  }
}

resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgAppName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-web-to-app'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: subnets.web
          sourcePortRange: '*'
          destinationAddressPrefix: subnets.app
          destinationPortRange: '8080'
          description: 'Allow web tier to call app tier'
        }
      }
      {
        name: 'deny-internet-inbound'
        properties: {
          priority: 200
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: subnets.app
          destinationPortRange: '*'
          description: 'Block direct internet access to app tier'
        }
      }
    ]
  }
}

resource nsgDb 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgDbName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-app-to-db'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: subnets.app
          sourcePortRange: '*'
          destinationAddressPrefix: subnets.db
          destinationPortRange: '5432'
          description: 'Allow app tier to reach PostgreSQL'
        }
      }
      {
        name: 'deny-all-inbound'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all other inbound to DB tier'
        }
      }
    ]
  }
}

// ─── Virtual Network ──────────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vnetName
  location: location
  tags: {
    environment: environment
    purpose: 'disaster-recovery'
    managedBy: 'bicep'
  }
  properties: {
    addressSpace: {
      addressPrefixes: [addressSpace]
    }
    subnets: [
      {
        name: 'subnet-web'
        properties: {
          addressPrefix: subnets.web
          networkSecurityGroup: {
            id: nsgWeb.id
          }
        }
      }
      {
        name: 'subnet-app'
        properties: {
          addressPrefix: subnets.app
          networkSecurityGroup: {
            id: nsgApp.id
          }
        }
      }
      {
        name: 'subnet-db'
        properties: {
          addressPrefix: subnets.db
          networkSecurityGroup: {
            id: nsgDb.id
          }
        }
      }
      {
        name: 'subnet-gateway'
        properties: {
          addressPrefix: subnets.gateway
        }
      }
    ]
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetWebId string = '${vnet.id}/subnets/subnet-web'
output subnetAppId string = '${vnet.id}/subnets/subnet-app'
output subnetDbId string = '${vnet.id}/subnets/subnet-db'
output nsgWebId string = nsgWeb.id
output nsgAppId string = nsgApp.id
output nsgDbId string = nsgDb.id
