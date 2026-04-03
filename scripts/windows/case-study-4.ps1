#Requires -Version 5.1
# ============================================================
# Case Study 4: Scalable and Secure DNS Management
# Dual-region DNS for ShopEasy e-commerce
# Regions: East US (primary) | East US 2 (DR / secondary)
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
$LocationDR     = "eastus2"
$DomainName     = "shopeasy.example.com"
$RgDns          = "rg-$Company-dns"
$RgUS           = "rg-$Company-us"
$RgDR           = "rg-$Company-eastus2"
$LabDir         = Join-Path (Split-Path $PSScriptRoot -Parent) "labs\case-study-4-dns"

$EastUsLbIp     = "20.10.5.100"
$EastUs2LbIp    = "20.40.5.100"

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
    Write-Host ""
    Write-Host "  rg-shopeasy-dns     → $LocationUS  (DNS zones + Traffic Manager)" -ForegroundColor Gray
    Write-Host "  rg-shopeasy-us      → $LocationUS  (East US primary endpoint)" -ForegroundColor Gray
    Write-Host "  rg-shopeasy-eastus2 → $LocationDR (East US 2 DR endpoint)" -ForegroundColor Gray
    Write-Host ""

    $groups = @(
        @{ Name = $RgDns; Location = $LocationUS },
        @{ Name = $RgUS;  Location = $LocationUS },
        @{ Name = $RgDR;  Location = $LocationDR }
    )

    foreach ($g in $groups) {
        Write-Step "Creating $($g.Name) in $($g.Location)..."
        New-AzResourceGroup -Name $g.Name -Location $g.Location `
            -Tag @{ company = $Company; purpose = "dns-management" } `
            -Force | Out-Null
        Write-Ok "$($g.Name) created"
    }
}

# ── Step 2: Create VNets ──────────────────────────────────────
function New-LabVNets {
    Write-Header "Step 2: Create VNets for Private DNS Linking"

    Write-Step "Creating VNet in East US ($RgUS)..."
    $subnetUS = New-AzVirtualNetworkSubnetConfig -Name "subnet-app" -AddressPrefix "10.0.1.0/24"
    $vnetUS = New-AzVirtualNetwork `
        -ResourceGroupName $RgUS `
        -Location $LocationUS `
        -Name "vnet-$Company-prod" `
        -AddressPrefix "10.0.0.0/16" `
        -Subnet $subnetUS
    Write-Ok "East US VNet: $($vnetUS.Id)"

    Write-Step "Creating VNet in East US 2 ($RgDR)..."
    $subnetDR = New-AzVirtualNetworkSubnetConfig -Name "subnet-app" -AddressPrefix "10.0.1.0/24"
    $vnetDR = New-AzVirtualNetwork `
        -ResourceGroupName $RgDR `
        -Location $LocationDR `
        -Name "vnet-$Company-dr" `
        -AddressPrefix "10.0.0.0/16" `
        -Subnet $subnetDR
    Write-Ok "East US 2 VNet: $($vnetDR.Id)"

    return @{ US = $vnetUS; DR = $vnetDR }
}

# ── Step 3: Deploy DNS Zones ──────────────────────────────────
function Deploy-DnsZones {
    param([string]$VNetId, [string]$VNetDrId = "")

    Write-Header "Step 3: Deploy Public & Private DNS Zones"
    Write-Host "  Public:  $DomainName" -ForegroundColor Gray
    Write-Host "  Private: corp.$Company.internal" -ForegroundColor Gray

    $deployName = "deploy-dns-$(Get-Date -Format 'yyyyMMddHHmmss')"

    $params = @{
        ResourceGroupName      = $RgDns
        Name                   = $deployName
        TemplateFile           = "$LabDir\01-dns-zones\main.bicep"
        TemplateParameterFile  = "$LabDir\01-dns-zones\parameters.json"
        vnetId                 = $VNetId
        lbPublicIp             = $EastUsLbIp
        eastUsLbIp             = $EastUsLbIp
        eastUs2LbIp            = $EastUs2LbIp
    }
    if ($VNetDrId) { $params["eastUs2VnetId"] = $VNetDrId }

    New-AzResourceGroupDeployment @params

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
        @{ RG = $RgUS; Name = "pip-lb-us-prod";      Location = $LocationUS },
        @{ RG = $RgDR; Name = "pip-lb-eastus2-prod"; Location = $LocationDR }
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
    Write-Host "  1. Geographic routing  (NA/SA → East US | WORLD → East US 2)" -ForegroundColor Gray
    Write-Host "  2. Performance routing (lowest latency between East US and East US 2)" -ForegroundColor Gray
    Write-Host "  3. Priority failover   (East US P1 → East US 2 P2)" -ForegroundColor Gray

    $usPipId = $Pips["pip-lb-us-prod"].Id
    $drPipId = $Pips["pip-lb-eastus2-prod"].Id

    $deployName = "deploy-tm-$(Get-Date -Format 'yyyyMMddHHmmss')"

    New-AzResourceGroupDeployment `
        -ResourceGroupName $RgDns `
        -Name $deployName `
        -TemplateFile "$LabDir\02-traffic-manager\main.bicep" `
        -TemplateParameterFile "$LabDir\02-traffic-manager\parameters.json" `
        -eastUsPublicIpId $usPipId `
        -eastUs2PublicIpId $drPipId

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
    Write-Host "  Traffic should auto-route to East US 2." -ForegroundColor Gray
    Write-Host ""
    Pause-ForContinue

    try {
        $tmProfile = Get-AzTrafficManagerProfile -ResourceGroupName $RgDns -Name "tm-$Company-failover"
        $tmFqdn    = "$($tmProfile.RelativeDnsName).trafficmanager.net"

        Write-Step "Current DNS resolution (East US should be primary):"
        Resolve-DnsName -Name $tmFqdn -ErrorAction SilentlyContinue | Select-Object Name, IPAddress | Format-Table

        Write-Step "Disabling East US endpoint (simulating regional failure)..."
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

        Write-Step "DNS after failure (expect East US 2 IP):"
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

    Write-Step "Resolve regional subdomains:"
    Write-Host "  us.$DomainName  → East US primary" -ForegroundColor Gray
    Resolve-DnsName -Name "us.$DomainName"  -ErrorAction SilentlyContinue | Select-Object Name, IPAddress
    Write-Host "  dr.$DomainName  → East US 2 DR" -ForegroundColor Gray
    Resolve-DnsName -Name "dr.$DomainName"  -ErrorAction SilentlyContinue | Select-Object Name, IPAddress

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
        foreach ($rg in @($RgDns, $RgUS, $RgDR)) {
            $exists = Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue
            if ($exists) {
                Remove-AzResourceGroup -Name $rg -Force -AsJob | Out-Null
                Write-Ok "Deleting $rg..."
            } else {
                Write-Warn "$rg does not exist, skipping."
            }
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
    Write-Host "║  Regions: East US (primary) | East US 2 (DR)   ║" -ForegroundColor Blue
    Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Blue
    Write-Host "║  1) Run full deployment (all steps)             ║" -ForegroundColor Blue
    Write-Host "║  2) Step 1: Create Resource Groups              ║" -ForegroundColor Blue
    Write-Host "║  3) Step 2: Create VNets                        ║" -ForegroundColor Blue
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

$vnets = @{}
$pips  = @{}

while ($true) {
    $choice = Show-Menu
    switch ($choice) {
        "1" {
            New-LabResourceGroups
            $vnets = New-LabVNets
            Deploy-DnsZones -VNetId $vnets.US.Id -VNetDrId $vnets.DR.Id
            $pips = New-RegionalPublicIPs
            Deploy-TrafficManager -Pips $pips
            Enable-DnsSec
            Show-DnsQueryDemos
            Invoke-DnsFailureSimulation
        }
        "2" { New-LabResourceGroups }
        "3" { $vnets = New-LabVNets }
        "4" {
            if (-not $vnets.US) {
                $vnetUS = Get-AzVirtualNetwork -ResourceGroupName $RgUS -Name "vnet-$Company-prod" -ErrorAction SilentlyContinue
                $vnetDR = Get-AzVirtualNetwork -ResourceGroupName $RgDR -Name "vnet-$Company-dr" -ErrorAction SilentlyContinue
                $vnets = @{ US = $vnetUS; DR = $vnetDR }
            }
            if ($vnets.US) {
                $drId = if ($vnets.DR) { $vnets.DR.Id } else { "" }
                Deploy-DnsZones -VNetId $vnets.US.Id -VNetDrId $drId
            } else { Write-Warn "Create VNets first (option 3)" }
        }
        "5" { $pips = New-RegionalPublicIPs }
        "6" {
            if ($pips.Count -eq 0) {
                $pips = @{
                    "pip-lb-us-prod"      = (Get-AzPublicIpAddress -ResourceGroupName $RgUS -Name "pip-lb-us-prod"      -ErrorAction SilentlyContinue)
                    "pip-lb-eastus2-prod" = (Get-AzPublicIpAddress -ResourceGroupName $RgDR -Name "pip-lb-eastus2-prod" -ErrorAction SilentlyContinue)
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
