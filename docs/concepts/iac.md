# Infrastructure as Code: ARM Templates & Bicep

## Why Infrastructure as Code (IaC)?

| Manual Deployment | IaC Deployment |
|-------------------|----------------|
| Error-prone, hard to repeat | Repeatable, consistent |
| No version history | Full version control (Git) |
| Slow (clicks in portal) | Fast (automated) |
| Hard to audit | Auditable, declarative |
| Difficult DR | DR = re-run the template |

---

## ARM Templates

**Azure Resource Manager (ARM) templates** are JSON files that declare the desired state of Azure resources. ARM is Azure's deployment and management layer — every Azure operation goes through ARM.

### Template Structure

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    // Input values provided at deployment time
  },
  "variables": {
    // Derived values computed from parameters
  },
  "resources": [
    // Azure resources to deploy
  ],
  "outputs": {
    // Values returned after deployment
  }
}
```

### ARM vs Bicep Comparison

| Feature | ARM JSON | Bicep |
|---------|----------|-------|
| Syntax | Verbose JSON | Clean DSL (domain-specific language) |
| Learning curve | Steep | Gentle |
| Compiles to | Itself (JSON) | ARM JSON |
| IDE support | Basic | Excellent (VS Code extension) |
| Modularity | Linked templates | Modules |
| Type safety | Limited | Strong |
| Comments | Not supported | Supported |
| Azure support | Full | Full (transpiles to ARM) |

---

## Bicep

Bicep is a **transparent abstraction** over ARM templates. It compiles to ARM JSON and has first-class support from Microsoft.

### Bicep Syntax Example

```bicep
// Variables
var location = resourceGroup().location
var prefix = 'cloudinn'

// Parameter with constraint
@description('Environment name')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

// Resource declaration
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: '${prefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
  }
}

// Output
output vnetId string = vnet.id
```

### Bicep Modules

Modules enable you to split Bicep code into reusable components:

```bicep
// main.bicep
module vnetModule './modules/vnet.bicep' = {
  name: 'vnetDeployment'
  params: {
    vnetName: 'vnet-cloudinn'
    location: location
    addressPrefix: '10.0.0.0/16'
  }
}

// Use module output
output deployedVnetId string = vnetModule.outputs.vnetId
```

---

## Bicep CLI Commands

### Linux / macOS (Azure CLI)

```bash
# Install / upgrade Bicep
az bicep install
az bicep upgrade

# Check version
az bicep version

# Compile Bicep to ARM JSON (for inspection/review)
az bicep build --file main.bicep

# Decompile ARM JSON to Bicep (for existing templates)
az bicep decompile --file existing-template.json

# Deploy Bicep file
az deployment group create \
  --resource-group rg-cloudinn \
  --template-file main.bicep \
  --parameters @parameters.json

# Deploy with inline parameters
az deployment group create \
  --resource-group rg-cloudinn \
  --template-file main.bicep \
  --parameters environment=prod location=eastus

# Preview changes (what-if)
az deployment group what-if \
  --resource-group rg-cloudinn \
  --template-file main.bicep \
  --parameters @parameters.json

# Validate template
az deployment group validate \
  --resource-group rg-cloudinn \
  --template-file main.bicep \
  --parameters @parameters.json

# View deployment status
az deployment group show \
  --resource-group rg-cloudinn \
  --name myDeployment \
  --query properties.provisioningState

# List deployments
az deployment group list \
  --resource-group rg-cloudinn \
  --output table
```

### Windows (PowerShell)

```powershell
# Install Bicep via winget
winget install Microsoft.Bicep

# Or via Azure CLI
az bicep install

# Deploy Bicep
New-AzResourceGroupDeployment `
  -ResourceGroupName "rg-cloudinn" `
  -TemplateFile ".\main.bicep" `
  -TemplateParameterFile ".\parameters.json"

# Preview changes (what-if)
New-AzResourceGroupDeployment `
  -ResourceGroupName "rg-cloudinn" `
  -TemplateFile ".\main.bicep" `
  -TemplateParameterFile ".\parameters.json" `
  -WhatIf

# Validate template
Test-AzResourceGroupDeployment `
  -ResourceGroupName "rg-cloudinn" `
  -TemplateFile ".\main.bicep" `
  -TemplateParameterFile ".\parameters.json"

# List deployments
Get-AzResourceGroupDeployment -ResourceGroupName "rg-cloudinn" | Select-Object DeploymentName, ProvisioningState, Timestamp
```

---

## Deployment Modes

| Mode | Behavior |
|------|---------|
| **Incremental** (default) | Adds/updates resources; does NOT delete resources not in template |
| **Complete** | Adds/updates AND deletes resources not in template |

> **Warning:** Use `Complete` mode carefully — it will delete resources in the resource group not defined in the template.

```bash
# Incremental (default)
az deployment group create \
  --resource-group rg-cloudinn \
  --template-file main.bicep \
  --mode Incremental

# Complete mode (destructive!)
az deployment group create \
  --resource-group rg-cloudinn \
  --template-file main.bicep \
  --mode Complete
```
