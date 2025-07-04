#!/bin/bash
# =========================================================
# NIPA Travel Ingress Controller Switcher
# =========================================================
# This script makes it easy to switch between different ingress controllers
# for performance testing.
#
# Usage: ./ingress-switcher.sh [ingress-type] [action]
#
# Examples:
#   ./ingress-switcher.sh traefik install  # Install Traefik + app
#   ./ingress-switcher.sh nginx clean      # Remove nginx + app
#   ./ingress-switcher.sh all clean        # Clean all ingress controllers
# =========================================================

# Configuration
NAMESPACE="nipa-travel"
APP_NAME="prod-nipa-travel"
TIMEOUT="5m"
APP_VALUES="values.yaml"
APP_SECRET_VALUES="values-secret.yaml"
INGRESS_CONTROLLER_DIR="ingress-controller-value"
INGRESS_RESOURCE_DIR="ingress-resource-value"

# Colors for better output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Help function
function show_help() {
  echo -e "${BLUE}=== NIPA Travel Ingress Controller Switcher ===${NC}"
  echo 
  echo -e "Usage: $0 ${GREEN}[ingress-type]${NC} ${YELLOW}[action]${NC}"
  echo
  echo -e "${GREEN}Ingress Types:${NC}"
  echo "  traefik   - Traefik ingress controller"
  echo "  nginx     - NGINX ingress controller"
  echo "  apisix    - APISIX ingress controller"
  echo "  haproxy   - HAProxy ingress controller"
  echo "  all       - All ingress controllers"
  echo
  echo -e "${YELLOW}Actions:${NC}"
  echo "  install   - Install ingress controller and app"
  echo "  clean     - Remove ingress controller and app"
  echo
  echo -e "${BLUE}Examples:${NC}"
  echo "  $0 traefik install"
  echo "  $0 nginx clean"
  echo "  $0 all clean"
  exit 0
}

# Check directories at startup
function check_environment() {
  echo -e "${BLUE}Checking environment...${NC}"
  
  # Check if we're in the correct directory (containing Chart.yaml)
  if [ ! -f "Chart.yaml" ]; then
    echo -e "${RED}Error: Chart.yaml not found in current directory${NC}"
    echo -e "${YELLOW}Make sure you're running this script from the root of your Helm chart directory${NC}"
    exit 1
  fi
  
  # Check if directories exist
  if [ ! -d "${INGRESS_CONTROLLER_DIR}" ]; then
    echo -e "${RED}Error: Ingress controller directory '${INGRESS_CONTROLLER_DIR}' not found${NC}"
    exit 1
  fi
  
  if [ ! -d "${INGRESS_RESOURCE_DIR}" ]; then
    echo -e "${RED}Error: Ingress resource directory '${INGRESS_RESOURCE_DIR}' not found${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}✓ Environment check passed${NC}"
}

# Get chart name for ingress type
function get_chart_name() {
  local ingress_type=$1
  
  case "$ingress_type" in
    traefik)
      echo "traefik/traefik"
      ;;
    nginx)
      echo "ingress-nginx/ingress-nginx"
      ;;
    apisix)
      echo "apisix/apisix"
      ;;
    haproxy)
      echo "haproxytech/kubernetes-ingress"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Install ingress controller and app
function install_ingress() {
  local ingress_type=$1
  local chart=$(get_chart_name "$ingress_type")
  local controller_file="${INGRESS_CONTROLLER_DIR}/${ingress_type}-controller-values.yaml"
  local resource_file="${INGRESS_RESOURCE_DIR}/${ingress_type}-values.yaml"
  
  if [ -z "$chart" ]; then
    echo -e "${RED}Error: Invalid ingress type '$ingress_type'${NC}"
    exit 1
  fi
  
  echo -e "${BLUE}===== Installing ${ingress_type} ingress setup =====${NC}"
  
  # Check if files exist
  if [ ! -f "$controller_file" ]; then
    echo -e "${RED}Error: Controller values file not found: ${controller_file}${NC}"
    exit 1
  fi
  
  if [ ! -f "$resource_file" ]; then
    echo -e "${RED}Error: Resource values file not found: ${resource_file}${NC}"
    exit 1
  fi
  
  # Create namespace if it doesn't exist
  kubectl get namespace ${NAMESPACE} >/dev/null 2>&1 || kubectl create namespace ${NAMESPACE}
  
  # Step 1: Install the ingress controller
  echo -e "${BLUE}Step 1/2: Installing ${ingress_type} ingress controller...${NC}"

  # Special case for APISIX
  if [ "$ingress_type" = "apisix" ]; then
    helm upgrade --install ${ingress_type} ${chart} \
      -f ${controller_file} \
      -n ${NAMESPACE} \
      --set ingress-controller.config.apisix.serviceNamespace=${NAMESPACE} \
      --set serviceMonitor.namespace=${NAMESPACE} \
      --create-namespace \
      --atomic --wait --timeout ${TIMEOUT}
  else
    helm upgrade --install ${ingress_type} ${chart} \
      -f ${controller_file} \
      -n ${NAMESPACE} \
      --create-namespace \
      --atomic --wait --timeout ${TIMEOUT}
  fi

  # Wait for ingress controller deployment to be ready
  echo -e "${BLUE}Waiting for ${ingress_type} ingress controller deployment to be ready...${NC}"
  kubectl rollout status deployment -n ${NAMESPACE} -l app.kubernetes.io/name=${ingress_type} --timeout=${TIMEOUT} || {
    echo -e "${RED}Error: Ingress controller deployment did not become ready in time.${NC}"
    exit 1
  }

  # Special case: If APISIX, wait for etcd StatefulSet to be ready
  if [ "$ingress_type" = "apisix" ]; then
    echo -e "${BLUE}Waiting for APISIX etcd StatefulSet to be ready...${NC}"
    kubectl rollout status statefulset.apps/apisix-etcd -n ${NAMESPACE} --timeout=${TIMEOUT} || {
      echo -e "${RED}Error: APISIX etcd StatefulSet did not become ready in time.${NC}"
      exit 1
    }
  fi

  # Wait 15 seconds for ingress controller to fully initialize
  echo -e "${BLUE}Waiting 15 seconds for ingress controller to fully initialize...${NC}"
  sleep 15

  echo -e "${GREEN}✓ ${ingress_type} ingress controller installed successfully${NC}"
  
  # Step 2: Install the application with ingress resources
  echo -e "${BLUE}Step 2/2: Installing application with ${ingress_type} ingress resources...${NC}"
  
  # Check that all required files exist
  echo -e "${BLUE}Checking required files:${NC}"
  echo -e "  App values: ${APP_VALUES} - $([ -f "${APP_VALUES}" ] && echo "✓ Found" || echo "❌ NOT FOUND")"
  echo -e "  Secret values: ${APP_SECRET_VALUES} - $([ -f "${APP_SECRET_VALUES}" ] && echo "✓ Found" || echo "❌ NOT FOUND")"
  echo -e "  Ingress resource: ${resource_file} - $([ -f "${resource_file}" ] && echo "✓ Found" || echo "❌ NOT FOUND")"
  
  # Add --debug flag for more verbose output
  helm upgrade --install ${APP_NAME} . \
    -f ${APP_VALUES} -f ${APP_SECRET_VALUES} -f ${resource_file} \
    -n ${NAMESPACE} \
    --create-namespace \
    --atomic --wait --timeout ${TIMEOUT} || {
      echo -e "${RED}Error: Failed to install application. See above for details.${NC}"
      exit 1
    }
  
  echo -e "${GREEN}✓ Application installed successfully with ${ingress_type} ingress resources${NC}"
  echo -e "${GREEN}===== ${ingress_type} ingress setup complete! =====${NC}"
  
  # Verify the installation
  echo -e "${BLUE}Verifying deployment:${NC}"
  echo -e "Ingress controller pods:"
  kubectl get pods -n ${NAMESPACE} -l "app.kubernetes.io/name=${ingress_type}" -o wide || echo -e "${YELLOW}No pods found with exact label. Trying broader search...${NC}"
  kubectl get pods -n ${NAMESPACE} | grep ${ingress_type} || echo -e "${YELLOW}No ${ingress_type} pods found${NC}"
  
  echo -e "\nApplication pods:"
  kubectl get pods -n ${NAMESPACE} -l "app.kubernetes.io/name=${APP_NAME}" -o wide || echo -e "${YELLOW}No pods found with label app.kubernetes.io/name=${APP_NAME}${NC}"
  kubectl get pods -n ${NAMESPACE} | grep ${APP_NAME} || echo -e "${YELLOW}No ${APP_NAME} pods found by name${NC}"
  
  echo -e "\nAll pods in namespace:"
  kubectl get pods -n ${NAMESPACE}
  
  # Show endpoints
  echo -e "\n${BLUE}Ingress endpoints:${NC}"
  kubectl get ingress -n ${NAMESPACE} || echo -e "${YELLOW}No ingress resources found${NC}"
}

# Clean up ingress controller and app
function clean_ingress() {
  local ingress_type=$1
  
  echo -e "${BLUE}===== Cleaning up ${ingress_type} ingress setup =====${NC}"
  
  # Step 1: Uninstall the application
  echo -e "${BLUE}Step 1/2: Uninstalling application...${NC}"
  helm uninstall ${APP_NAME} -n ${NAMESPACE} 2>/dev/null || echo -e "${YELLOW}Application was not installed${NC}"
  
  # Step 2: Uninstall the ingress controller
  echo -e "${BLUE}Step 2/2: Uninstalling ${ingress_type} ingress controller...${NC}"
  helm uninstall ${ingress_type} -n ${NAMESPACE} 2>/dev/null || echo -e "${YELLOW}${ingress_type} ingress controller was not installed${NC}"
  
  echo -e "${GREEN}===== ${ingress_type} ingress setup cleaned up! =====${NC}"
}

# Clean all ingress controllers
function clean_all() {
  echo -e "${BLUE}===== Cleaning up all ingress setups =====${NC}"
  
  # Step 1: Uninstall the application
  echo -e "${BLUE}Step 1: Uninstalling application...${NC}"
  helm uninstall ${APP_NAME} -n ${NAMESPACE} 2>/dev/null || echo -e "${YELLOW}Application was not installed${NC}"
  
  # Step 2: Uninstall all ingress controllers
  echo -e "${BLUE}Step 2: Uninstalling all ingress controllers...${NC}"
  
  for ingress_type in traefik nginx apisix haproxy; do
    echo -e "${BLUE}  - Uninstalling ${ingress_type}...${NC}"
    helm uninstall ${ingress_type} -n ${NAMESPACE} 2>/dev/null || echo -e "${YELLOW}  ${ingress_type} was not installed${NC}"
  done
  
  echo -e "${GREEN}===== All ingress setups cleaned up! =====${NC}"
}

# Main function
function main() {
  # Check if help is requested or insufficient arguments
  if [ $# -lt 2 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_help
    exit 0
  fi
  
  local ingress_type=$1
  local action=$2
  
  # Check environment first
  check_environment
  
  # Validate action
  if [ "$action" != "install" ] && [ "$action" != "clean" ]; then
    echo -e "${RED}Error: Invalid action '$action'${NC}"
    echo -e "Valid actions: install, clean"
    exit 1
  fi
  
  # Handle "all" option
  if [ "$ingress_type" = "all" ]; then
    if [ "$action" = "clean" ]; then
      clean_all
    else
      echo -e "${RED}Error: Cannot install all ingress controllers at once${NC}"
      echo -e "Please specify a single ingress controller to install"
      exit 1
    fi
    exit 0
  fi
  
  # Validate ingress type
  if [ "$(get_chart_name "$ingress_type")" = "" ]; then
    echo -e "${RED}Error: Invalid ingress type '$ingress_type'${NC}"
    echo -e "Valid options: traefik, nginx, apisix, haproxy, all"
    exit 1
  fi
  
  # Execute the requested action
  case "$action" in
    install)
      install_ingress "$ingress_type"
      ;;
    clean)
      clean_ingress "$ingress_type"
      ;;
  esac
}

# Execute main function
main "$@"