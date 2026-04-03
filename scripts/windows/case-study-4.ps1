#Requires -Version 5.1
# ============================================================
# Case Study 4: Scalable and Secure DNS Management
# Global Enterprise DNS for ShopEasy e-commerce
# Windows PowerShell Version
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ──────────────────────────────────────────────────
function Write-Header { param($msg)
    Write-Host ""; Write-Host "═══════════════════════════════════════" -ForegroundColor Blue
    Write-Host "  $msg" -ForegroundColor Blue
    Write-Host "═══════════════════════════════════════" -ForegroundColor Blue
}
function Write-Step { param($msg) Write-Host "[STEP] $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "[  OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Pause-ForContinue { Write-Host "Press ENTER to continue..." -ForegroundColor Yellow; Read-Host | Out-Null }

# ── Configuration ─────────────────────────────────────────────
$Company        = "shopeasy"
$LocationUS     = "eastus"
$LocationEU     = "westeurope"
$LocationAP     = "southeastasia"
$DomainName     = "shopeasy.example.com"
$RgDns          = "rg-$Company-dns"
$RgUS           = "rg-$Company-us"
$RgEU           = "rg-$Company-eu"
$RgAP           = "rg-$Company-ap"
$LabDir         = Join-Path (Split-Path $PSScriptRoot -Parent) "labs\case-study-4-dns"

$EastUsLbIp     = "20.10.5.100"
$WestEuropeLbIp = "52.174.5.200"
$SeAsiaLbIp     = "20.195.10.50"

# ── Pre-flight ────────────────────────────────────────────────
function Invoke-Preflight {
    Write-Header "Pre-flight Checks"
    try {
        $ctx = Get-AzContext
        if ($null -eq $ctx) { throw "Not logged in" }
        Write-Ok "Logged in: $($ctx.Subscription.Name)"
    }
    catch {
        Connect-AzAccount
    }
}

# ── Step 1: Create Resource Groups ───────────────────────────
function New-LabResourceGroups {
    Write-Header "Step 1: Create Resource Groups"

    $groups = @(
        @{ Name = $RgDns; Location = $LocationUS },
        @{ Name = $RgUS;  Location = $LocationUS },
        @{ Name = $RgEU;  Location = $LocationEU },
        @{ Name = $RgAP;  Location = $LocationAP }
    )

    foreach ($g in $groups) {
        Write-Step "Creating $($g.Name) in $($g.Location)..."
        New-AzResourceGroup -Name $g.Name -Location $g.Location `
            -Tag @{ company = $Company; purpose = "dns-management" } `
            -Force | Out-Null
        Write-Ok "$($g.Name) created"
    }
}

# ── Step 2: Create VNet ───────────────────────────────────────
function New-LabVNet {
    Write-Header "Step 2: Create VNet for Private DNS Linking"

    $subnetConfig = New-AzVirtualNetworkSubnetConfig `
        -Name "subnet-app" `
        -AddressPrefix "10.0.1.0/24"

    $vnet = New-AzVirtualNetwork `
        -ResourceGroupName $RgUS `
        -Location $LocationUS `
        -Name "vnet-$Company-prod" `
        -AddressPrefix "10.0.0.0/16" `
        -Subnet $subnetConfig

    Write-Ok "VNet created: $($vnet.Id)"
    return $vnet
}

# ── Step 3: Deploy DNS Zones ──────────────────────────────────
function Deploy-DnsZones {
    param([string]$VNetId)

    Write-Header "Step 3: Deploy Public & Private DNS Zones"
    Write-Host "  Public: $DomainName" -ForegroundColor Gray
    Write-Host "  Private: corp.$Company.internal" -ForegroundColor Gray

    $deployName = "deploy-dns-$(Get-Date -Format 'yyyyMMddHHmmss')"

    New-AzResourceGroupDeployment `
        -ResourceGroupName $RgDns `
        -Name $deployName `
        -TemplateFile "$LabDir\01-dns-zones\main.bicep" `
        -TemplateParameterFile "$LabDir\01-dns-zones\parameters.json" `
        -vnetId $VNetId `
        -lbPublicIp $EastUsLbIp `
        -eastUsLbIp $EastUsLbIp `
        -westEuropeLbIp $WestEuropeLbIp `
        -seAsiaLbIp $SeAsiaLbIp

    Write-Step "Azure Name Servers (add to domain registrar):"
    $zone = Get-AzDnsZone -ResourceGroupName $RgDns -Name $DomainName
    $zone.NameServers | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }

    Write-Warn "IMPORTANT: Delegate $DomainName to these name servers at your registrar."
    Write-Ok "DNS zones deployed"
}

# ── Step 4: Create Regional Public IPs ───────────────────────
function New-RegionalPublicIPs {
    Write-Header "Step 4: Create Regional Public IP Addresses"

    $pipConfigs = @(
        @{ RG = $RgUS; Name = "pip-lb-us-prod"; Location = $LocationUS },
        @{ RG = $RgEU; Name = "pip-lb-eu-prod"; Location = $LocationEU },
        @{ RG = $RgAP; Name = "pip-lb-ap-prod"; Location = $LocationAP }
    )

    $pips = @{}
    foreach ($cfg in $pipConfigs) {
        Write-Step "Creating $($cfg.Name) in $($cfg.Location)..."
        $pip = New-AzPublicIpAddress `
            -ResourceGroupName $cfg.RG `
            -Name $cfg.Name `
            -Location $cfg.Location `
            -Sku Standard `
            -AllocationMethod Static
        $pips[$cfg.Name] = $pip
        Write-Ok "$($cfg.Name): $($pip.IpAddress)"
    }

    return $pips
}

# ── Step 5: Deploy Traffic Manager ───────────────────────────
function Deploy-TrafficManager {
    param([hashtable]$Pips)

    Write-Header "Step 5: Deploy Traffic Manager Profiles"
    Write-Host "  1. Geographic routing (by region)" -ForegroundColor Gray
    Write-Host "  2. Performance routing (by latency)" -ForegroundColor Gray
    Write-Host "  3. Priority failover" -ForegroundColor Gray

    $usPipId = $Pips["pip-lb-us-prod"].Id
    $euPipId = $Pips["pip-lb-eu-prod"].Id
    $apPipId = $Pips["pip-lb-ap-prod"].Id

    $deployName = "deploy-tm-$(Get-Date -Format 'yyyyMMddHHmmss')"

    New-AzResourceGroupDeployment `
        -ResourceGroupName $RgDns `
        -Name $deployName `
        -TemplateFile "$LabDir\02-traffic-manager\main.bicep" `
        -TemplateParameterFile "$LabDir\02-traffic-manager\parameters.json" `
        -eastUsPublicIpId $usPipId `
        -westEuropePublicIpId $euPipId `
        -seAsiaPublicIpId $apPipId

    Write-Step "Traffic Manager profiles:"
    Get-AzTrafficManagerProfile -ResourceGroupName $RgDns |
        Select-Object Name, TrafficRoutingMethod | Format-Table

    Write-Ok "Traffic Manager deployed"
}

# ── Step 6: Enable DNSSEC ─────────────────────────────────────
function Enable-DnsSec {
    Write-Header "Step 6: Enable DNSSEC"
    Write-Warn "DNSSEC protects $DomainName against spoofing attacks."
    Pause-ForContinue

    # Azure CLI is the most reliable way for DNSSEC (Az module support varies)
    Write-Step "Enabling DNSSEC via Azure CLI..."
    $result = az network dns dnssec-config create `
        --resource-group $RgDns `
        --zone-name $DomainName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "DNSSEC enabled"
    }
    else {
        Write-Warn "DNSSEC is in preview. If the command fails, enable via Azure Portal:"
        Write-Host "  1. Go to Azure Portal → DNS Zones → $DomainName" -ForegroundColor Yellow
        Write-Host "  2. Click 'DNSSEC' in the left menu" -ForegroundColor Yellow
        Write-Host "  3. Click 'Enable DNSSEC'" -ForegroundColor Yellow
    }

    Write-Step "Retrieving DS records (add to registrar for chain of trust)..."
    az network dns dnssec-config show `
        --resource-group $RgDns `
        --zone-name $DomainName `
        --query "signingKeys[].delegationSignerInfo" 2>$null |
        Write-Host
}

# ── Step 7: DNS Failure Simulation ───────────────────────────
function Invoke-DnsFailureSimulation {
    Write-Header "Step 7: DNS Failure Simulation & Automatic Recovery"
    Write-Host ""
    Write-Host "  Simulating East US regional failure..." -ForegroundColor Gray
    Write-Host "  Traffic should auto-route to West Europe." -ForegroundColor Gray
    Write-Host ""
    Pause-ForContinue

    try {
        $tmProfile = Get-AzTrafficManagerProfile -ResourceGroupName $RgDns -Name "tm-$Company-failover"
        $tmFqdn    = "$($tmProfile.RelativeDnsName).trafficmanager.net"

        Write-Step "Current DNS resolution (East US should be primary):"
        Resolve-DnsName -Name $tmFqdn -ErrorAction SilentlyContinue | Select-Object Name, IPAddress | Format-Table

        Write-Step "Disabling East US endpoint..."
        $ep = Get-AzTrafficManagerEndpoint `
            -Name "primary-east-us" `
            -ProfileName "tm-$Company-failover" `
            -ResourceGroupName $RgDns `
            -Type AzureEndpoints
        $ep.EndpointStatus = "Disabled"
        Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep | Out-Null
        Write-Ok "East US endpoint disabled"

        Write-Step "Waiting 60 seconds for Traffic Manager to detect failure..."
        for ($i = 60; $i -gt 0; $i--) {
            Write-Progress -Activity "Waiting for DNS failover" -Status "$i seconds remaining" -PercentComplete ((60-$i)/60*100)
            Start-Sleep -Seconds 1
        }
        Write-Progress -Completed -Activity "Done"

        Write-Step "DNS after failure (expect West Europe IP):"
        Resolve-DnsName -Name $tmFqdn -ErrorAction SilentlyContinue | Select-Object Name, IPAddress | Format-Table

        Pause-ForContinue

        Write-Step "Re-enabling East US endpoint (recovery)..."
        $ep.EndpointStatus = "Enabled"
        Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $ep | Out-Null
        Write-Ok "East US re-enabled. DNS will fail back within ~60 seconds."

        Start-Sleep -Seconds 30
        Write-Step "DNS after recovery:"
        Resolve-DnsName -Name $tmFqdn -ErrorAction SilentlyContinue | Select-Object Name, IPAddress | Format-Table
    }
    catch {
        Write-Warn "Traffic Manager not deployed yet. Run step 5 first."
    }
}

# ── DNS Query Demonstrations ──────────────────────────────────
function Show-DnsQueryDemos {
    Write-Header "DNS Query Demonstrations"

    Write-Step "All DNS records in $DomainName zone:"
    Get-AzDnsRecordSet -ResourceGroupName $RgDns -ZoneName $DomainName |
        Select-Object Name, RecordType, Ttl |
        Format-Table -AutoSize

    Write-Step "Resolve www.$DomainName (via PowerShell):"
    Resolve-DnsName -Name "www.$DomainName" -ErrorAction SilentlyContinue

    Write-Step "Resolve MX records:"
    Resolve-DnsName -Name $DomainName -Type MX -ErrorAction SilentlyContinue

    Write-Step "Resolve TXT records (SPF):"
    Resolve-DnsName -Name $DomainName -Type TXT -ErrorAction SilentlyContinue

    Write-Step "Check DNSSEC (RRSIG records):"
    Resolve-DnsName -Name $DomainName -Type RRSIG -DnssecOk -ErrorAction SilentlyContinue

    Write-Step "Geo routing test (geographic Traffic Manager):"
    $tmGeo = Get-AzTrafficManagerProfile -ResourceGroupName $RgDns -Name "tm-$Company-geo" -ErrorAction SilentlyContinue
    if ($tmGeo) {
        $geoFqdn = "$($tmGeo.RelativeDnsName).trafficmanager.net"
        Write-Host "  Resolving: $geoFqdn" -ForegroundColor Gray
        Resolve-DnsName -Name $geoFqdn -ErrorAction SilentlyContinue | Select-Object Name, IPAddress
    }
}

# ── Cleanup ───────────────────────────────────────────────────
function Remove-LabResources {
    Write-Header "Cleanup"
    Write-Warn "This will delete ALL resource groups!"
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -eq "yes") {
        foreach ($rg in @($RgDns, $RgUS, $RgEU, $RgAP)) {
            Remove-AzResourceGroup -Name $rg -Force -AsJob -ErrorAction SilentlyContinue
            Write-Ok "Deleting $rg..."
        }
    }
    else {
        Write-Ok "Cleanup cancelled"
    }
}

# ── Main Menu ─────────────────────────────────────────────────
function Show-Menu {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Blue
    Write-Host "║  Case Study 4: Global DNS Management Lab        ║" -ForegroundColor Blue
    Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Blue
    Write-Host "║  1) Run full deployment (all steps)             ║" -ForegroundColor Blue
    Write-Host "║  2) Step 1: Create Resource Groups              ║" -ForegroundColor Blue
    Write-Host "║  3) Step 2: Create VNet                         ║" -ForegroundColor Blue
    Write-Host "║  4) Step 3: Deploy DNS Zones                    ║" -ForegroundColor Blue
    Write-Host "║  5) Step 4: Create Regional IPs                 ║" -ForegroundColor Blue
    Write-Host "║  6) Step 5: Deploy Traffic Manager              ║" -ForegroundColor Blue
    Write-Host "║  7) Step 6: Enable DNSSEC                       ║" -ForegroundColor Blue
    Write-Host "║  8) Step 7: DNS Failure Simulation              ║" -ForegroundColor Blue
    Write-Host "║  9) DNS Query Demonstrations                    ║" -ForegroundColor Blue
    Write-Host "║  C) Cleanup                                     ║" -ForegroundColor Blue
    Write-Host "║  0) Exit                                        ║" -ForegroundColor Blue
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Blue
    return (Read-Host "Select option")
}

# ── Entry Point ───────────────────────────────────────────────
Invoke-Preflight

$vnet = $null
$pips = @{}

while ($true) {
    $choice = Show-Menu
    switch ($choice) {
        "1" {
            New-LabResourceGroups
            $vnet = New-LabVNet
            Deploy-DnsZones -VNetId $vnet.Id
            $pips = New-RegionalPublicIPs
            Deploy-TrafficManager -Pips $pips
            Enable-DnsSec
            Show-DnsQueryDemos
            Invoke-DnsFailureSimulation
        }
        "2" { New-LabResourceGroups }
        "3" { $vnet = New-LabVNet }
        "4" {
            if (-not $vnet) {
                $vnet = Get-AzVirtualNetwork -ResourceGroupName $RgUS -Name "vnet-$Company-prod" -ErrorAction SilentlyContinue
            }
            if ($vnet) { Deploy-DnsZones -VNetId $vnet.Id } else { Write-Warn "Create VNet first (option 3)" }
        }
        "5" { $pips = New-RegionalPublicIPs }
        "6" {
            if ($pips.Count -eq 0) {
                $pips = @{
                    "pip-lb-us-prod" = (Get-AzPublicIpAddress -ResourceGroupName $RgUS -Name "pip-lb-us-prod" -ErrorAction SilentlyContinue)
                    "pip-lb-eu-prod" = (Get-AzPublicIpAddress -ResourceGroupName $RgEU -Name "pip-lb-eu-prod" -ErrorAction SilentlyContinue)
                    "pip-lb-ap-prod" = (Get-AzPublicIpAddress -ResourceGroupName $RgAP -Name "pip-lb-ap-prod" -ErrorAction SilentlyContinue)
                }
            }
            if ($pips["pip-lb-us-prod"]) { Deploy-TrafficManager -Pips $pips } else { Write-Warn "Create regional IPs first (option 5)" }
        }
        "7" { Enable-DnsSec }
        "8" { Invoke-DnsFailureSimulation }
        "9" { Show-DnsQueryDemos }
        { $_ -in "C","c" } { Remove-LabResources }
        "0" { Write-Host "Exiting."; exit 0 }
        default { Write-Warn "Invalid option" }
    }
}
