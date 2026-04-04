#!/usr/bin/env bash
# ============================================================
# Azure Training Lab - Environment Setup Script (Linux/macOS)
# Module: Introduction to Azure - II
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_banner() {
  echo -e "${BLUE}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║       Azure Training Lab - Environment Setup            ║"
  echo "║       Introduction to Azure - II                        ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_step() {
  echo -e "${CYAN}[STEP]${NC} $1"
}

print_ok() {
  echo -e "${GREEN}[  OK]${NC} $1"
}

print_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
  echo -e "${RED}[FAIL]${NC} $1"
}

# ── Check & install Azure CLI ─────────────────────────────────
check_azure_cli() {
  print_step "Checking Azure CLI..."
  if command -v az &>/dev/null; then
    AZ_VERSION=$(az version --query '"azure-cli"' -o tsv)
    print_ok "Azure CLI found: v${AZ_VERSION}"
  else
    print_warn "Azure CLI not found. Installing..."
    if [[ "$(uname)" == "Darwin" ]]; then
      brew update && brew install azure-cli
    elif [[ -f /etc/debian_version ]]; then
      curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    elif [[ -f /etc/redhat-release ]]; then
      sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
      sudo dnf install -y azure-cli
    else
      print_error "Unsupported OS. Install Azure CLI manually: https://aka.ms/installazureclilinux"
      exit 1
    fi
    print_ok "Azure CLI installed"
  fi
}

# ── Check & install Bicep ─────────────────────────────────────
check_bicep() {
  print_step "Checking Bicep CLI..."
  if az bicep version &>/dev/null; then
    BICEP_VERSION=$(az bicep version --query 'bicepVersion' -o tsv 2>/dev/null || az bicep version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    print_ok "Bicep found: v${BICEP_VERSION}"
  else
    print_step "Installing Bicep CLI..."
    az bicep install
    print_ok "Bicep installed"
  fi
}

# ── Login to Azure ────────────────────────────────────────────
azure_login() {
  print_step "Checking Azure login status..."
  if az account show &>/dev/null; then
    SUBSCRIPTION=$(az account show --query name -o tsv)
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    print_ok "Already logged in. Subscription: ${SUBSCRIPTION} (${SUBSCRIPTION_ID})"
  else
    print_step "Not logged in. Starting Azure login..."
    az login
    SUBSCRIPTION=$(az account show --query name -o tsv)
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    print_ok "Logged in. Subscription: ${SUBSCRIPTION} (${SUBSCRIPTION_ID})"
  fi

  export AZURE_SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
  echo -e "${YELLOW}Active subscription ID: ${SUBSCRIPTION_ID}${NC}"
  echo "Update parameters.json files with this subscription ID before deploying."
}

# ── Check required tools ──────────────────────────────────────
check_tools() {
  print_step "Checking additional tools..."

  tools=("curl" "jq" "nslookup" "dig")
  for tool in "${tools[@]}"; do
    if command -v "${tool}" &>/dev/null; then
      print_ok "${tool} available"
    else
      print_warn "${tool} not found (optional but useful for lab exercises)"
    fi
  done
}

# ── Register Azure providers ──────────────────────────────────
register_providers() {
  print_step "Registering required Azure resource providers..."

  providers=(
    "Microsoft.Network"
    "Microsoft.Compute"
    "Microsoft.Storage"
    "Microsoft.RecoveryServices"
  )

  for provider in "${providers[@]}"; do
    STATE=$(az provider show --namespace "${provider}" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
    if [[ "${STATE}" == "Registered" ]]; then
      print_ok "Provider ${provider}: Registered"
    else
      print_step "Registering ${provider}..."
      az provider register --namespace "${provider}" --wait
      print_ok "Provider ${provider}: Registered"
    fi
  done
}

# ── Main ──────────────────────────────────────────────────────
main() {
  print_banner
  check_azure_cli
  check_bicep
  azure_login
  check_tools
  register_providers

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  Setup complete! Next steps:                            ║${NC}"
  echo -e "${GREEN}║  1. Run: ./scripts/linux/case-study-3.sh                ║${NC}"
  echo -e "${GREEN}║  2. Run: ./scripts/linux/case-study-4.sh                ║${NC}"
  echo -e "${GREEN}║  (Subscription is auto-detected at runtime)             ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
}

main "$@"
