#!/usr/bin/env bash
# ============================================================
# Case Study 4: Scalable and Secure DNS Management
# Dual-region DNS for ShopEasy e-commerce
# Regions: East US (primary) | East US 2 (DR / secondary)
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

print_header() { echo -e "\n${BLUE}═══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}═══════════════════════════════════════${NC}"; }
print_step()   { echo -e "${CYAN}[STEP]${NC} $1"; }
print_ok()     { echo -e "${GREEN}[  OK]${NC} $1"; }
print_warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()  { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
pause()        { echo -e "${YELLOW}Press ENTER to continue...${NC}"; read -r; }

# ── Configuration ─────────────────────────────────────────────
COMPANY="shopeasy"
LOCATION_US="eastus"
LOCATION_DR="eastus2"
DOMAIN_NAME="shopeasy.example.com"

RG_DNS="rg-${COMPANY}-dns"
RG_US="rg-${COMPANY}-us"
RG_DR="rg-${COMPANY}-eastus2"

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/labs/case-study-4-dns"

# Placeholder IPs (replaced by real IPs after public IP creation)
EAST_US_LB_IP="20.10.5.100"
EAST_US2_LB_IP="20.40.5.100"

# ── Pre-flight checks ─────────────────────────────────────────
preflight() {
  print_header "Pre-flight Checks"
  az account show --query "{name:name, id:id}" -o table || print_error "Not logged in. Run: az login"
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  print_ok "Subscription: ${SUBSCRIPTION_ID}"
  export SUBSCRIPTION_ID
}

# ── Step 1: Create Resource Groups ───────────────────────────
create_resource_groups() {
  print_header "Step 1: Create Resource Groups"
  echo ""
  echo "  rg-shopeasy-dns    → ${LOCATION_US}  (DNS zones + Traffic Manager)"
  echo "  rg-shopeasy-us     → ${LOCATION_US}  (East US primary endpoint)"
  echo "  rg-shopeasy-eastus2 → ${LOCATION_DR} (East US 2 DR endpoint)"
  echo ""

  for rg_info in "${RG_DNS}:${LOCATION_US}" "${RG_US}:${LOCATION_US}" "${RG_DR}:${LOCATION_DR}"; do
    RG="${rg_info%%:*}"
    LOC="${rg_info##*:}"
    print_step "Creating ${RG} in ${LOC}..."
    az group create --name "${RG}" --location "${LOC}" \
      --tags "company=${COMPANY}" "purpose=dns-management" \
      --output table
    print_ok "${RG} created"
  done
}

# ── Step 2: Create VNets (needed for private DNS) ─────────────
create_vnets() {
  print_header "Step 2: Create VNets for Private DNS Zone Linking"

  print_step "Creating VNet in East US (${RG_US})..."
  az network vnet create \
    --resource-group "${RG_US}" \
    --name "vnet-${COMPANY}-prod" \
    --address-prefix "10.0.0.0/16" \
    --subnet-name "subnet-app" \
    --subnet-prefix "10.0.1.0/24" \
    --location "${LOCATION_US}" \
    --output table

  VNET_ID=$(az network vnet show \
    --resource-group "${RG_US}" \
    --name "vnet-${COMPANY}-prod" \
    --query id -o tsv)
  print_ok "East US VNet: ${VNET_ID}"

  print_step "Creating VNet in East US 2 (${RG_DR})..."
  az network vnet create \
    --resource-group "${RG_DR}" \
    --name "vnet-${COMPANY}-dr" \
    --address-prefix "10.0.0.0/16" \
    --subnet-name "subnet-app" \
    --subnet-prefix "10.0.1.0/24" \
    --location "${LOCATION_DR}" \
    --output table

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

  VNET_ID=$(az network vnet show \
    --resource-group "${RG_US}" \
    --name "vnet-${COMPANY}-prod" \
    --query id -o tsv)

  VNET_DR_ID=$(az network vnet show \
    --resource-group "${RG_DR}" \
    --name "vnet-${COMPANY}-dr" \
    --query id -o tsv 2>/dev/null || echo "")

  az deployment group create \
    --resource-group "${RG_DNS}" \
    --template-file "${LAB_DIR}/01-dns-zones/main.bicep" \
    --parameters "${LAB_DIR}/01-dns-zones/parameters.json" \
    --parameters "vnetId=${VNET_ID}" \
                 "eastUs2VnetId=${VNET_DR_ID}" \
                 "lbPublicIp=${EAST_US_LB_IP}" \
                 "eastUsLbIp=${EAST_US_LB_IP}" \
                 "eastUs2LbIp=${EAST_US2_LB_IP}" \
    --name "deploy-dns-$(date +%Y%m%d%H%M%S)" \
    --output table

  print_step "Azure Name Servers for ${DOMAIN_NAME}:"
  az network dns zone show \
    --resource-group "${RG_DNS}" \
    --name "${DOMAIN_NAME}" \
    --query nameServers \
    --output table

  print_warn "IMPORTANT: Update NS records at your domain registrar to enable Azure DNS."
  print_ok "DNS zones deployed"
}

# ── Step 4: Create Regional Public IPs ───────────────────────
create_regional_ips() {
  print_header "Step 4: Create Regional Public IP Addresses"
  print_step "Creating public IPs in East US and East US 2..."

  az network public-ip create \
    --resource-group "${RG_US}" \
    --name "pip-lb-us-prod" \
    --sku Standard \
    --allocation-method Static \
    --location "${LOCATION_US}" \
    --output table

  az network public-ip create \
    --resource-group "${RG_DR}" \
    --name "pip-lb-eastus2-prod" \
    --sku Standard \
    --allocation-method Static \
    --location "${LOCATION_DR}" \
    --output table

  US_PIP_ID=$(az network public-ip show --resource-group "${RG_US}" --name "pip-lb-us-prod" --query id -o tsv)
  DR_PIP_ID=$(az network public-ip show --resource-group "${RG_DR}" --name "pip-lb-eastus2-prod" --query id -o tsv)

  US_PIP_ADDR=$(az network public-ip show --resource-group "${RG_US}" --name "pip-lb-us-prod" --query ipAddress -o tsv)
  DR_PIP_ADDR=$(az network public-ip show --resource-group "${RG_DR}" --name "pip-lb-eastus2-prod" --query ipAddress -o tsv)

  print_ok "East US IP:  ${US_PIP_ADDR} (${US_PIP_ID})"
  print_ok "East US 2 IP: ${DR_PIP_ADDR} (${DR_PIP_ID})"
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

  US_PIP_ID=$(az network public-ip show --resource-group "${RG_US}" --name "pip-lb-us-prod" --query id -o tsv)
  DR_PIP_ID=$(az network public-ip show --resource-group "${RG_DR}" --name "pip-lb-eastus2-prod" --query id -o tsv)

  az deployment group create \
    --resource-group "${RG_DNS}" \
    --template-file "${LAB_DIR}/02-traffic-manager/main.bicep" \
    --parameters "${LAB_DIR}/02-traffic-manager/parameters.json" \
    --parameters "eastUsPublicIpId=${US_PIP_ID}" \
                 "eastUs2PublicIpId=${DR_PIP_ID}" \
    --name "deploy-tm-$(date +%Y%m%d%H%M%S)" \
    --output table

  print_step "Traffic Manager profiles created:"
  az network traffic-manager profile list \
    --resource-group "${RG_DNS}" \
    --query "[].{Name:name, RoutingMethod:trafficRoutingMethod, DNS:dnsConfig.fqdn}" \
    --output table

  print_ok "Traffic Manager deployed"
}

# ── Step 6: Enable DNSSEC ─────────────────────────────────────
enable_dnssec() {
  print_header "Step 6: Enable DNSSEC"
  echo ""
  echo "  DNSSEC protects ${DOMAIN_NAME} against DNS spoofing."
  echo "  Azure will sign all DNS records with cryptographic keys."
  echo ""
  print_warn "NOTE: After enabling, you MUST add the DS record to your domain registrar."
  pause

  az deployment group create \
    --resource-group "${RG_DNS}" \
    --template-file "${LAB_DIR}/03-dnssec/main.bicep" \
    --parameters "dnsZoneName=${DOMAIN_NAME}" \
                 "dnsZoneResourceGroup=${RG_DNS}" \
    --name "deploy-dnssec-$(date +%Y%m%d%H%M%S)" \
    --output table 2>/dev/null || {
      print_warn "DNSSEC via Bicep requires preview API. Trying Azure CLI..."
      az network dns dnssec-config create \
        --resource-group "${RG_DNS}" \
        --zone-name "${DOMAIN_NAME}" 2>/dev/null || \
        print_warn "DNSSEC is in preview. Enable manually in Azure portal for: ${DOMAIN_NAME}"
    }

  print_step "Retrieving DS records for registrar..."
  az network dns dnssec-config show \
    --resource-group "${RG_DNS}" \
    --zone-name "${DOMAIN_NAME}" \
    --query "signingKeys[].delegationSignerInfo" 2>/dev/null || \
    print_warn "DNSSEC signing keys not yet available. Check back after provisioning completes."

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
  pause

  TM_FAILOVER=$(az network traffic-manager profile show \
    --resource-group "${RG_DNS}" \
    --name "tm-${COMPANY}-failover" \
    --query dnsConfig.fqdn -o tsv 2>/dev/null || echo "tm not found")

  if [[ "${TM_FAILOVER}" != "tm not found" ]]; then
    print_step "Current DNS resolution (East US should be primary):"
    nslookup "${TM_FAILOVER}" 2>/dev/null || dig "${TM_FAILOVER}" A 2>/dev/null || true

    print_step "Disabling East US endpoint (simulating regional failure)..."
    az network traffic-manager endpoint update \
      --resource-group "${RG_DNS}" \
      --profile-name "tm-${COMPANY}-failover" \
      --name "primary-east-us" \
      --type azureEndpoints \
      --endpoint-status Disabled

    print_step "Waiting 60 seconds for Traffic Manager to detect failure..."
    for i in {60..1}; do
      printf "\r  ${YELLOW}Waiting: %3d seconds${NC}" "${i}"
      sleep 1
    done
    echo ""

    print_step "DNS resolution after failure (should be East US 2 IP):"
    nslookup "${TM_FAILOVER}" 2>/dev/null || dig "${TM_FAILOVER}" A 2>/dev/null || true

    print_step "Re-enabling East US endpoint (recovery)..."
    az network traffic-manager endpoint update \
      --resource-group "${RG_DNS}" \
      --profile-name "tm-${COMPANY}-failover" \
      --name "primary-east-us" \
      --type azureEndpoints \
      --endpoint-status Enabled

    print_ok "DNS failure simulation complete. East US re-enabled."
  else
    print_warn "Traffic Manager not deployed yet. Run step 5 first."
  fi
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
    --query nameServers -o table 2>/dev/null || echo "  Zone not deployed yet"

  print_step "Query A records:"
  echo "  nslookup www.${DOMAIN_NAME}"
  nslookup "www.${DOMAIN_NAME}" 2>/dev/null || true

  print_step "Query regional subdomains:"
  echo "  us.${DOMAIN_NAME}  → East US primary"
  echo "  dr.${DOMAIN_NAME}  → East US 2 DR"
  nslookup "us.${DOMAIN_NAME}" 2>/dev/null || true

  print_step "Query MX records:"
  dig MX "${DOMAIN_NAME}" +short 2>/dev/null || nslookup -type=MX "${DOMAIN_NAME}" 2>/dev/null || true

  print_step "Query TXT records (SPF):"
  dig TXT "${DOMAIN_NAME}" +short 2>/dev/null || nslookup -type=TXT "${DOMAIN_NAME}" 2>/dev/null || true

  print_step "Check DNSSEC (should show AD flag if enabled and propagated):"
  dig +dnssec "${DOMAIN_NAME}" SOA 2>/dev/null | grep -E "flags:|RRSIG" || true

  print_step "List all DNS records in zone:"
  az network dns record-set list \
    --resource-group "${RG_DNS}" \
    --zone-name "${DOMAIN_NAME}" \
    --query "[].{Name:name, Type:type, TTL:ttl}" \
    --output table 2>/dev/null || true
}

# ── Cleanup ───────────────────────────────────────────────────
cleanup() {
  print_header "Cleanup"
  print_warn "This will delete ALL resource groups and resources!"
  echo -e "Type 'yes' to confirm: "
  read -r confirm
  if [[ "${confirm}" == "yes" ]]; then
    for rg in "${RG_DNS}" "${RG_US}" "${RG_DR}"; do
      if az group exists --name "${rg}" | grep -q "true"; then
        az group delete --name "${rg}" --yes --no-wait && print_ok "Deleting ${rg}..."
      else
        print_warn "${rg} does not exist, skipping."
      fi
    done
    print_ok "Deletion initiated for all resource groups"
  else
    print_ok "Cleanup cancelled"
  fi
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
  preflight
  while true; do
    show_menu
    read -r choice
    case "${choice}" in
      1)
        create_resource_groups
        create_vnets
        deploy_dns_zones
        create_regional_ips
        deploy_traffic_manager
        enable_dnssec
        dns_query_demos
        simulate_dns_failure
        ;;
      2) create_resource_groups ;;
      3) create_vnets ;;
      4) deploy_dns_zones ;;
      5) create_regional_ips ;;
      6) deploy_traffic_manager ;;
      7) enable_dnssec ;;
      8) simulate_dns_failure ;;
      9) dns_query_demos ;;
      c|C) cleanup ;;
      0) echo "Exiting."; exit 0 ;;
      *) print_warn "Invalid option" ;;
    esac
  done
}

main "$@"
