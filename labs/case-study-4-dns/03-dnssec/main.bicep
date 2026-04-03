// Case Study 4 - Step 3: DNSSEC Configuration
// Enables DNSSEC on the public DNS zone for shopeasy.example.com
//
// NOTE: Azure DNS DNSSEC is generally available for public zones.
// The DNS zone must already exist before enabling DNSSEC.
//
// After deployment, you MUST:
// 1. Retrieve the DS record from Azure
// 2. Add the DS record to your parent zone at the domain registrar
// 3. This creates the chain of trust

@description('Name of the existing DNS zone to enable DNSSEC on')
param dnsZoneName string = 'shopeasy.example.com'

@description('Resource group containing the DNS zone')
param dnsZoneResourceGroup string = resourceGroup().name

// ─── DNSSEC Configuration ─────────────────────────────────────────────────────

resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
}

// Enable DNSSEC on the zone
// This generates key pairs (ZSK - Zone Signing Key) and signs all records
resource dnssec 'Microsoft.Network/dnsZones/dnssecConfigs@2023-07-01-preview' = {
  parent: dnsZone
  name: 'default'
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output dnssecConfigId string = dnssec.id
output dnssecState string = dnssec.properties.provisioningState

output nextSteps object = {
  step1: 'Wait for DNSSEC provisioning to complete (check Azure portal)'
  step2: 'Retrieve DS records: az network dns dnssec-config show --resource-group ${dnsZoneResourceGroup} --zone-name ${dnsZoneName}'
  step3: 'Log into your domain registrar and add the DS record to the parent zone (.com or .net etc.)'
  step4: 'Verify DNSSEC chain of trust: dig +dnssec ${dnsZoneName} SOA'
  step5: 'Use online checker: https://dnsviz.net or https://dnssec-analyzer.verisignlabs.com'
  warning: 'If DS record is not added to parent zone within the TTL, DNSSEC validation will FAIL for all users with validating resolvers'
}
