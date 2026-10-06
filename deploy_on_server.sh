#!/usr/bin/env bash
# ==============================================================================
# Arcane & Traefik Air-Gapped Server Deployment Script
# Target: Ubuntu / Debian Air-Gapped Host (No internet access required)
# Fully compatible with Linux / Ubuntu as well as Windows (Git Bash / WSL).
# ==============================================================================

set -euo pipefail

# Ensure Windows Git Bash / MSYS2 does not mangle paths if run locally
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# ==============================================================================
# CONFIGURATION & VARIABLES (ALL DEFINED AT THE TOP WITH DEFAULT VALUES)
# ==============================================================================

# --- Container & Network Settings ---
NETWORK_NAME="proxy"                                   # Docker network name
COMPOSE_FILE="compose.yaml"                            # Docker compose filename
ENV_FILE=".env"                                        # Environment file
ENV_EXAMPLE_FILE=".env.example"                        # Example environment file

# --- Project Directory Structure ---
DATA_DIR="arcane-data"                                 # Arcane database & runtime storage
PROJECTS_DIR="projects"                                # Arcane projects directory
BACKUPS_DIR="arcane-backups"                           # Arcane backups volume directory
CERTS_DIR="traefik/certs"                              # Traefik TLS certificates directory
DYNAMIC_DIR="traefik/dynamic"                          # Traefik dynamic configuration directory

# --- Offline Image Archive Settings ---
IMAGE_ARCHIVE="docker-images.tar.gz"                   # Default offline Docker images archive name
ARCHIVE_FILE=""                                        # Runtime archive iterator

# --- Health Check & Timeout Settings ---
MAX_WAIT=45                                            # Maximum seconds to wait for Arcane health check
POLL_INTERVAL=3                                        # Seconds between health checks
ELAPSED=0                                              # Health check elapsed timer
ARCANE_HEALTHY=false                                   # Arcane container health status
ARCANE_STATUS=""                                       # Health status output from docker inspect

# --- Default Hostnames & Endpoints (Used if not in .env) ---
ARCANE_HOST="dockermgr.chetan.local"                   # Default Arcane Manager domain
TRAEFIK_HOST="proxy.chetan.local"                      # Default Traefik Dashboard domain
HOST_IPS=""                                            # Detected server IP addresses
PRIMARY_IP=""                                          # Primary detected server IP address

# --- Command Binaries ---
DOCKER_CMD="docker"                                    # Docker CLI command (switches to 'sudo docker' if needed)
COMPOSE_CMD="docker compose"                           # Docker Compose command (detected at runtime)

# --- UI & Terminal Colors ---
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'                                           # Reset color

# --- Script Path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# ==============================================================================
# MAIN LOGIC
# ==============================================================================

echo -e "${CYAN}${BOLD}"
echo "=========================================================="
echo "    Arcane & Traefik - Air-Gapped Server Deployment       "
echo "=========================================================="
echo -e "${NC}"

cd "$SCRIPT_DIR"
log_info "Working directory: $SCRIPT_DIR"

# ------------------------------------------------------------------------------
# 1. Prerequisite Checks
# ------------------------------------------------------------------------------
log_info "Checking system prerequisites..."

# Check Docker CLI
if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker is not installed on this system."
    log_error "Please pre-install Docker Engine before running this script."
    exit 1
fi

# Determine if sudo is needed for docker
if ! docker info >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
        log_warn "Current user cannot access Docker daemon directly. Using 'sudo docker'."
        DOCKER_CMD="sudo docker"
    else
        log_error "Docker daemon is not running or accessible. Please ensure the docker service is active:"
        log_error "  sudo systemctl start docker"
        exit 1
    fi
fi

# Detect Docker Compose command (v2 plugin or v1 standalone)
if $DOCKER_CMD compose version >/dev/null 2>&1; then
    COMPOSE_CMD="$DOCKER_CMD compose"
    log_success "Found Docker Compose Plugin: $($COMPOSE_CMD version --short 2>/dev/null || echo 'v2')"
elif command -v docker-compose >/dev/null 2>&1; then
    if docker-compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    elif command -v sudo >/dev/null 2>&1 && sudo docker-compose version >/dev/null 2>&1; then
        COMPOSE_CMD="sudo docker-compose"
    fi
    log_success "Found standalone docker-compose: $($COMPOSE_CMD --version 2>/dev/null || echo 'v1')"
else
    log_error "Neither 'docker compose' (plugin) nor 'docker-compose' (standalone) was found."
    log_error "Please install the Docker Compose plugin on this host."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Load Offline Docker Images
# ------------------------------------------------------------------------------
if [ -f "$IMAGE_ARCHIVE" ]; then
    log_info "Found offline image archive: ${BOLD}${IMAGE_ARCHIVE}${NC}"
elif [ -f "docker-images.tar" ]; then
    IMAGE_ARCHIVE="docker-images.tar"
    log_info "Found offline image archive: ${BOLD}${IMAGE_ARCHIVE}${NC}"
elif compgen -G "*.tar.gz" > /dev/null; then
    for ARCHIVE_FILE in *.tar.gz; do
        if [[ "$ARCHIVE_FILE" == *"image"* ]]; then
            IMAGE_ARCHIVE="$ARCHIVE_FILE"
            log_info "Found offline image archive: ${BOLD}${IMAGE_ARCHIVE}${NC}"
            break
        fi
    done
fi

if [ -f "$IMAGE_ARCHIVE" ]; then
    log_info "Loading Docker images into local Docker cache (this may take a minute)..."
    if [[ "$IMAGE_ARCHIVE" == *.gz ]]; then
        gzip -dc "$IMAGE_ARCHIVE" | $DOCKER_CMD load
    else
        $DOCKER_CMD load -i "$IMAGE_ARCHIVE"
    fi
    log_success "Docker images loaded successfully."
else
    log_warn "No image archive found in current directory."
    log_warn "Proceeding assuming required images are already present in local Docker cache."
fi

# ------------------------------------------------------------------------------
# 3. Directory Structure & Permissions Setup
# ------------------------------------------------------------------------------
log_info "Verifying required directory structure..."

mkdir -p "$DATA_DIR" "$PROJECTS_DIR" "$BACKUPS_DIR" "$CERTS_DIR" "$DYNAMIC_DIR"

# Secure TLS private keys if present
if compgen -G "${CERTS_DIR}/*.key" > /dev/null; then
    log_info "Securing TLS private keys in ${CERTS_DIR} (chmod 600)..."
    chmod 600 "${CERTS_DIR}"/*.key 2>/dev/null || true
fi
if compgen -G "${CERTS_DIR}/*.crt" > /dev/null; then
    chmod 644 "${CERTS_DIR}"/*.crt 2>/dev/null || true
fi

# Ensure data directories are writable
chmod 755 "$DATA_DIR" "$PROJECTS_DIR" "$BACKUPS_DIR" 2>/dev/null || true

# Check Environment Configuration
if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$ENV_EXAMPLE_FILE" ]; then
        log_warn "No ${ENV_FILE} file found. Creating one from ${ENV_EXAMPLE_FILE}..."
        cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
    else
        log_warn "No ${ENV_FILE} file found and ${ENV_EXAMPLE_FILE} is missing. Using default compose variables."
    fi
else
    log_success "Using existing ${ENV_FILE} configuration."
fi

# ------------------------------------------------------------------------------
# 4. Ensure Docker Proxy Network Exists
# ------------------------------------------------------------------------------
if ! $DOCKER_CMD network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    log_info "Creating external Docker network: ${NETWORK_NAME}..."
    $DOCKER_CMD network create "$NETWORK_NAME"
    log_success "Docker network '${NETWORK_NAME}' created."
else
    log_info "Docker network '${NETWORK_NAME}' already exists."
fi

# ------------------------------------------------------------------------------
# 5. Launch Stack via Docker Compose
# ------------------------------------------------------------------------------
log_info "Stopping existing containers (if any)..."
$COMPOSE_CMD down --remove-orphans 2>/dev/null || true

log_info "Starting Arcane & Traefik services..."
$COMPOSE_CMD up -d

# ------------------------------------------------------------------------------
# 6. Wait for Services & Health Check
# ------------------------------------------------------------------------------
log_info "Waiting for containers to initialize and report health..."

while [ $ELAPSED -lt $MAX_WAIT ]; do
    ARCANE_STATUS=$($DOCKER_CMD inspect --format '{{json .State.Health.Status}}' arcane 2>/dev/null || echo '"unknown"')
    
    if [ "$ARCANE_STATUS" = '"healthy"' ]; then
        ARCANE_HEALTHY=true
        break
    fi
    
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    echo -n "."
done
echo ""

if [ "$ARCANE_HEALTHY" = true ]; then
    log_success "Arcane health check passed (status: healthy)."
else
    log_warn "Arcane container health check did not report healthy within ${MAX_WAIT}s."
    log_warn "It might still be initializing. Check logs with: $COMPOSE_CMD logs arcane"
fi

# ------------------------------------------------------------------------------
# 7. Print Deployment Status & Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}==========================================================${NC}"
echo -e "${GREEN}${BOLD}     Arcane & Traefik Stack Successfully Deployed!        ${NC}"
echo -e "${GREEN}${BOLD}==========================================================${NC}"

echo -e "\n${BOLD}Current Container Status:${NC}"
$COMPOSE_CMD ps

# Extract hostnames from .env if present
if [ -f "$ENV_FILE" ]; then
    ARCANE_HOST=$(grep -E '^ARCANE_HOST=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2 | tr -d '\r "' | tr -d "'" || echo "$ARCANE_HOST")
    TRAEFIK_HOST=$(grep -E '^TRAEFIK_HOST=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2 | tr -d '\r "' | tr -d "'" || echo "$TRAEFIK_HOST")
fi

# Detect host IPs portably across Linux/Ubuntu and Windows
HOST_IPS=$(hostname -I 2>/dev/null || ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || ipconfig.exe 2>/dev/null | grep -i "IPv4" | awk -F: '{print $2}' | tr -d '\r ' || echo "")
PRIMARY_IP=$(echo "$HOST_IPS" | awk '{print $1}')

echo -e "\n${BOLD}Access Endpoints:${NC}"
echo -e "  - ${CYAN}Arcane WebUI:${NC}        https://${ARCANE_HOST}"
echo -e "  - ${CYAN}Traefik Dashboard:${NC}   https://${TRAEFIK_HOST}"
if [ -n "$PRIMARY_IP" ]; then
    echo -e "  - ${CYAN}Server IP Address:${NC}   ${PRIMARY_IP}"
fi

echo -e "\n${BOLD}Default Credentials (Initial Login):${NC}"
echo -e "  - Username: ${YELLOW}arcane${NC}"
echo -e "  - Password: ${YELLOW}arcane-admin${NC}"

echo -e "\n${BOLD}Client Workstation DNS Setup:${NC}"
echo -e "Because this environment is air-gapped, point your workstation's hosts file to this server:"
if [ -n "$PRIMARY_IP" ]; then
    echo -e "  ${PRIMARY_IP}  ${ARCANE_HOST}"
    echo -e "  ${PRIMARY_IP}  ${TRAEFIK_HOST}"
else
    echo -e "  <SERVER_IP>  ${ARCANE_HOST}"
    echo -e "  <SERVER_IP>  ${TRAEFIK_HOST}"
fi

echo -e "\n${BOLD}Useful Commands:${NC}"
echo -e "  - View logs:    ${CYAN}$COMPOSE_CMD logs -f${NC}"
echo -e "  - Stop stack:   ${CYAN}$COMPOSE_CMD down${NC}"
echo -e "  - Restart:      ${CYAN}$COMPOSE_CMD restart${NC}"
echo "=========================================================="
