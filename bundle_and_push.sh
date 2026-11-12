#!/usr/bin/env bash
# ==============================================================================
# Arcane & Traefik Air-Gapped Bundler & Remote SSH Deployer
# Packages Docker images + project configs, and pushes to Ubuntu server via SSH.
# Fully compatible with Windows (Git Bash / MSYS2 / WSL / Cygwin) and Linux / Ubuntu.
# ==============================================================================

set -euo pipefail

# Ensure Windows Git Bash / MSYS2 does not translate Unix-style paths (e.g. /opt/...)
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# ==============================================================================
# CONFIGURATION & VARIABLES (ALL DEFINED AT THE TOP WITH DEFAULT VALUES)
# ==============================================================================

# --- Remote Server SSH & SCP Configuration ---
TARGET_SSH="chetan@172.20.64.101"                      # Target user & IP/hostname
SSH_PORT="22"                                          # SSH port on remote server
SSH_KEY=""                                             # Path to private key (e.g. ~/.ssh/id_rsa, leave empty for default SSH)
REMOTE_DEST="/home/chetan/arcane-docker-manager"               # Target directory on remote Ubuntu server

# --- Packaging & Output Configuration ---
OUTPUT_BUNDLE="arcane-airgap-bundle.tar.gz"            # Filename for generated tarball
COMPOSE_FILE="compose.yaml"                            # Compose file to discover images from
IMAGE_ARCHIVE_NAME="docker-images.tar.gz"              # Name of the internal Docker image archive
INCLUDE_DATA=false                                     # Whether to bundle arcane-data (SQLite DB, etc.)
AUTO_RUN=false                                         # Automatically run deploy_on_server.sh on remote server
BUNDLE_ONLY=false                                      # Only build the bundle archive (skip SSH upload)

# --- Docker Images Configuration ---
EXTRA_IMAGES=""                                        # Additional Docker images to bundle (space-separated)
FALLBACK_IMAGES=(
    "ghcr.io/getarcaneapp/manager:v2.15.0"
    "docker.io/traefik:v3.7.13"
)
IMAGES=()                                              # List of images to be pulled and saved

# --- UI & Terminal Colors ---
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'                                           # Reset color

# --- Runtime Paths & Buffers ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=""                                            # Temporary workspace created at runtime
STAGING_DIR=""                                         # Staging folder within WORK_DIR
CLI_TARGET_PROVIDED=false                              # Tracks if -t was passed on CLI
SSH_OPTS=()                                            # SSH options array
SCP_OPTS=()                                            # SCP options array

# --- Interactive Prompts Temporary Buffers ---
INPUT_TARGET=""
INPUT_PORT=""
INPUT_KEY=""
INPUT_DEST=""
INPUT_RUN=""

# --- Loop Iteration Variables ---
CURRENT_IMG=""
EXTRA_IMG=""

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

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

show_help() {
    cat <<EOF
Usage: ./bundle_and_push.sh [OPTIONS]

Options:
  -t, --target USER@HOST     SSH target (default: ${TARGET_SSH})
  -p, --port PORT            SSH port (default: ${SSH_PORT})
  -i, --identity FILE        SSH private key identity file (default: system default)
  -d, --dest DIR             Remote deployment directory (default: ${REMOTE_DEST})
  -r, --run                  Automatically execute deploy_on_server.sh on remote host after transfer
      --bundle-only          Only build local archive without pushing to remote server
      --exclude-data         Do not include arcane-data SQLite database in bundle
      --extra-images "LIST"  Space-separated list of additional Docker images to include
  -o, --output FILE          Output bundle file name (default: ${OUTPUT_BUNDLE})
  -h, --help                 Show this help message

Cross-Platform Compatibility:
  Runs identically on Windows (Git Bash, MSYS2, WSL, Cygwin) and Linux (Ubuntu, Debian, RHEL).
EOF
}

# ==============================================================================
# MAIN LOGIC
# ==============================================================================

cd "$SCRIPT_DIR"

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            TARGET_SSH="$2"
            CLI_TARGET_PROVIDED=true
            shift 2
            ;;
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -i|--identity)
            SSH_KEY="$2"
            shift 2
            ;;
        -d|--dest)
            REMOTE_DEST="$2"
            shift 2
            ;;
        -r|--run)
            AUTO_RUN=true
            shift
            ;;
        --bundle-only)
            BUNDLE_ONLY=true
            shift
            ;;
        --exclude-data)
            INCLUDE_DATA=false
            shift
            ;;
        --extra-images)
            EXTRA_IMAGES="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_BUNDLE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${CYAN}${BOLD}"
echo "=========================================================="
echo "    Arcane & Traefik - Air-Gap Packager & Deployer       "
echo "=========================================================="
echo -e "${NC}"

# Interactive prompts if required arguments are missing and not in bundle-only mode
if [ "$BUNDLE_ONLY" = false ] && [ "$CLI_TARGET_PROVIDED" = false ]; then
    echo -e "${YELLOW}Interactive Mode (press Enter to accept default values):${NC}\n"
    
    read -rp "Target SSH host [Default: ${TARGET_SSH}]: " INPUT_TARGET
    [ -n "$INPUT_TARGET" ] && TARGET_SSH="$INPUT_TARGET"
    
    read -rp "SSH Port [Default: ${SSH_PORT}]: " INPUT_PORT
    [ -n "$INPUT_PORT" ] && SSH_PORT="$INPUT_PORT"
    
    read -rp "SSH Identity file (Default: ${SSH_KEY:-system default}): " INPUT_KEY
    [ -n "$INPUT_KEY" ] && SSH_KEY="$INPUT_KEY"
    
    read -rp "Remote destination directory [Default: ${REMOTE_DEST}]: " INPUT_DEST
    [ -n "$INPUT_DEST" ] && REMOTE_DEST="$INPUT_DEST"
    
    read -rp "Automatically run deploy_on_server.sh on remote server? [y/N] (Default: $([ "$AUTO_RUN" = true ] && echo 'y' || echo 'n')): " INPUT_RUN
    if [[ "$INPUT_RUN" =~ ^[Yy]$ ]]; then
        AUTO_RUN=true
    fi
    echo ""
fi

# Pre-flight Checks (Local machine)
log_info "Verifying local tools..."

if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker is required locally to pull and package images, but was not found."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon is not running locally. Please start Docker Desktop/daemon."
    exit 1
fi

if [ "$BUNDLE_ONLY" = false ]; then
    if ! command -v ssh >/dev/null 2>&1; then
        log_error "SSH client is required to connect to the remote server, but was not found."
        exit 1
    fi
    if ! command -v scp >/dev/null 2>&1; then
        log_error "SCP is required to copy the bundle to the remote server, but was not found."
        exit 1
    fi
fi

# Extract and Pull Docker Images
log_info "Discovering Docker images required by the project..."

# Portable image discovery (avoids process substitution quirks across older shells)
if [ -f "$COMPOSE_FILE" ]; then
    for CURRENT_IMG in $(grep -E '^[[:space:]]*image:' "$COMPOSE_FILE" 2>/dev/null | awk '{print $2}' | tr -d '\r "' | tr -d "'" ); do
        if [ -n "$CURRENT_IMG" ]; then
            IMAGES+=("$CURRENT_IMG")
        fi
    done
elif [ -f "docker-compose.yml" ]; then
    for CURRENT_IMG in $(grep -E '^[[:space:]]*image:' docker-compose.yml 2>/dev/null | awk '{print $2}' | tr -d '\r "' | tr -d "'" ); do
        if [ -n "$CURRENT_IMG" ]; then
            IMAGES+=("$CURRENT_IMG")
        fi
    done
fi

# Fallback defaults if extraction missed anything
if [ ${#IMAGES[@]} -eq 0 ]; then
    log_warn "Could not auto-detect images from ${COMPOSE_FILE}. Using fallback images."
    IMAGES=("${FALLBACK_IMAGES[@]}")
fi

# Add any extra images specified
if [ -n "$EXTRA_IMAGES" ]; then
    for EXTRA_IMG in $EXTRA_IMAGES; do
        IMAGES+=("$EXTRA_IMG")
    done
fi

log_info "Images to package:"
for CURRENT_IMG in "${IMAGES[@]}"; do
    echo -e "  - ${CYAN}$CURRENT_IMG${NC}"
done

# Pull all images locally
log_info "Pulling Docker images from registry to ensure latest local copies..."
for CURRENT_IMG in "${IMAGES[@]}"; do
    log_info "Pulling $CURRENT_IMG..."
    docker pull "$CURRENT_IMG"
done
log_success "All Docker images verified locally."

# Build Staging Directory (inside local workspace to prevent Windows drive/temp quirks)
WORK_DIR="${SCRIPT_DIR}/.tmp_bundle_$$"
STAGING_DIR="${WORK_DIR}/staging"
mkdir -p "$STAGING_DIR"

log_info "Saving and compressing Docker images into ${STAGING_DIR}/${IMAGE_ARCHIVE_NAME}..."
log_info "(This step may take several minutes depending on compression speed)..."

docker save "${IMAGES[@]}" | gzip > "${STAGING_DIR}/${IMAGE_ARCHIVE_NAME}"
ARCHIVE_SIZE=$(du -h "${STAGING_DIR}/${IMAGE_ARCHIVE_NAME}" 2>/dev/null | awk '{print $1}' || echo "saved")
log_success "Docker images saved (${ARCHIVE_SIZE})."

# Copy Project Files & Configuration
log_info "Assembling project files into staging area..."

if [ -f "$COMPOSE_FILE" ]; then
    cp "$COMPOSE_FILE" "$STAGING_DIR/"
fi
if [ -f "docker-compose.yml" ]; then
    cp docker-compose.yml "$STAGING_DIR/"
fi

if [ -f ".env" ]; then
    cp .env "$STAGING_DIR/"
fi
if [ -f ".env.example" ]; then
    cp .env.example "$STAGING_DIR/"
fi

if [ -d "traefik" ]; then
    cp -r traefik "$STAGING_DIR/"
fi

if [ -d "projects" ]; then
    cp -r projects "$STAGING_DIR/"
else
    mkdir -p "$STAGING_DIR/projects"
fi

if [ -d "arcane-backups" ]; then
    cp -r arcane-backups "$STAGING_DIR/"
else
    mkdir -p "$STAGING_DIR/arcane-backups"
fi

if [ "$INCLUDE_DATA" = true ]; then
    if [ -d "arcane-data" ]; then
        log_info "Including existing arcane-data (database, settings)..."
        cp -r arcane-data "$STAGING_DIR/"
    else
        mkdir -p "$STAGING_DIR/arcane-data"
    fi
else
    log_info "Excluding existing arcane-data (clean deployment)..."
    mkdir -p "$STAGING_DIR/arcane-data"
fi

if [ -f "deploy_on_server.sh" ]; then
    cp deploy_on_server.sh "$STAGING_DIR/"
    chmod +x "$STAGING_DIR/deploy_on_server.sh" 2>/dev/null || true
else
    log_error "deploy_on_server.sh was not found in the current directory!"
    exit 1
fi

# Sanitize line endings: ensure pure Unix LF for all shell scripts and configs
log_info "Ensuring Unix LF line endings for remote Ubuntu compatibility..."
if command -v dos2unix >/dev/null 2>&1; then
    dos2unix -q "$STAGING_DIR"/*.sh "$STAGING_DIR"/*.yaml "$STAGING_DIR"/.env* 2>/dev/null || true
else
    sed -i 's/\r$//' "$STAGING_DIR"/deploy_on_server.sh 2>/dev/null || true
    [ -f "$STAGING_DIR/$COMPOSE_FILE" ] && sed -i 's/\r$//' "$STAGING_DIR/$COMPOSE_FILE" 2>/dev/null || true
    [ -f "$STAGING_DIR/.env" ] && sed -i 's/\r$//' "$STAGING_DIR/.env" 2>/dev/null || true
fi

# Package into final Tarball
log_info "Packaging staging files into final bundle: ${BOLD}${OUTPUT_BUNDLE}${NC}..."
tar -czf "$OUTPUT_BUNDLE" -C "$STAGING_DIR" .
BUNDLE_SIZE=$(du -h "$OUTPUT_BUNDLE" 2>/dev/null | awk '{print $1}' || echo "created")
log_success "Bundle successfully created: ${OUTPUT_BUNDLE} (${BUNDLE_SIZE})"

# Push to Remote Server via SSH / SCP
if [ "$BUNDLE_ONLY" = true ]; then
    echo ""
    echo -e "${GREEN}${BOLD}==========================================================${NC}"
    echo -e "${GREEN}${BOLD}             Bundle Ready for Offline Transfer!           ${NC}"
    echo -e "${GREEN}${BOLD}==========================================================${NC}"
    echo -e "Archive: ${CYAN}${OUTPUT_BUNDLE}${NC}"
    echo -e "\nTo deploy manually on the air-gapped Ubuntu server:"
    echo -e "  1. Copy '${OUTPUT_BUNDLE}' to the target server (e.g. via USB or SCP)."
    echo -e "  2. Extract it into your desired directory:"
    echo -e "     ${CYAN}mkdir -p ${REMOTE_DEST}${NC}"
    echo -e "     ${CYAN}tar -xzf ${OUTPUT_BUNDLE} -C ${REMOTE_DEST}${NC}"
    echo -e "  3. Run the installer:"
    echo -e "     ${CYAN}cd ${REMOTE_DEST} && sudo ./deploy_on_server.sh${NC}"
    exit 0
fi

# Build SSH options
SSH_OPTS=(-p "$SSH_PORT" -o "StrictHostKeyChecking=accept-new")
SCP_OPTS=(-P "$SSH_PORT" -o "StrictHostKeyChecking=accept-new")

if [ -n "$SSH_KEY" ]; then
    SSH_OPTS+=(-i "$SSH_KEY")
    SCP_OPTS+=(-i "$SSH_KEY")
fi

log_info "Testing SSH connectivity to ${TARGET_SSH} on port ${SSH_PORT}..."
if ! ssh "${SSH_OPTS[@]}" "$TARGET_SSH" "echo 'SSH connection verified'" >/dev/null 2>&1; then
    log_error "Failed to connect to ${TARGET_SSH} via SSH."
    log_error "Please check the hostname, port, and authentication credentials."
    exit 1
fi
log_success "SSH connection established."

log_info "Creating remote directory '${REMOTE_DEST}'..."
ssh "${SSH_OPTS[@]}" "$TARGET_SSH" "sudo mkdir -p '$REMOTE_DEST' 2>/dev/null || mkdir -p '$REMOTE_DEST'"

log_info "Transferring ${OUTPUT_BUNDLE} to ${TARGET_SSH}:${REMOTE_DEST}..."
scp "${SCP_OPTS[@]}" "$OUTPUT_BUNDLE" "${TARGET_SSH}:${REMOTE_DEST}/${OUTPUT_BUNDLE}"
log_success "Bundle transfer complete!"

# Remote Extraction & Execution
if [ "$AUTO_RUN" = true ]; then
    log_info "Triggering remote deployment on ${TARGET_SSH}..."
    ssh -t "${SSH_OPTS[@]}" "$TARGET_SSH" "cd '$REMOTE_DEST' && tar -xzf '$OUTPUT_BUNDLE' && sed -i 's/\r$//' deploy_on_server.sh 2>/dev/null || true; chmod +x deploy_on_server.sh && (sudo ./deploy_on_server.sh || ./deploy_on_server.sh)"
else
    echo ""
    echo -e "${GREEN}${BOLD}==========================================================${NC}"
    echo -e "${GREEN}${BOLD}         Bundle Successfully Pushed to Remote Server!      ${NC}"
    echo -e "${GREEN}${BOLD}==========================================================${NC}"
    echo -e "The bundle has been uploaded to: ${CYAN}${TARGET_SSH}:${REMOTE_DEST}/${OUTPUT_BUNDLE}${NC}\n"
    echo -e "To execute the deployment on the server, SSH in and run:"
    echo -e "  ${CYAN}ssh ${SSH_OPTS[*]} ${TARGET_SSH}${NC}"
    echo -e "  ${CYAN}cd ${REMOTE_DEST}${NC}"
    echo -e "  ${CYAN}tar -xzf ${OUTPUT_BUNDLE}${NC}"
    echo -e "  ${CYAN}sudo ./deploy_on_server.sh${NC}"
    echo "=========================================================="
fi
