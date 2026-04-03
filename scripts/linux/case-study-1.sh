#!/usr/bin/env bash
# ============================================================
# Case Study 1: Azure Dual-Region Disaster Recovery
# Primary: East US  |  DR Standby: East US 2
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
LOCATION_PRIMARY="eastus"
LOCATION_DR="eastus2"
ENVIRONMENT="prod"
COMPANY_PREFIX="cloudinn"

RESOURCE_GROUP_PRIMARY="rg-${COMPANY_PREFIX}-primary-${ENVIRONMENT}"
RESOURCE_GROUP_DR="rg-${COMPANY_PREFIX}-dr-${ENVIRONMENT}"

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/labs/case-study-1-dr"

VNET_NAME="${COMPANY_PREFIX}-vnet-${ENVIRONMENT}"
LB_PIP_NAME="pip-lb-${ENVIRONMENT}"
TM_PROFILE_NAME="tm-${COMPANY_PREFIX}-dr"

# ── Pre-flight checks ─────────────────────────────────────────
preflight() {
  print_header "Pre-flight Checks"
  print_step "Verifying Azure login..."
  az account show --query "{name:name, id:id}" -o table || print_error "Not logged in. Run: az login"
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  print_ok "Subscription: ${SUBSCRIPTION_ID}"
  print_step "Verifying Bicep..."
  az bicep version || print_error "Bicep not installed. Run: az bicep install"
  print_ok "Pre-flight checks passed"
  export SUBSCRIPTION_ID
}

# ── Step 1: Create Resource Groups ───────────────────────────
create_resource_groups() {
  print_header "Step 1: Create Resource Groups"

  print_step "Creating PRIMARY resource group: ${RESOURCE_GROUP_PRIMARY} (${LOCATION_PRIMARY})..."
  az group create \
    --name "${RESOURCE_GROUP_PRIMARY}" \
    --location "${LOCATION_PRIMARY}" \
    --tags "environment=${ENVIRONMENT}" "role=primary" "purpose=disaster-recovery" \
    --output table
  print_ok "${RESOURCE_GROUP_PRIMARY} created"

  print_step "Creating DR resource group: ${RESOURCE_GROUP_DR} (${LOCATION_DR})..."
  az group create \
    --name "${RESOURCE_GROUP_DR}" \
    --location "${LOCATION_DR}" \
    --tags "environment=${ENVIRONMENT}" "role=dr-standby" "purpose=disaster-recovery" \
    --output table
  print_ok "${RESOURCE_GROUP_DR} created"
}

# ── Step 2a: Deploy PRIMARY VNet (East US) ────────────────────
deploy_primary_vnet() {
  print_header "Step 2a: Deploy PRIMARY VNet & NSGs (East US)"
  echo ""
  echo "  Region: ${LOCATION_PRIMARY} (East US)"
  echo "  Address Space: 10.0.0.0/16"
  echo "  ├── subnet-web   10.0.1.0/24  (NSG: 443/80 from Internet)"
  echo "  ├── subnet-app   10.0.2.0/24  (NSG: 8080 from web tier)"
  echo "  ├── subnet-db    10.0.3.0/24  (NSG: 5432 from app tier)"
  echo "  └── AzureBastionSubnet 10.0.5.0/27"
  echo ""

  az deployment group create \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --template-file "${LAB_DIR}/01-vnet/main.bicep" \
    --parameters location="${LOCATION_PRIMARY}" environment="${ENVIRONMENT}" companyPrefix="${COMPANY_PREFIX}" \
    --name "deploy-vnet-primary-$(date +%Y%m%d%H%M%S)" \
    --output table

  PRIMARY_VNET_ID=$(az network vnet show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${VNET_NAME}" --query id -o tsv)
  print_ok "Primary VNet deployed: ${PRIMARY_VNET_ID}"
  export PRIMARY_VNET_ID
}

# ── Step 2b: Deploy DR VNet (East US 2) ──────────────────────
deploy_dr_vnet() {
  print_header "Step 2b: Deploy DR VNet & NSGs (East US 2)"
  echo ""
  echo "  Region: ${LOCATION_DR} (East US 2)"
  echo "  Same subnet layout as primary — mirrors the architecture"
  echo ""

  az deployment group create \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --template-file "${LAB_DIR}/01-vnet/main.bicep" \
    --parameters location="${LOCATION_DR}" environment="${ENVIRONMENT}" companyPrefix="${COMPANY_PREFIX}" \
    --name "deploy-vnet-dr-$(date +%Y%m%d%H%M%S)" \
    --output table

  DR_VNET_ID=$(az network vnet show \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --name "${VNET_NAME}" --query id -o tsv)
  print_ok "DR VNet deployed: ${DR_VNET_ID}"
  export DR_VNET_ID
}

# ── Step 3: Configure DNS Zones ──────────────────────────────
deploy_dns() {
  print_header "Step 3: Configure Azure DNS Zones (Primary Region)"
  echo ""
  echo "  Public zone:  ${COMPANY_PREFIX}-app.example.com (global)"
  echo "  Private zone: internal.${COMPANY_PREFIX}.azure (linked to primary VNet)"
  echo ""
  print_warn "After deployment, update NS records at your domain registrar."

  PRIMARY_VNET_ID=$(az network vnet show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${VNET_NAME}" --query id -o tsv)

  az deployment group create \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --template-file "${LAB_DIR}/02-dns/main.bicep" \
    --parameters "${LAB_DIR}/02-dns/parameters.json" \
    --parameters "vnetId=${PRIMARY_VNET_ID}" \
                 "publicDnsZoneName=${COMPANY_PREFIX}-app.example.com" \
                 "privateDnsZoneName=internal.${COMPANY_PREFIX}.azure" \
    --name "deploy-dns-$(date +%Y%m%d%H%M%S)" \
    --output table

  echo ""
  print_step "Azure DNS Name Servers (add to your domain registrar):"
  az network dns zone show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${COMPANY_PREFIX}-app.example.com" \
    --query nameServers --output table 2>/dev/null || print_warn "DNS zone retrieval skipped"

  print_ok "DNS zones deployed"
}

# ── Step 4a: Deploy PRIMARY App Infrastructure ────────────────
deploy_primary_infra() {
  print_header "Step 4a: Deploy PRIMARY App Infrastructure (East US)"
  echo ""
  echo "  ├── Load Balancer + Public IP"
  echo "  ├── Web VM (Ubuntu 22.04 + Nginx) — subnet-web"
  echo "  ├── App VM (Ubuntu 22.04)          — subnet-app"
  echo "  ├── Storage Account (Standard_LRS)"
  echo "  └── Azure SQL Database"
  echo ""

  _get_subnet_ids "${RESOURCE_GROUP_PRIMARY}"
  _deploy_infra "${RESOURCE_GROUP_PRIMARY}" "${LOCATION_PRIMARY}" "primary"

  PRIMARY_LB_PIP_ID=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${LB_PIP_NAME}" --query id -o tsv)
  PRIMARY_LB_PIP=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${LB_PIP_NAME}" --query ipAddress -o tsv 2>/dev/null || echo "pending")

  print_ok "Primary infrastructure deployed. LB IP: ${PRIMARY_LB_PIP}"
  export PRIMARY_LB_PIP_ID PRIMARY_LB_PIP
}

# ── Step 4b: Deploy DR App Infrastructure ────────────────────
deploy_dr_infra() {
  print_header "Step 4b: Deploy DR App Infrastructure (East US 2)"
  echo ""
  echo "  Identical stack to primary — kept on standby"
  echo ""

  _get_subnet_ids "${RESOURCE_GROUP_DR}"
  _deploy_infra "${RESOURCE_GROUP_DR}" "${LOCATION_DR}" "dr"

  DR_LB_PIP_ID=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --name "${LB_PIP_NAME}" --query id -o tsv)
  DR_LB_PIP=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --name "${LB_PIP_NAME}" --query ipAddress -o tsv 2>/dev/null || echo "pending")

  print_ok "DR infrastructure deployed. LB IP: ${DR_LB_PIP}"
  export DR_LB_PIP_ID DR_LB_PIP
}

# ── Internal helper: get subnet IDs ──────────────────────────
_get_subnet_ids() {
  local rg="$1"
  SUBNET_WEB_ID=$(az network vnet subnet show --resource-group "${rg}" \
    --vnet-name "${VNET_NAME}" --name "subnet-web" --query id -o tsv)
  SUBNET_APP_ID=$(az network vnet subnet show --resource-group "${rg}" \
    --vnet-name "${VNET_NAME}" --name "subnet-app" --query id -o tsv)
  SUBNET_DB_ID=$(az network vnet subnet show --resource-group "${rg}" \
    --vnet-name "${VNET_NAME}" --name "subnet-db" --query id -o tsv)
}

# ── Internal helper: deploy infra stack ──────────────────────
_deploy_infra() {
  local rg="$1"
  local location="$2"
  local role="$3"
  local VM_PASSWORD="AzureDR@Training2024!"
  print_warn "Using demo password. Use Azure Key Vault in production."

  az deployment group create \
    --resource-group "${rg}" \
    --template-file "${LAB_DIR}/03-arm-templates/main.bicep" \
    --parameters "location=${location}" \
                 "subnetWebId=${SUBNET_WEB_ID}" \
                 "subnetAppId=${SUBNET_APP_ID}" \
                 "subnetDbId=${SUBNET_DB_ID}" \
                 "adminPassword=${VM_PASSWORD}" \
    --name "deploy-infra-${role}-$(date +%Y%m%d%H%M%S)" \
    --output table
}

# ── Step 5: Deploy Traffic Manager ───────────────────────────
deploy_traffic_manager() {
  print_header "Step 5: Deploy Azure Traffic Manager"
  echo ""
  echo "  Routing method : Priority"
  echo "  Priority 1     : East US  (primary)  — receives all traffic"
  echo "  Priority 2     : East US 2 (DR)       — receives traffic only if P1 fails"
  echo "  TTL            : 30 seconds"
  echo "  Health probe   : HTTPS /health every 10s"
  echo "  Failover time  : ~30-60 seconds"
  echo ""

  PRIMARY_LB_PIP_ID=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${LB_PIP_NAME}" --query id -o tsv)
  DR_LB_PIP_ID=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --name "${LB_PIP_NAME}" --query id -o tsv)

  az deployment group create \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --template-file "${LAB_DIR}/04-traffic-manager/main.bicep" \
    --parameters "companyPrefix=${COMPANY_PREFIX}" \
                 "primaryPublicIpId=${PRIMARY_LB_PIP_ID}" \
                 "drPublicIpId=${DR_LB_PIP_ID}" \
                 "dnsTtl=30" \
    --name "deploy-tm-$(date +%Y%m%d%H%M%S)" \
    --output table

  TM_FQDN=$(az network traffic-manager profile show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${TM_PROFILE_NAME}" \
    --query dnsConfig.fqdn -o tsv)

  print_ok "Traffic Manager deployed: ${TM_FQDN}"
  export TM_FQDN
}

# ── Step 6: Failover Test ─────────────────────────────────────
run_failover_test() {
  print_header "Step 6: Failover Test — East US → East US 2"
  echo ""
  echo "  Simulates East US (primary) going offline."
  echo "  Traffic Manager should automatically route to East US 2."
  echo ""
  pause

  TM_FQDN=$(az network traffic-manager profile show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${TM_PROFILE_NAME}" \
    --query dnsConfig.fqdn -o tsv)

  print_step "BEFORE FAILOVER — DNS should resolve to East US (primary) IP:"
  nslookup "${TM_FQDN}" || dig "${TM_FQDN}" A || true

  print_step "Disabling East US primary endpoint (simulating regional outage)..."
  az network traffic-manager endpoint update \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --profile-name "${TM_PROFILE_NAME}" \
    --name "endpoint-eastus-primary" \
    --type azureEndpoints \
    --endpoint-status Disabled
  print_ok "East US endpoint disabled"

  print_step "Waiting 60 seconds (probe interval × failure threshold + TTL)..."
  for i in {60..1}; do
    printf "\r  ${YELLOW}Waiting: %3d seconds remaining${NC}" "${i}"
    sleep 1
  done
  echo ""

  print_step "AFTER FAILOVER — DNS should now resolve to East US 2 (DR) IP:"
  nslookup "${TM_FQDN}" || dig "${TM_FQDN}" A || true

  print_step "East US 2 endpoint health status:"
  az network traffic-manager endpoint show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --profile-name "${TM_PROFILE_NAME}" \
    --name "endpoint-eastus2-dr" \
    --type azureEndpoints \
    --query properties.endpointMonitorStatus -o tsv

  echo ""
  print_warn "--- FAILBACK: Re-enabling East US primary ---"
  pause

  az network traffic-manager endpoint update \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --profile-name "${TM_PROFILE_NAME}" \
    --name "endpoint-eastus-primary" \
    --type azureEndpoints \
    --endpoint-status Enabled
  print_ok "East US endpoint re-enabled. Traffic will fail back within ~60 seconds."

  print_step "DNS after failback (expect East US IP again):"
  sleep 30
  nslookup "${TM_FQDN}" || dig "${TM_FQDN}" A || true

  print_ok "Failover test complete!"
}

# ── Verify Deployment ─────────────────────────────────────────
verify_deployment() {
  print_header "Deployment Verification"

  print_step "Resources in PRIMARY (${RESOURCE_GROUP_PRIMARY}):"
  az resource list --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --query "[].{Name:name, Type:type, Location:location}" --output table

  print_step "Resources in DR (${RESOURCE_GROUP_DR}):"
  az resource list --resource-group "${RESOURCE_GROUP_DR}" \
    --query "[].{Name:name, Type:type, Location:location}" --output table

  print_step "Traffic Manager endpoints:"
  az network traffic-manager endpoint list \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --profile-name "${TM_PROFILE_NAME}" \
    --query "[].{Name:name, Priority:properties.priority, Status:properties.endpointStatus, Health:properties.endpointMonitorStatus}" \
    --output table 2>/dev/null || true

  print_step "Primary VNet subnets:"
  az network vnet subnet list \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --vnet-name "${VNET_NAME}" \
    --query "[].{Name:name, CIDR:addressPrefix}" --output table

  print_ok "Verification complete"
}

# ── Cleanup ───────────────────────────────────────────────────
cleanup() {
  print_header "Cleanup"
  print_warn "This will delete BOTH resource groups and all resources!"
  echo -e "Type 'yes' to confirm: "
  read -r confirm
  if [[ "${confirm}" == "yes" ]]; then
    for rg in "${RESOURCE_GROUP_PRIMARY}" "${RESOURCE_GROUP_DR}"; do
      if az group show --name "${rg}" &>/dev/null; then
        az group delete --name "${rg}" --yes --no-wait
        print_ok "Deletion initiated: ${rg}"
      else
        print_warn "Skipping ${rg} (does not exist)"
      fi
    done
  else
    print_ok "Cleanup cancelled"
  fi
}

# ── Main Menu ─────────────────────────────────────────────────
show_menu() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  Case Study 1: Azure Dual-Region DR Lab             ║${NC}"
  echo -e "${BLUE}║  Primary: East US  |  DR Standby: East US 2        ║${NC}"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
  echo -e "${BLUE}║  1) Run full deployment (all steps)                 ║${NC}"
  echo -e "${BLUE}║  2) Step 1:  Create Resource Groups                 ║${NC}"
  echo -e "${BLUE}║  3) Step 2a: Deploy PRIMARY VNet (East US)          ║${NC}"
  echo -e "${BLUE}║  4) Step 2b: Deploy DR VNet (East US 2)             ║${NC}"
  echo -e "${BLUE}║  5) Step 3:  Deploy DNS Zones                       ║${NC}"
  echo -e "${BLUE}║  6) Step 4a: Deploy PRIMARY Infrastructure          ║${NC}"
  echo -e "${BLUE}║  7) Step 4b: Deploy DR Infrastructure               ║${NC}"
  echo -e "${BLUE}║  8) Step 5:  Deploy Traffic Manager                 ║${NC}"
  echo -e "${BLUE}║  9) Step 6:  Run Failover Test                      ║${NC}"
  echo -e "${BLUE}║  v) Verify Deployment                               ║${NC}"
  echo -e "${BLUE}║  c) Cleanup (delete all resources)                  ║${NC}"
  echo -e "${BLUE}║  0) Exit                                            ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
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
        deploy_primary_vnet
        deploy_dr_vnet
        deploy_dns
        deploy_primary_infra
        deploy_dr_infra
        deploy_traffic_manager
        verify_deployment
        run_failover_test
        ;;
      2) create_resource_groups ;;
      3) deploy_primary_vnet ;;
      4) deploy_dr_vnet ;;
      5) deploy_dns ;;
      6) deploy_primary_infra ;;
      7) deploy_dr_infra ;;
      8) deploy_traffic_manager ;;
      9) run_failover_test ;;
      v|V) verify_deployment ;;
      c|C) cleanup ;;
      0) echo "Exiting."; exit 0 ;;
      *) print_warn "Invalid option" ;;
    esac
  done
}

main "$@"
