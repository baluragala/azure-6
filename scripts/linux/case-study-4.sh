#!/usr/bin/env bash
# ============================================================
# Case Study 4: Scalable and Secure DNS Management
# Dual-region DNS for ShopEasy e-commerce
# Regions: East US (primary) | East US 2 (DR / secondary)
#
# Best-practice hardening:
#   • No global set -e  → step errors return to menu, not exit
#   • set -uo pipefail  → unbound vars + broken pipes still fatal
#   • Idempotent ops    → safe to re-run any step at any time
#   • Retry wrapper     → 3 attempts with exp. backoff for az calls
#   • Prereq guards     → each step validates its dependencies first
#   • SIGINT trap       → leaves the terminal in a clean state
# ============================================================

set -uo pipefail   # -u: unbound vars are errors  -o pipefail: pipe errors propagate
                   # NOTE: -e (exit on error) is intentionally omitted so the
                   #       interactive menu survives individual step failures.

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

print_header() { echo -e "\n${BLUE}═══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}═══════════════════════════════════════${NC}"; }
print_step()   { echo -e "${CYAN}[STEP]${NC} $1"; }
print_ok()     { echo -e "${GREEN}[  OK]${NC} $1"; }
print_warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()  { echo -e "${RED}[FAIL]${NC} $1"; }   # does NOT exit — returns to menu
pause()        { echo -e "${YELLOW}Press ENTER to continue...${NC}"; read -r; }

# ── Clean exit on Ctrl-C ─────────────────────────────────────
trap 'echo -e "\n${YELLOW}Interrupted. Returning to menu.${NC}"; return 2 2>/dev/null || exit 0' INT

# ── Configuration ─────────────────────────────────────────────
COMPANY="shopeasy"
LOCATION_US="eastus"
LOCATION_DR="eastus2"
DOMAIN_NAME="shopeasy.example.com"

RG_DNS="rg-${COMPANY}-dns"
RG_US="rg-${COMPANY}-us"
RG_DR="rg-${COMPANY}-eastus2"

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/labs/case-study-4-dns"

EAST_US_LB_IP="20.10.5.100"
EAST_US2_LB_IP="20.40.5.100"

# ── Idempotency helpers ───────────────────────────────────────
rg_exists()         { az group show            --name "$1"                                &>/dev/null; }
vnet_exists()       { az network vnet show     --resource-group "$1" --name "$2"         &>/dev/null; }
pip_exists()        { az network public-ip show --resource-group "$1" --name "$2"        &>/dev/null; }
dns_zone_exists()   { az network dns zone show --resource-group "$1" --name "$2"         &>/dev/null; }
tm_profile_exists() { az network traffic-manager profile show --resource-group "$1" --name "$2" &>/dev/null; }

# ── Retry wrapper (3 attempts, exponential backoff) ──────────
# Usage: az_retry <az subcommand and args…>
az_retry() {
  local max_attempts=3
  local delay=10
  local attempt=1
  while (( attempt <= max_attempts )); do
    if az "$@"; then
      return 0
    fi
    if (( attempt < max_attempts )); then
      print_warn "Azure CLI attempt ${attempt}/${max_attempts} failed. Retrying in ${delay}s..."
      sleep "${delay}"
      delay=$(( delay * 2 ))
    fi
    (( attempt++ ))
  done
  print_error "Azure CLI command failed after ${max_attempts} attempts: az $*"
  return 1
}

# ── Step runner: isolates failures so menu stays alive ───────
# Usage: run_step "Step name" function_name [args…]
run_step() {
  local name="$1"; shift
  if "$@"; then
    return 0
  else
    local rc=$?
    print_warn "\"${name}\" did not complete cleanly (exit ${rc})."
    print_warn "Review the output above, then retry from the menu if needed."
    return "${rc}"
  fi
}

# ── Pre-flight checks ─────────────────────────────────────────
preflight() {
  print_header "Pre-flight Checks"

  print_step "Verifying Azure login..."
  if ! az account show --query "{name:name, id:id}" -o table; then
    print_error "Not logged in. Run: az login"
    return 1
  fi

  print_step "Verifying Azure CLI version..."
  az version --query '"azure-cli"' -o tsv

  print_step "Verifying Bicep..."
  if ! az bicep version &>/dev/null; then
    print_warn "Bicep not found — installing..."
    az bicep install || { print_error "Bicep install failed"; return 1; }
  fi

  print_step "Verifying DNS tools (nslookup/dig)..."
  command -v nslookup &>/dev/null || command -v dig &>/dev/null || \
    print_warn "Neither nslookup nor dig found — DNS query demos will be limited."

  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  export SUBSCRIPTION_ID
  print_ok "Pre-flight passed. Subscription: ${SUBSCRIPTION_ID}"
}

# ── Internal helper: create a single resource group idempotently ─
_create_rg() {
  local rg="$1"
  local loc="$2"
  local tags="${3:-}"
  if rg_exists "${rg}"; then
    local existing_loc
    existing_loc=$(az group show --name "${rg}" --query location -o tsv)
    if [[ "${existing_loc}" != "${loc}" ]]; then
      print_error "Resource group '${rg}' already exists in '${existing_loc}' but expected '${loc}'."
      print_warn "Delete it first:  az group delete --name ${rg} --yes"
      return 1
    fi
    print_ok "${rg} already exists in ${loc} — skipping creation"
  else
    print_step "Creating ${rg} in ${loc}..."
    az_retry group create --name "${rg}" --location "${loc}" \
      --tags ${tags} \
      --output table || return 1
    print_ok "${rg} created"
  fi
}

# ── Step 1: Create Resource Groups ───────────────────────────
create_resource_groups() {
  print_header "Step 1: Create Resource Groups"
  echo ""
  echo "  ${RG_DNS}      → ${LOCATION_US}  (DNS zones + Traffic Manager)"
  echo "  ${RG_US}       → ${LOCATION_US}  (East US primary endpoint)"
  echo "  ${RG_DR}       → ${LOCATION_DR}  (East US 2 DR endpoint)"
  echo ""
  local tags="company=${COMPANY} purpose=dns-management"
  _create_rg "${RG_DNS}" "${LOCATION_US}" "${tags}" || return 1
  _create_rg "${RG_US}"  "${LOCATION_US}" "${tags}" || return 1
  _create_rg "${RG_DR}"  "${LOCATION_DR}" "${tags}" || return 1
}

# ── Step 2: Create VNets (needed for private DNS) ─────────────
create_vnets() {
  print_header "Step 2: Create VNets for Private DNS Zone Linking"

  rg_exists "${RG_US}" || {
    print_error "Resource group '${RG_US}' not found. Run Step 1 first."
    return 1
  }
  rg_exists "${RG_DR}" || {
    print_error "Resource group '${RG_DR}' not found. Run Step 1 first."
    return 1
  }

  # East US VNet
  if vnet_exists "${RG_US}" "vnet-${COMPANY}-prod"; then
    print_ok "East US VNet 'vnet-${COMPANY}-prod' already exists — skipping"
  else
    print_step "Creating VNet in East US (${RG_US})..."
    az_retry network vnet create \
      --resource-group "${RG_US}" \
      --name "vnet-${COMPANY}-prod" \
      --address-prefix "10.0.0.0/16" \
      --subnet-name "subnet-app" \
      --subnet-prefix "10.0.1.0/24" \
      --location "${LOCATION_US}" \
      --output table || return 1
  fi

  VNET_ID=$(az network vnet show \
    --resource-group "${RG_US}" \
    --name "vnet-${COMPANY}-prod" \
    --query id -o tsv)
  print_ok "East US VNet: ${VNET_ID}"

  # East US 2 VNet
  if vnet_exists "${RG_DR}" "vnet-${COMPANY}-dr"; then
    print_ok "East US 2 VNet 'vnet-${COMPANY}-dr' already exists — skipping"
  else
    print_step "Creating VNet in East US 2 (${RG_DR})..."
    az_retry network vnet create \
      --resource-group "${RG_DR}" \
      --name "vnet-${COMPANY}-dr" \
      --address-prefix "10.0.0.0/16" \
      --subnet-name "subnet-app" \
      --subnet-prefix "10.0.1.0/24" \
      --location "${LOCATION_DR}" \
      --output table || return 1
  fi

  VNET_DR_ID=$(az network vnet show \
    --resource-group "${RG_DR}" \
    --name "vnet-${COMPANY}-dr" \
    --query id -o tsv)
  print_ok "East US 2 VNet: ${VNET_DR_ID}"

  export VNET_ID VNET_DR_ID
}

# ── Step 3: Deploy DNS Zones ──────────────────────────────────
deploy_dns_zones() {
  print_header "Step 3: Deploy Public & Private DNS Zones"
  echo ""
  echo "  Public Zone: ${DOMAIN_NAME}"
  echo "  ├── @ A   → ${EAST_US_LB_IP}   (apex → East US)"
  echo "  ├── www A → ${EAST_US_LB_IP}   (East US)"
  echo "  ├── us  A → ${EAST_US_LB_IP}   (East US primary)"
  echo "  └── dr  A → ${EAST_US2_LB_IP}  (East US 2 DR)"
  echo ""
  echo "  Private Zone: corp.shopeasy.internal"
  echo "  ├── order-service   → 10.0.2.10"
  echo "  ├── product-service → 10.0.2.11"
  echo "  ├── db-master       → 10.0.3.4"
  echo "  └── redis           → 10.0.2.20"
  echo ""

  rg_exists "${RG_DNS}" || {
    print_error "DNS resource group not found. Run Step 1 first."
    return 1
  }
  vnet_exists "${RG_US}" "vnet-${COMPANY}-prod" || {
    print_error "East US VNet not found. Run Step 2 first."
    return 1
  }

  VNET_ID=$(az network vnet show \
    --resource-group "${RG_US}" \
    --name "vnet-${COMPANY}-prod" \
    --query id -o tsv)

  VNET_DR_ID=$(az network vnet show \
    --resource-group "${RG_DR}" \
    --name "vnet-${COMPANY}-dr" \
    --query id -o tsv 2>/dev/null || echo "")

  if dns_zone_exists "${RG_DNS}" "${DOMAIN_NAME}"; then
    print_ok "DNS zone '${DOMAIN_NAME}' already exists — re-deploying to reconcile records"
  fi

  az_retry deployment group create \
    --resource-group "${RG_DNS}" \
    --template-file "${LAB_DIR}/01-dns-zones/main.bicep" \
    --parameters "${LAB_DIR}/01-dns-zones/parameters.json" \
    --parameters "vnetId=${VNET_ID}" \
                 "eastUs2VnetId=${VNET_DR_ID}" \
                 "lbPublicIp=${EAST_US_LB_IP}" \
                 "eastUsLbIp=${EAST_US_LB_IP}" \
                 "eastUs2LbIp=${EAST_US2_LB_IP}" \
    --name "deploy-dns-$(date +%Y%m%d%H%M%S)" \
    --output table || return 1

  print_step "Azure Name Servers for ${DOMAIN_NAME}:"
  az network dns zone show \
    --resource-group "${RG_DNS}" \
    --name "${DOMAIN_NAME}" \
    --query nameServers \
    --output table 2>/dev/null || print_warn "Name server retrieval skipped"

  print_warn "IMPORTANT: Update NS records at your domain registrar to enable Azure DNS."
  print_ok "DNS zones deployed"
}

# ── Step 4: Create Regional Public IPs ───────────────────────
create_regional_ips() {
  print_header "Step 4: Create Regional Public IP Addresses"

  rg_exists "${RG_US}" || {
    print_error "Resource group '${RG_US}' not found. Run Step 1 first."
    return 1
  }
  rg_exists "${RG_DR}" || {
    print_error "Resource group '${RG_DR}' not found. Run Step 1 first."
    return 1
  }

  # East US PIP
  if pip_exists "${RG_US}" "pip-lb-us-prod"; then
    print_ok "East US Public IP 'pip-lb-us-prod' already exists — skipping"
  else
    print_step "Creating pip-lb-us-prod in East US..."
    az_retry network public-ip create \
      --resource-group "${RG_US}" \
      --name "pip-lb-us-prod" \
      --sku Standard \
      --allocation-method Static \
      --location "${LOCATION_US}" \
      --output table || return 1
  fi

  # East US 2 PIP
  if pip_exists "${RG_DR}" "pip-lb-eastus2-prod"; then
    print_ok "East US 2 Public IP 'pip-lb-eastus2-prod' already exists — skipping"
  else
    print_step "Creating pip-lb-eastus2-prod in East US 2..."
    az_retry network public-ip create \
      --resource-group "${RG_DR}" \
      --name "pip-lb-eastus2-prod" \
      --sku Standard \
      --allocation-method Static \
      --location "${LOCATION_DR}" \
      --output table || return 1
  fi

  US_PIP_ID=$(az network public-ip show --resource-group "${RG_US}" --name "pip-lb-us-prod" --query id -o tsv)
  DR_PIP_ID=$(az network public-ip show --resource-group "${RG_DR}" --name "pip-lb-eastus2-prod" --query id -o tsv)
  US_PIP_ADDR=$(az network public-ip show --resource-group "${RG_US}" --name "pip-lb-us-prod" --query ipAddress -o tsv 2>/dev/null || echo "pending")
  DR_PIP_ADDR=$(az network public-ip show --resource-group "${RG_DR}" --name "pip-lb-eastus2-prod" --query ipAddress -o tsv 2>/dev/null || echo "pending")

  print_ok "East US IP:   ${US_PIP_ADDR}"
  print_ok "East US 2 IP: ${DR_PIP_ADDR}"
  export US_PIP_ID DR_PIP_ID
}

# ── Step 5: Deploy Traffic Manager (Geo + Performance) ───────
deploy_traffic_manager() {
  print_header "Step 5: Deploy Traffic Manager Profiles"
  echo ""
  echo "  Three profiles:"
  echo "  1. Geographic routing   (NA/SA → East US | WORLD → East US 2)"
  echo "  2. Performance routing  (lowest latency between East US and East US 2)"
  echo "  3. Priority failover    (East US P1 → East US 2 P2)"
  echo ""

  pip_exists "${RG_US}" "pip-lb-us-prod" || {
    print_error "East US Public IP not found. Run Step 4 first."
    return 1
  }
  pip_exists "${RG_DR}" "pip-lb-eastus2-prod" || {
    print_error "East US 2 Public IP not found. Run Step 4 first."
    return 1
  }
  rg_exists "${RG_DNS}" || {
    print_error "DNS resource group not found. Run Step 1 first."
    return 1
  }

  US_PIP_ID=$(az network public-ip show --resource-group "${RG_US}" --name "pip-lb-us-prod" --query id -o tsv)
  DR_PIP_ID=$(az network public-ip show --resource-group "${RG_DR}" --name "pip-lb-eastus2-prod" --query id -o tsv)

  if tm_profile_exists "${RG_DNS}" "tm-${COMPANY}-failover"; then
    print_ok "Traffic Manager profiles already exist — re-deploying to reconcile"
  fi

  az_retry deployment group create \
    --resource-group "${RG_DNS}" \
    --template-file "${LAB_DIR}/02-traffic-manager/main.bicep" \
    --parameters "${LAB_DIR}/02-traffic-manager/parameters.json" \
    --parameters "eastUsPublicIpId=${US_PIP_ID}" \
                 "eastUs2PublicIpId=${DR_PIP_ID}" \
    --name "deploy-tm-$(date +%Y%m%d%H%M%S)" \
    --output table || return 1

  print_step "Traffic Manager profiles:"
  az network traffic-manager profile list \
    --resource-group "${RG_DNS}" \
    --query "[].{Name:name, RoutingMethod:trafficRoutingMethod, DNS:dnsConfig.fqdn}" \
    --output table 2>/dev/null || true

  print_ok "Traffic Manager deployed"
}

# ── Step 6: Enable DNSSEC ─────────────────────────────────────
enable_dnssec() {
  print_header "Step 6: Enable DNSSEC"
  echo ""
  echo "  DNSSEC protects ${DOMAIN_NAME} against DNS spoofing."
  echo "  Azure will sign all DNS records with cryptographic keys."
  echo ""

  dns_zone_exists "${RG_DNS}" "${DOMAIN_NAME}" || {
    print_error "DNS zone '${DOMAIN_NAME}' not found. Run Step 3 first."
    return 1
  }

  print_warn "NOTE: After enabling, you MUST add the DS record to your domain registrar."
  pause

  az_retry deployment group create \
    --resource-group "${RG_DNS}" \
    --template-file "${LAB_DIR}/03-dnssec/main.bicep" \
    --parameters "dnsZoneName=${DOMAIN_NAME}" \
                 "dnsZoneResourceGroup=${RG_DNS}" \
    --name "deploy-dnssec-$(date +%Y%m%d%H%M%S)" \
    --output table 2>/dev/null || {
      print_warn "DNSSEC via Bicep requires preview API — trying Azure CLI..."
      az network dns dnssec-config create \
        --resource-group "${RG_DNS}" \
        --zone-name "${DOMAIN_NAME}" 2>/dev/null || \
        print_warn "DNSSEC is in preview. Enable manually: Azure Portal → DNS Zones → ${DOMAIN_NAME} → DNSSEC"
    }

  print_step "Retrieving DS records for registrar..."
  az network dns dnssec-config show \
    --resource-group "${RG_DNS}" \
    --zone-name "${DOMAIN_NAME}" \
    --query "signingKeys[].delegationSignerInfo" 2>/dev/null || \
    print_warn "DNSSEC signing keys not yet available — check back in a few minutes."

  print_ok "DNSSEC step complete"
}

# ── Step 7: DNS Failure Simulation ───────────────────────────
simulate_dns_failure() {
  print_header "Step 7: DNS Failure Simulation & Recovery"
  echo ""
  echo "  Simulating East US regional failure:"
  echo "  → Disabling East US endpoint in failover Traffic Manager profile"
  echo "  → Traffic should route to East US 2 automatically"
  echo ""

  tm_profile_exists "${RG_DNS}" "tm-${COMPANY}-failover" || {
    print_error "Traffic Manager profile 'tm-${COMPANY}-failover' not found. Run Step 5 first."
    return 1
  }

  pause

  TM_FAILOVER=$(az network traffic-manager profile show \
    --resource-group "${RG_DNS}" \
    --name "tm-${COMPANY}-failover" \
    --query dnsConfig.fqdn -o tsv 2>/dev/null || echo "")

  [[ -z "${TM_FAILOVER}" ]] && {
    print_error "Could not read Traffic Manager FQDN."
    return 1
  }

  print_step "Current DNS resolution (East US should be primary):"
  nslookup "${TM_FAILOVER}" 2>/dev/null || dig "${TM_FAILOVER}" A 2>/dev/null || \
    print_warn "DNS query tools unavailable"

  print_step "Disabling East US endpoint (simulating regional failure)..."
  az_retry network traffic-manager endpoint update \
    --resource-group "${RG_DNS}" \
    --profile-name "tm-${COMPANY}-failover" \
    --name "primary-east-us" \
    --type azureEndpoints \
    --endpoint-status Disabled || return 1
  print_ok "East US endpoint disabled"

  print_step "Waiting 60 seconds for Traffic Manager to detect failure..."
  for i in {60..1}; do
    printf "\r  ${YELLOW}Waiting: %3d seconds remaining${NC}" "${i}"
    sleep 1
  done
  echo ""

  print_step "DNS resolution after failure (should be East US 2 IP):"
  nslookup "${TM_FAILOVER}" 2>/dev/null || dig "${TM_FAILOVER}" A 2>/dev/null || true

  print_step "Re-enabling East US endpoint (recovery)..."
  az_retry network traffic-manager endpoint update \
    --resource-group "${RG_DNS}" \
    --profile-name "tm-${COMPANY}-failover" \
    --name "primary-east-us" \
    --type azureEndpoints \
    --endpoint-status Enabled || {
    print_warn "Re-enable command failed — endpoint may already be enabled."
  }
  print_ok "DNS failure simulation complete. East US re-enabled."
}

# ── DNS Record Query Demos ────────────────────────────────────
dns_query_demos() {
  print_header "DNS Query Demonstrations"
  echo ""
  echo "  These commands demonstrate DNS resolution in action."
  echo "  Run these during the live session to show concepts."
  echo ""

  print_step "Get Azure DNS name servers for ${DOMAIN_NAME}:"
  az network dns zone show \
    --resource-group "${RG_DNS}" \
    --name "${DOMAIN_NAME}" \
    --query nameServers -o table 2>/dev/null || print_warn "Zone not deployed yet"

  print_step "Query A records (www):"
  nslookup "www.${DOMAIN_NAME}" 2>/dev/null || dig "www.${DOMAIN_NAME}" A +short 2>/dev/null || true

  print_step "Query regional subdomains:"
  echo "  us.${DOMAIN_NAME}  → East US primary"
  echo "  dr.${DOMAIN_NAME}  → East US 2 DR"
  nslookup "us.${DOMAIN_NAME}" 2>/dev/null || dig "us.${DOMAIN_NAME}" A +short 2>/dev/null || true

  print_step "Query MX records:"
  dig MX "${DOMAIN_NAME}" +short 2>/dev/null || nslookup -type=MX "${DOMAIN_NAME}" 2>/dev/null || true

  print_step "Query TXT records (SPF):"
  dig TXT "${DOMAIN_NAME}" +short 2>/dev/null || nslookup -type=TXT "${DOMAIN_NAME}" 2>/dev/null || true

  print_step "Check DNSSEC (should show AD flag if enabled and propagated):"
  dig +dnssec "${DOMAIN_NAME}" SOA 2>/dev/null | grep -E "flags:|RRSIG" || \
    print_warn "dig not available or DNSSEC not yet propagated"

  print_step "List all DNS records in zone:"
  az network dns record-set list \
    --resource-group "${RG_DNS}" \
    --zone-name "${DOMAIN_NAME}" \
    --query "[].{Name:name, Type:type, TTL:ttl}" \
    --output table 2>/dev/null || print_warn "Zone not deployed yet"
}

# ── Cleanup ───────────────────────────────────────────────────
cleanup() {
  print_header "Cleanup"
  print_warn "This will delete ALL resource groups and ALL resources inside them!"
  echo -e "${YELLOW}Type 'yes' to confirm: ${NC}"
  read -r confirm
  if [[ "${confirm}" == "yes" ]]; then
    for rg in "${RG_DNS}" "${RG_US}" "${RG_DR}"; do
      if rg_exists "${rg}"; then
        az group delete --name "${rg}" --yes --no-wait
        print_ok "Deletion initiated: ${rg}"
      else
        print_warn "Skipping '${rg}' — resource group does not exist"
      fi
    done
    print_ok "Deletion running in background. Run 'az group list -o table' to confirm."
  else
    print_ok "Cleanup cancelled"
  fi
}

# ── Full deployment in sequence ───────────────────────────────
full_deploy() {
  create_resource_groups || return 1
  create_vnets           || return 1
  deploy_dns_zones       || return 1
  create_regional_ips    || return 1
  deploy_traffic_manager || return 1
  enable_dnssec          || { print_warn "DNSSEC step failed — continuing"; }
  dns_query_demos
  simulate_dns_failure
}

# ── Main Menu ─────────────────────────────────────────────────
show_menu() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  Case Study 4: Global DNS Management Lab        ║${NC}"
  echo -e "${BLUE}║  Regions: East US (primary) | East US 2 (DR)   ║${NC}"
  echo -e "${BLUE}╠══════════════════════════════════════════════════╣${NC}"
  echo -e "${BLUE}║  1) Run full deployment (all steps)             ║${NC}"
  echo -e "${BLUE}║  2) Step 1: Create Resource Groups              ║${NC}"
  echo -e "${BLUE}║  3) Step 2: Create VNets                        ║${NC}"
  echo -e "${BLUE}║  4) Step 3: Deploy DNS Zones                    ║${NC}"
  echo -e "${BLUE}║  5) Step 4: Create Regional IPs                 ║${NC}"
  echo -e "${BLUE}║  6) Step 5: Deploy Traffic Manager              ║${NC}"
  echo -e "${BLUE}║  7) Step 6: Enable DNSSEC                       ║${NC}"
  echo -e "${BLUE}║  8) Step 7: DNS Failure Simulation              ║${NC}"
  echo -e "${BLUE}║  9) DNS Query Demonstrations                    ║${NC}"
  echo -e "${BLUE}║  c) Cleanup                                     ║${NC}"
  echo -e "${BLUE}║  0) Exit                                        ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
  echo -n "Select option: "
}

main() {
  run_step "Pre-flight" preflight || true   # warnings only, never block the menu

  while true; do
    show_menu
    read -r choice
    case "${choice}" in
      1) run_step "Full deployment"          full_deploy ;;
      2) run_step "Create Resource Groups"   create_resource_groups ;;
      3) run_step "Create VNets"             create_vnets ;;
      4) run_step "Deploy DNS Zones"         deploy_dns_zones ;;
      5) run_step "Create Regional IPs"      create_regional_ips ;;
      6) run_step "Deploy Traffic Manager"   deploy_traffic_manager ;;
      7) run_step "Enable DNSSEC"            enable_dnssec ;;
      8) run_step "DNS Failure Simulation"   simulate_dns_failure ;;
      9) run_step "DNS Query Demos"          dns_query_demos ;;
      c|C) run_step "Cleanup"               cleanup ;;
      0) echo "Exiting."; exit 0 ;;
      *) print_warn "Invalid option '${choice}'" ;;
    esac
  done
}

main "$@"
