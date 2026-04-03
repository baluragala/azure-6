#!/usr/bin/env bash
# ============================================================
# Case Study 1: Azure Dual-Region Disaster Recovery
# Primary: East US  |  DR Standby: East US 2
#
# Best-practice hardening:
#   • No global set -e  → step errors return to menu, not exit
#   • set -uo pipefail  → unbound vars + broken pipes still fatal
#   • Idempotent ops    → safe to re-run any step at any time
#   • Retry wrapper     → 3 attempts with exp. backoff for az calls
#   • Prereq guards     → each step validates its dependencies first
#   • --output none     → avoids "content already consumed" ARM bug
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

# ── Idempotency helpers ───────────────────────────────────────
rg_exists()        { az group show                   --name "$1"                          &>/dev/null; }
vnet_exists()      { az network vnet show            --resource-group "$1" --name "$2"   &>/dev/null; }
pip_exists()       { az network public-ip show       --resource-group "$1" --name "$2"   &>/dev/null; }
tm_profile_exists(){ az network traffic-manager profile show --resource-group "$1" --name "$2" &>/dev/null; }
dns_zone_exists()  { az network dns zone show        --resource-group "$1" --name "$2"   &>/dev/null; }
vm_exists()        { az vm show                      --resource-group "$1" --name "$2"   &>/dev/null; }

# ── Deploy wrapper: runs az deployment group create without --output table
#    "--output table" causes "content already consumed" in Azure CLI when
#    ARM returns an async polling response. Use --output none + post-query.
az_deploy() {
  local deploy_name="${1}"; shift    # first arg is the deployment name label for logging
  print_step "Deploying: ${deploy_name} (this may take several minutes)..."
  az deployment group create \
    --output none \
    "$@" || return 1
  print_ok "Deployment complete: ${deploy_name}"
}

# ── Retry wrapper (3 attempts, exponential backoff) ──────────
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
  print_error "Azure CLI command failed after ${max_attempts} attempts."
  return 1
}

# ── Step runner: isolates failures so menu stays alive ───────
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
    print_warn "Neither nslookup nor dig found — DNS query demos will be skipped."

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
    az_retry group create \
      --name "${rg}" \
      --location "${loc}" \
      --tags ${tags} \
      --output table || return 1
    print_ok "${rg} created"
  fi
}

# ── Step 1: Create Resource Groups ───────────────────────────
create_resource_groups() {
  print_header "Step 1: Create Resource Groups"
  local tags="environment=${ENVIRONMENT} role=primary purpose=disaster-recovery"
  _create_rg "${RESOURCE_GROUP_PRIMARY}" "${LOCATION_PRIMARY}" "${tags}" || return 1
  _create_rg "${RESOURCE_GROUP_DR}"      "${LOCATION_DR}"      "${tags}" || return 1
}

# ── Step 2a: Deploy PRIMARY VNet (East US) ────────────────────
deploy_primary_vnet() {
  print_header "Step 2a: Deploy PRIMARY VNet & NSGs (East US)"
  echo ""
  echo "  Region: ${LOCATION_PRIMARY} (East US)"
  echo "  Address Space: 10.0.0.0/16"
  echo "  ├── subnet-web     10.0.1.0/24  (NSG: 443/80 from Internet)"
  echo "  ├── subnet-app     10.0.2.0/24  (NSG: 8080 from web tier)"
  echo "  ├── subnet-db      10.0.3.0/24  (NSG: 5432 from app tier)"
  echo "  └── subnet-gateway 10.0.4.0/27"
  echo ""

  rg_exists "${RESOURCE_GROUP_PRIMARY}" || {
    print_error "Resource group '${RESOURCE_GROUP_PRIMARY}' not found. Run Step 1 first."
    return 1
  }

  if vnet_exists "${RESOURCE_GROUP_PRIMARY}" "${VNET_NAME}"; then
    print_ok "Primary VNet '${VNET_NAME}' already exists — skipping deployment"
  else
    az_deploy "Primary VNet" \
      --resource-group "${RESOURCE_GROUP_PRIMARY}" \
      --template-file "${LAB_DIR}/01-vnet/main.bicep" \
      --parameters location="${LOCATION_PRIMARY}" environment="${ENVIRONMENT}" companyPrefix="${COMPANY_PREFIX}" \
      --name "deploy-vnet-primary-$(date +%Y%m%d%H%M%S)" || return 1
  fi

  PRIMARY_VNET_ID=$(az network vnet show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${VNET_NAME}" --query id -o tsv)
  print_ok "Primary VNet: ${PRIMARY_VNET_ID}"
  export PRIMARY_VNET_ID
}

# ── Step 2b: Deploy DR VNet (East US 2) ──────────────────────
deploy_dr_vnet() {
  print_header "Step 2b: Deploy DR VNet & NSGs (East US 2)"
  echo ""
  echo "  Region: ${LOCATION_DR} (East US 2)"
  echo "  Same subnet layout as primary — mirrors the architecture"
  echo ""

  rg_exists "${RESOURCE_GROUP_DR}" || {
    print_error "Resource group '${RESOURCE_GROUP_DR}' not found. Run Step 1 first."
    return 1
  }

  if vnet_exists "${RESOURCE_GROUP_DR}" "${VNET_NAME}"; then
    print_ok "DR VNet '${VNET_NAME}' already exists — skipping deployment"
  else
    az_deploy "DR VNet" \
      --resource-group "${RESOURCE_GROUP_DR}" \
      --template-file "${LAB_DIR}/01-vnet/main.bicep" \
      --parameters location="${LOCATION_DR}" environment="${ENVIRONMENT}" companyPrefix="${COMPANY_PREFIX}" \
      --name "deploy-vnet-dr-$(date +%Y%m%d%H%M%S)" || return 1
  fi

  DR_VNET_ID=$(az network vnet show \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --name "${VNET_NAME}" --query id -o tsv)
  print_ok "DR VNet: ${DR_VNET_ID}"
  export DR_VNET_ID
}

# ── Step 3: Configure DNS Zones ──────────────────────────────
deploy_dns() {
  print_header "Step 3: Configure Azure DNS Zones (Primary Region)"
  echo ""
  echo "  Public zone:  ${COMPANY_PREFIX}-app.example.com (global)"
  echo "  Private zone: internal.${COMPANY_PREFIX}.azure (linked to primary VNet)"
  echo ""

  rg_exists "${RESOURCE_GROUP_PRIMARY}" || {
    print_error "Primary resource group not found. Run Step 1 first."
    return 1
  }
  vnet_exists "${RESOURCE_GROUP_PRIMARY}" "${VNET_NAME}" || {
    print_error "Primary VNet not found. Run Step 2a first."
    return 1
  }

  PRIMARY_VNET_ID=$(az network vnet show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${VNET_NAME}" --query id -o tsv)

  if dns_zone_exists "${RESOURCE_GROUP_PRIMARY}" "${COMPANY_PREFIX}-app.example.com"; then
    print_ok "DNS zones already exist — re-deploying to reconcile records"
  fi

  az_deploy "DNS Zones" \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --template-file "${LAB_DIR}/02-dns/main.bicep" \
    --parameters "${LAB_DIR}/02-dns/parameters.json" \
    --parameters "vnetId=${PRIMARY_VNET_ID}" \
                 "publicDnsZoneName=${COMPANY_PREFIX}-app.example.com" \
                 "privateDnsZoneName=internal.${COMPANY_PREFIX}.azure" \
    --name "deploy-dns-$(date +%Y%m%d%H%M%S)" || return 1

  print_step "Azure DNS Name Servers (add to your domain registrar):"
  az network dns zone show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${COMPANY_PREFIX}-app.example.com" \
    --query nameServers --output table 2>/dev/null || print_warn "DNS zone retrieval skipped"

  print_warn "After deployment, update NS records at your domain registrar."
  print_ok "DNS zones deployed"
}

# ── Step 4a: Deploy PRIMARY App Infrastructure ────────────────
deploy_primary_infra() {
  print_header "Step 4a: Deploy PRIMARY App Infrastructure (East US)"
  echo ""
  echo "  ├── Load Balancer + Public IP (${LB_PIP_NAME})"
  echo "  ├── Web VM (Ubuntu 22.04 + Nginx) — subnet-web"
  echo "  ├── App VM (Ubuntu 22.04)          — subnet-app"
  echo "  ├── Storage Account (Standard_LRS)"
  echo "  └── Azure SQL Database"
  echo ""

  rg_exists "${RESOURCE_GROUP_PRIMARY}" || {
    print_error "Primary resource group not found. Run Step 1 first."
    return 1
  }
  vnet_exists "${RESOURCE_GROUP_PRIMARY}" "${VNET_NAME}" || {
    print_error "Primary VNet not found. Run Step 2a first."
    return 1
  }

  # Check if the full infra stack is already deployed (LB PIP + both VMs)
  if pip_exists "${RESOURCE_GROUP_PRIMARY}" "${LB_PIP_NAME}" && \
     vm_exists  "${RESOURCE_GROUP_PRIMARY}" "vm-web-${ENVIRONMENT}" && \
     vm_exists  "${RESOURCE_GROUP_PRIMARY}" "vm-app-${ENVIRONMENT}"; then
    print_ok "Primary infrastructure already deployed (LB PIP + VMs found) — skipping"
  else
    _get_subnet_ids "${RESOURCE_GROUP_PRIMARY}" || return 1
    _deploy_infra   "${RESOURCE_GROUP_PRIMARY}" "${LOCATION_PRIMARY}" "primary" || return 1
  fi

  PRIMARY_LB_PIP_ID=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${LB_PIP_NAME}" --query id -o tsv 2>/dev/null || echo "")
  PRIMARY_LB_PIP=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${LB_PIP_NAME}" --query ipAddress -o tsv 2>/dev/null || echo "pending")

  [[ -z "${PRIMARY_LB_PIP_ID}" ]] && {
    print_warn "LB Public IP not found yet — it may still be provisioning."
  }

  print_ok "Primary infrastructure ready. LB IP: ${PRIMARY_LB_PIP}"
  export PRIMARY_LB_PIP_ID PRIMARY_LB_PIP
}

# ── Step 4b: Deploy DR App Infrastructure ────────────────────
deploy_dr_infra() {
  print_header "Step 4b: Deploy DR App Infrastructure (East US 2)"
  echo ""
  echo "  Identical stack to primary — kept on standby"
  echo ""

  rg_exists "${RESOURCE_GROUP_DR}" || {
    print_error "DR resource group not found. Run Step 1 first."
    return 1
  }
  vnet_exists "${RESOURCE_GROUP_DR}" "${VNET_NAME}" || {
    print_error "DR VNet not found. Run Step 2b first."
    return 1
  }

  # Check if the full infra stack is already deployed (LB PIP + both VMs)
  if pip_exists "${RESOURCE_GROUP_DR}" "${LB_PIP_NAME}" && \
     vm_exists  "${RESOURCE_GROUP_DR}" "vm-web-${ENVIRONMENT}" && \
     vm_exists  "${RESOURCE_GROUP_DR}" "vm-app-${ENVIRONMENT}"; then
    print_ok "DR infrastructure already deployed (LB PIP + VMs found) — skipping"
  else
    _get_subnet_ids "${RESOURCE_GROUP_DR}" || return 1
    _deploy_infra   "${RESOURCE_GROUP_DR}" "${LOCATION_DR}" "dr" || return 1
  fi

  DR_LB_PIP_ID=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --name "${LB_PIP_NAME}" --query id -o tsv 2>/dev/null || echo "")
  DR_LB_PIP=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --name "${LB_PIP_NAME}" --query ipAddress -o tsv 2>/dev/null || echo "pending")

  [[ -z "${DR_LB_PIP_ID}" ]] && {
    print_warn "DR LB Public IP not found yet — it may still be provisioning."
  }

  print_ok "DR infrastructure ready. LB IP: ${DR_LB_PIP}"
  export DR_LB_PIP_ID DR_LB_PIP
}

# ── Internal helper: get subnet IDs ──────────────────────────
_get_subnet_ids() {
  local rg="$1"
  SUBNET_WEB_ID=$(az network vnet subnet show --resource-group "${rg}" \
    --vnet-name "${VNET_NAME}" --name "subnet-web" --query id -o tsv 2>/dev/null || echo "")
  SUBNET_APP_ID=$(az network vnet subnet show --resource-group "${rg}" \
    --vnet-name "${VNET_NAME}" --name "subnet-app" --query id -o tsv 2>/dev/null || echo "")

  if [[ -z "${SUBNET_WEB_ID}" || -z "${SUBNET_APP_ID}" ]]; then
    print_error "Could not retrieve subnet IDs from '${rg}'. Ensure the VNet was deployed."
    return 1
  fi
  export SUBNET_WEB_ID SUBNET_APP_ID
}

# ── Internal helper: deploy infra stack ──────────────────────
_deploy_infra() {
  local rg="$1"
  local location="$2"
  local role="$3"

  # Training default password — override with CS1_VM_PASSWORD env var.
  # Azure requirements: 12+ chars, upper + lower + digit + symbol.
  local DEFAULT_PASSWORD="AzureLab@Train24!"
  local VM_PASSWORD="${CS1_VM_PASSWORD:-${DEFAULT_PASSWORD}}"
  print_warn "VM password: ${VM_PASSWORD:0:4}***  (export CS1_VM_PASSWORD=<pass> to override)"
  print_warn "IMPORTANT: Change this password before any non-lab use."

  az_deploy "Infra stack (${role})" \
    --resource-group "${rg}" \
    --template-file "${LAB_DIR}/03-arm-templates/main.bicep" \
    --parameters "location=${location}" \
                 "subnetWebId=${SUBNET_WEB_ID}" \
                 "subnetAppId=${SUBNET_APP_ID}" \
                 "adminPassword=${VM_PASSWORD}" \
    --name "deploy-infra-${role}-$(date +%Y%m%d%H%M%S)"
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

  pip_exists "${RESOURCE_GROUP_PRIMARY}" "${LB_PIP_NAME}" || {
    print_error "Primary LB Public IP '${LB_PIP_NAME}' not found. Run Step 4a first."
    return 1
  }
  pip_exists "${RESOURCE_GROUP_DR}" "${LB_PIP_NAME}" || {
    print_error "DR LB Public IP '${LB_PIP_NAME}' not found. Run Step 4b first."
    return 1
  }

  PRIMARY_LB_PIP_ID=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${LB_PIP_NAME}" --query id -o tsv)
  DR_LB_PIP_ID=$(az network public-ip show \
    --resource-group "${RESOURCE_GROUP_DR}" \
    --name "${LB_PIP_NAME}" --query id -o tsv)

  if tm_profile_exists "${RESOURCE_GROUP_PRIMARY}" "${TM_PROFILE_NAME}"; then
    print_ok "Traffic Manager profile already exists — re-deploying to reconcile"
  fi

  az_deploy "Traffic Manager" \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --template-file "${LAB_DIR}/04-traffic-manager/main.bicep" \
    --parameters "companyPrefix=${COMPANY_PREFIX}" \
                 "primaryPublicIpId=${PRIMARY_LB_PIP_ID}" \
                 "drPublicIpId=${DR_LB_PIP_ID}" \
                 "dnsTtl=30" \
    --name "deploy-tm-$(date +%Y%m%d%H%M%S)" || return 1

  TM_FQDN=$(az network traffic-manager profile show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${TM_PROFILE_NAME}" \
    --query dnsConfig.fqdn -o tsv 2>/dev/null || echo "")

  [[ -z "${TM_FQDN}" ]] && {
    print_warn "Could not read Traffic Manager FQDN — it may still be provisioning."
    return 0
  }

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

  tm_profile_exists "${RESOURCE_GROUP_PRIMARY}" "${TM_PROFILE_NAME}" || {
    print_error "Traffic Manager profile not found. Run Step 5 first."
    return 1
  }

  pause

  TM_FQDN=$(az network traffic-manager profile show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --name "${TM_PROFILE_NAME}" \
    --query dnsConfig.fqdn -o tsv)

  print_step "BEFORE FAILOVER — current DNS resolution:"
  nslookup "${TM_FQDN}" 2>/dev/null || dig "${TM_FQDN}" A 2>/dev/null || \
    print_warn "DNS query tools unavailable — skipping resolution check"

  print_step "Disabling East US primary endpoint (simulating regional outage)..."
  az_retry network traffic-manager endpoint update \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --profile-name "${TM_PROFILE_NAME}" \
    --name "endpoint-eastus-primary" \
    --type azureEndpoints \
    --endpoint-status Disabled \
    --output none || return 1
  print_ok "East US endpoint disabled"

  print_step "Waiting 60 seconds (probe × failure threshold + TTL propagation)..."
  for i in {60..1}; do
    printf "\r  ${YELLOW}Waiting: %3d seconds remaining${NC}" "${i}"
    sleep 1
  done
  echo ""

  print_step "AFTER FAILOVER — DNS should now resolve to East US 2 IP:"
  nslookup "${TM_FQDN}" 2>/dev/null || dig "${TM_FQDN}" A 2>/dev/null || true

  print_step "East US 2 endpoint health status:"
  az network traffic-manager endpoint show \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --profile-name "${TM_PROFILE_NAME}" \
    --name "endpoint-eastus2-dr" \
    --type azureEndpoints \
    --query properties.endpointMonitorStatus -o tsv 2>/dev/null || \
    print_warn "Could not read endpoint health status"

  echo ""
  print_warn "--- FAILBACK: Re-enabling East US primary ---"
  pause

  az_retry network traffic-manager endpoint update \
    --resource-group "${RESOURCE_GROUP_PRIMARY}" \
    --profile-name "${TM_PROFILE_NAME}" \
    --name "endpoint-eastus-primary" \
    --type azureEndpoints \
    --endpoint-status Enabled \
    --output none || {
    print_warn "Re-enable command failed — endpoint may already be enabled."
  }
  print_ok "East US endpoint re-enabled. Traffic will fail back within ~60 seconds."

  print_step "DNS after failback (expect East US IP again):"
  sleep 30
  nslookup "${TM_FQDN}" 2>/dev/null || dig "${TM_FQDN}" A 2>/dev/null || true

  print_ok "Failover test complete!"
}

# ── Verify Deployment ─────────────────────────────────────────
verify_deployment() {
  print_header "Deployment Verification"

  local rg
  for rg in "${RESOURCE_GROUP_PRIMARY}" "${RESOURCE_GROUP_DR}"; do
    if rg_exists "${rg}"; then
      print_step "Resources in ${rg}:"
      az resource list --resource-group "${rg}" \
        --query "[].{Name:name, Type:type, Location:location}" --output table 2>/dev/null || \
        print_warn "Could not list resources in ${rg}"
    else
      print_warn "Resource group '${rg}' does not exist — skipping"
    fi
  done

  if tm_profile_exists "${RESOURCE_GROUP_PRIMARY}" "${TM_PROFILE_NAME}"; then
    print_step "Traffic Manager endpoints:"
    az network traffic-manager endpoint list \
      --resource-group "${RESOURCE_GROUP_PRIMARY}" \
      --profile-name "${TM_PROFILE_NAME}" \
      --query "[].{Name:name, Priority:properties.priority, Status:properties.endpointStatus, Health:properties.endpointMonitorStatus}" \
      --output table 2>/dev/null || print_warn "Could not retrieve TM endpoints"
  else
    print_warn "Traffic Manager not deployed yet"
  fi

  if vnet_exists "${RESOURCE_GROUP_PRIMARY}" "${VNET_NAME}"; then
    print_step "Primary VNet subnets:"
    az network vnet subnet list \
      --resource-group "${RESOURCE_GROUP_PRIMARY}" \
      --vnet-name "${VNET_NAME}" \
      --query "[].{Name:name, CIDR:addressPrefix}" --output table 2>/dev/null || true
  fi

  print_ok "Verification complete"
}

# ── Cleanup ───────────────────────────────────────────────────
cleanup() {
  print_header "Cleanup"
  print_warn "This will delete BOTH resource groups and ALL resources inside them!"
  echo -e "${YELLOW}Type 'yes' to confirm: ${NC}"
  read -r confirm
  if [[ "${confirm}" == "yes" ]]; then
    local rg
    for rg in "${RESOURCE_GROUP_PRIMARY}" "${RESOURCE_GROUP_DR}"; do
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
  deploy_primary_vnet    || return 1
  deploy_dr_vnet         || return 1
  deploy_dns             || { print_warn "DNS step failed — continuing with infrastructure"; }
  deploy_primary_infra   || return 1
  deploy_dr_infra        || return 1
  deploy_traffic_manager || return 1
  verify_deployment
  run_failover_test
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
  run_step "Pre-flight" preflight || true   # warnings only, never block the menu

  while true; do
    show_menu
    read -r choice
    case "${choice}" in
      1) run_step "Full deployment"            full_deploy ;;
      2) run_step "Create Resource Groups"     create_resource_groups ;;
      3) run_step "Deploy PRIMARY VNet"        deploy_primary_vnet ;;
      4) run_step "Deploy DR VNet"             deploy_dr_vnet ;;
      5) run_step "Deploy DNS Zones"           deploy_dns ;;
      6) run_step "Deploy PRIMARY Infra"       deploy_primary_infra ;;
      7) run_step "Deploy DR Infra"            deploy_dr_infra ;;
      8) run_step "Deploy Traffic Manager"     deploy_traffic_manager ;;
      9) run_step "Failover Test"              run_failover_test ;;
      v|V) run_step "Verify Deployment"        verify_deployment ;;
      c|C) run_step "Cleanup"                  cleanup ;;
      0) echo "Exiting."; exit 0 ;;
      *) print_warn "Invalid option '${choice}'" ;;
    esac
  done
}

main "$@"
