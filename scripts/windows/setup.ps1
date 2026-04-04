#Requires -Version 5.1
# ============================================================
# Azure Training Lab - Environment Setup Script (Windows PowerShell)
# Module: Introduction to Azure - II
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ──────────────────────────────────────────────────
function Write-Banner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Blue
    Write-Host "║       Azure Training Lab - Environment Setup            ║" -ForegroundColor Blue
    Write-Host "║       Introduction to Azure - II                        ║" -ForegroundColor Blue
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Blue
    Write-Host ""
}

function Write-Step   { param($msg) Write-Host "[STEP] $msg" -ForegroundColor Cyan }
function Write-Ok     { param($msg) Write-Host "[  OK] $msg" -ForegroundColor Green }
function Write-Warn   { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err    { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; throw $msg }

# ── Check Azure CLI ───────────────────────────────────────────
function Test-AzureCLI {
    Write-Step "Checking Azure CLI..."
    try {
        $version = az version --query '"azure-cli"' -o tsv 2>$null
        Write-Ok "Azure CLI found: v$version"
    }
    catch {
        Write-Warn "Azure CLI not found. Installing via winget..."
        try {
            winget install Microsoft.AzureCLI --silent
            Write-Ok "Azure CLI installed"
        }
        catch {
            Write-Err "Failed to install Azure CLI. Download manually: https://aka.ms/installazurecliwindows"
        }
    }
}

# ── Check Azure PowerShell ────────────────────────────────────
function Test-AzPowerShell {
    Write-Step "Checking Azure PowerShell (Az module)..."
    if (Get-Module -ListAvailable -Name Az.Accounts) {
        $azVersion = (Get-Module -ListAvailable -Name Az.Accounts | Select-Object -First 1).Version
        Write-Ok "Az module found: v$azVersion"
    }
    else {
        Write-Step "Installing Az PowerShell module..."
        Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -Scope CurrentUser
        Write-Ok "Az module installed"
    }
}

# ── Check Bicep ───────────────────────────────────────────────
function Test-Bicep {
    Write-Step "Checking Bicep CLI..."
    try {
        az bicep version 2>$null | Out-Null
        Write-Ok "Bicep found"
    }
    catch {
        Write-Step "Installing Bicep..."
        az bicep install
        Write-Ok "Bicep installed"
    }
}

# ── Azure Login ───────────────────────────────────────────────
function Connect-AzureAccounts {
    Write-Step "Checking Azure login (Az module)..."
    try {
        $ctx = Get-AzContext
        if ($null -eq $ctx -or $null -eq $ctx.Account) {
            Write-Step "Not logged in. Starting interactive login..."
            Connect-AzAccount
        }
        $sub = (Get-AzContext).Subscription
        Write-Ok "Logged in. Subscription: $($sub.Name) ($($sub.Id))"
    }
    catch {
        Write-Step "Logging in via Azure CLI..."
        az login
    }

    Write-Step "Checking Azure CLI login..."
    try {
        $cliAccount = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
        Write-Ok "Azure CLI: $($cliAccount.name) ($($cliAccount.id))"
        $env:AZURE_SUBSCRIPTION_ID = $cliAccount.id
        Write-Host ""
        Write-Host "Subscription ID: $($cliAccount.id)" -ForegroundColor Yellow
        Write-Host "Update parameters.json files with this value before deploying." -ForegroundColor Yellow
    }
    catch {
        az login
    }
}

# ── Register Azure providers ──────────────────────────────────
function Register-AzureProviders {
    Write-Step "Registering required Azure resource providers..."

    $providers = @(
        "Microsoft.Network",
        "Microsoft.Compute",
        "Microsoft.Storage",
        "Microsoft.RecoveryServices"
    )

    foreach ($provider in $providers) {
        $state = az provider show --namespace $provider --query registrationState -o tsv 2>$null
        if ($state -eq "Registered") {
            Write-Ok "Provider $provider`: Registered"
        }
        else {
            Write-Step "Registering $provider..."
            az provider register --namespace $provider --wait
            Write-Ok "Provider $provider`: Registered"
        }
    }
}

# ── Check tools ───────────────────────────────────────────────
function Test-Tools {
    Write-Step "Checking additional tools..."

    $tools = @("curl", "nslookup", "Resolve-DnsName")
    foreach ($tool in $tools) {
        if (Get-Command $tool -ErrorAction SilentlyContinue) {
            Write-Ok "$tool available"
        }
        else {
            Write-Warn "$tool not found (optional)"
        }
    }
}

# ── Main ──────────────────────────────────────────────────────
function Main {
    Write-Banner
    Test-AzureCLI
    Test-AzPowerShell
    Test-Bicep
    Connect-AzureAccounts
    Test-Tools
    Register-AzureProviders

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  Setup complete! Next steps:                            ║" -ForegroundColor Green
    Write-Host "║  1. Update 7de694dc-7044-4a4a-9a27-d499eb4072b7 in parameters   ║" -ForegroundColor Green
    Write-Host "║  2. Run: .\scripts\windows\case-study-1.ps1             ║" -ForegroundColor Green
    Write-Host "║  3. Run: .\scripts\windows\case-study-4.ps1             ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
}

Main
