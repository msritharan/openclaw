#!/usr/bin/env bash
# OpenClaw VPS Docker + Tailscale Fully-Automated Deployment Script
# Usage: ./deploy-vps-docker.sh user@your-vps-host [--teardown]
#
# Environment variables:
#   OPENCLAW_VPS_SSH_KEY          Path to SSH private key (default: ~/.ssh/id_ed25519)
#   OPENCLAW_VPS_SSH_PORT         SSH port (default: 22)
#   OPENCLAW_VPS_TAILSCALE_KEY    Pre-provisioned Tailscale auth key (optional)
#   OPENCLAW_VPS_IMAGE            Docker image to use (default: openclaw:local = build from source)
#   OPENCLAW_VPS_BRANCH           Git branch to clone (default: main)
#   OPENCLAW_VPS_DOMAIN           Tailscale Funnel domain (optional, e.g. gateway.example.com)
#   OPENCLAW_VPS_TAILSCALE_MODE   Tailscale mode: "serve" (tailnet) or "funnel" (public) (default: serve)
#   OPENCLAW_VPS_GATEWAY_PORT     Gateway port (default: 18789)
#   SKIP_TAILSCALE                Set to 1 to skip Tailscale installation
#
# The script generates a gateway token and prints it at the end for client connection.

set -euo pipefail

# --- Color output ---
BOLD='\033[1m'
ACCENT='\033[38;2;255;77;77m'
SUCCESS='\033[38;2;0;229;204m'
WARN='\033[38;2;255;176;32m'
ERROR='\033[38;2;230;57;70m'
MUTED='\033[38;2;90;100;128m'
NC='\033[0m'

info()    { echo -e "${ACCENT}[INFO]${NC} $*"; }
success() { echo -e "${SUCCESS}[OK]${NC} $*"; }
warn()    { echo -e "${WARN}[WARN]${NC} $*"; }
error()   { echo -e "${ERROR}[ERROR]${NC} $*" >&2; }

# --- Defaults ---
SSH_USER_HOST="${1:-}"
TEARDOWN_MODE=false
OPENCLAW_VPS_SSH_KEY="${OPENCLAW_VPS_SSH_KEY:-$HOME/.ssh/id_ed25519}"
OPENCLAW_VPS_SSH_PORT="${OPENCLAW_VPS_SSH_PORT:-22}"
OPENCLAW_VPS_IMAGE="${OPENCLAW_VPS_IMAGE:-openclaw:local}"
OPENCLAW_VPS_BRANCH="${OPENCLAW_VPS_BRANCH:-main}"
OPENCLAW_VPS_DOMAIN="${OPENCLAW_VPS_DOMAIN:-}"
OPENCLAW_VPS_TAILSCALE_MODE="${OPENCLAW_VPS_TAILSCALE_MODE:-serve}"
OPENCLAW_VPS_GATEWAY_PORT="${OPENCLAW_VPS_GATEWAY_PORT:-18789}"
SKIP_TAILSCALE="${SKIP_TAILSCALE:-0}"
OPENCLAW_VPS_TAILSCALE_KEY="${OPENCLAW_VPS_TAILSCALE_KEY:-}"

# Handle --teardown flag
if [[ "${2:-}" == "--teardown" ]]; then
  TEARDOWN_MODE=true
fi

if [[ "$TEARDOWN_MODE" == "true" ]]; then
  info "Running in TEARDOWN mode - removing OpenClaw from VPS"
fi

# --- Helpers ---
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Missing required command: $1"
    exit 1
  fi
}

require_cmd ssh
require_cmd scp

# Validate SSH connection info
if [[ -z "$SSH_USER_HOST" ]]; then
  echo -e "${BOLD}OpenClaw VPS Docker + Tailscale Deployment Script${NC}"
  echo ""
  echo "Usage: $0 user@your-vps-host [options]"
  echo ""
  echo "Options:"
  echo "  --teardown              Remove OpenClaw from VPS instead of deploying"
  echo ""
  echo "Environment variables:"
  echo "  OPENCLAW_VPS_SSH_KEY         SSH private key path (default: ~/.ssh/id_ed25519)"
  echo "  OPENCLAW_VPS_SSH_PORT         SSH port (default: 22)"
  echo "  OPENCLAW_VPS_TAILSCALE_KEY    Pre-provisioned Tailscale auth key"
  echo "  OPENCLAW_VPS_IMAGE            Docker image (default: openclaw:local = build from source)"
  echo "  OPENCLAW_VPS_BRANCH           Git branch (default: main)"
  echo "  OPENCLAW_VPS_DOMAIN           Tailscale Funnel domain (optional)"
  echo "  OPENCLAW_VPS_TAILSCALE_MODE   'serve' (tailnet) or 'funnel' (public) (default: serve)"
  echo "  OPENCLAW_VPS_GATEWAY_PORT     Gateway port (default: 18789)"
  echo "  SKIP_TAILSCALE                Set to 1 to skip Tailscale"
  echo ""
  error "SSH connection info required as first argument (e.g., root@123.45.67.89)"
  exit 1
fi

# Validate Tailscale mode
if [[ "$OPENCLAW_VPS_TAILSCALE_MODE" != "serve" && "$OPENCLAW_VPS_TAILSCALE_MODE" != "funnel" ]]; then
  error "OPENCLAW_VPS_TAILSCALE_MODE must be 'serve' or 'funnel', got: $OPENCLAW_VPS_TAILSCALE_MODE"
  exit 1
fi

# SSH identity file check
SSH_ARGS=("-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null")
if [[ -f "$OPENCLAW_VPS_SSH_KEY" ]]; then
  SSH_ARGS+=("-i" "$OPENCLAW_VPS_SSH_KEY")
fi
if [[ "$OPENCLAW_VPS_SSH_PORT" != "22" ]]; then
  SSH_ARGS+=("-p" "$OPENCLAW_VPS_SSH_PORT")
fi

info "Target VPS: $SSH_USER_HOST"
info "SSH key: $OPENCLAW_VPS_SSH_KEY"
info "Tailscale mode: $OPENCLAW_VPS_TAILSCALE_MODE"

# --- SSH exec helper ---
ssh_exec() {
  ssh "${SSH_ARGS[@]}" "$SSH_USER_HOST" "$@"
}

ssh_exec_sudo() {
  ssh "${SSH_ARGS[@]}" "$SSH_USER_HOST" "sudo bash -c \"$*\""
}

# --- Pre-flight checks ---
info "Checking SSH connectivity..."
if ! ssh "${SSH_ARGS[@]}" -o "ConnectTimeout=10" "$SSH_USER_HOST" "echo 'SSH OK'" >/dev/null 2>&1; then
  error "Cannot connect to $SSH_USER_HOST via SSH. Check key/host/port."
  exit 1
fi
success "SSH connection verified"

# Detect OS
VPS_OS="$(ssh_exec "cat /etc/os-release 2>/dev/null | grep -E '^ID=' | cut -d= -f2 | tr -d '"' || echo 'unknown'")"
VPS_OS_VERSION="$(ssh_exec "cat /etc/os-release 2>/dev/null | grep -E '^VERSION_ID=' | cut -d= -f2 | tr -d '"' || echo ''")"
info "VPS OS: $VPS_OS $VPS_OS_VERSION"

# =============================================================================
# TEARDOWN MODE
# =============================================================================
if [[ "$TEARDOWN_MODE" == "true" ]]; then
  info "Stopping and removing OpenClaw containers..."
  ssh_exec "cd /opt/openclaw 2>/dev/null && docker compose down -v --remove-orphans 2>/dev/null || true" || true

  info "Removing OpenClaw files..."
  ssh_exec "rm -rf /opt/openclaw ~/.openclaw 2>/dev/null || true" || true

  if [[ "$SKIP_TAILSCALE" != "1" ]]; then
    info "Removing Tailscale configuration..."
    ssh_exec "tailscale up --reset 2>/dev/null || true" || true
  fi

  info "Disabling Docker and Tailscale on boot..."
  ssh_exec "systemctl disable docker 2>/dev/null || true" || true
  ssh_exec "systemctl disable --now tailscaled 2>/dev/null || true" || true

  success "Teardown complete"
  exit 0
fi

# =============================================================================
# DEPLOY MODE
# =============================================================================

# --- Generate gateway token ---
GATEWAY_TOKEN="$(openssl rand -hex 32 2>/dev/null)" || {
  GATEWAY_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" || {
    GATEWAY_TOKEN="$(ssh_exec "python3 -c 'import secrets; print(secrets.token_hex(32))'")"
  }
}
if [[ -z "$GATEWAY_TOKEN" ]]; then
  error "Failed to generate gateway token"
  exit 1
fi
info "Generated gateway token (will be shown at end)"

# --- Create remote setup script ---
info "Creating remote setup script..."

REMOTE_SCRIPT=$(cat <<'REMOTE_EOF'
#!/usr/bin/env bash
set -euo pipefail

TEARDOWN_MODE="${TEARDOWN_MODE:-false}"
SKIP_TAILSCALE="${SKIP_TAILSCALE:-0}"
OPENCLAW_VPS_TAILSCALE_MODE="${OPENCLAW_VPS_TAILSCALE_MODE:-serve}"
OPENCLAW_VPS_GATEWAY_PORT="${OPENCLAW_VPS_GATEWAY_PORT:-18789}"
OPENCLAW_VPS_IMAGE="${OPENCLAW_VPS_IMAGE:-openclaw:local}"
OPENCLAW_VPS_BRANCH="${OPENCLAW_VPS_BRANCH:-main}"
OPENCLAW_VPS_DOMAIN="${OPENCLAW_VPS_DOMAIN:-}"
OPENCLAW_VPS_TAILSCALE_KEY="${OPENCLAW_VPS_TAILSCALE_KEY:-}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"

BOLD='\033[1m'
ACCENT='\033[38;2;255;77;77m'
SUCCESS='\033[38;2;0;229;204m'
WARN='\033[38;2;255;176;32m'
ERROR='\033[38;2;230;57;70m'
NC='\033[0m'

log_info()    { echo -e "${ACCENT}[INFO]${NC} $*"; }
log_success() { echo -e "${SUCCESS}[OK]${NC} $*"; }
log_warn()    { echo -e "${WARN}[WARN]${NC} $*"; }
log_error()   { echo -e "${ERROR}[ERROR]${NC} $*" >&2; }

OPENCLAW_DIR="/opt/openclaw"
OPENCLAW_CONFIG_DIR="/root/.openclaw"
OPENCLAW_WORKSPACE_DIR="/root/.openclaw/workspace"

# =============================================================================
# TEARDOWN
# =============================================================================
if [[ "$TEARDOWN_MODE" == "true" ]]; then
    log_info "Stopping and removing OpenClaw containers..."
    cd "$OPENCLAW_DIR" 2>/dev/null && docker compose down -v --remove-orphans 2>/dev/null || true

    log_info "Removing OpenClaw files..."
    rm -rf "$OPENCLAW_DIR" "$OPENCLAW_CONFIG_DIR" 2>/dev/null || true

    if [[ "$SKIP_TAILSCALE" != "1" ]]; then
        log_info "Resetting Tailscale..."
        tailscale up --reset 2>/dev/null || true
    fi

    log_info "Disabling Docker and Tailscale on boot..."
    systemctl disable docker 2>/dev/null || true
    systemctl disable --now tailscaled 2>/dev/null || true

    log_success "Teardown complete"
    exit 0
fi

# =============================================================================
# DEPLOY
# =============================================================================

# --- Detect OS ---
OS_ID=""
if [[ -f /etc/os-release ]]; then
    OS_ID="$(. /etc/os-release && echo "$ID")"
fi
log_info "OS detected: $OS_ID"

# --- Install Docker ---
install_docker() {
    log_info "Installing Docker..."

    if command -v docker >/dev/null 2>&1; then
        log_success "Docker already installed: $(docker --version)"
        return 0
    fi

    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update
        apt-get install -y git curl ca-certificates gnupg lsb-release
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || \
        curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $(lsb_release -cs) stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif [[ "$OS_ID" == "fedora" || "$OS_ID" == "rhel" || "$OS_ID" == "centos" ]]; then
        dnf install -y dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        # Fallback: use convenience script
        curl -fsSL https://get.docker.com | sh
    fi

    systemctl enable --now docker
    log_success "Docker installed and started"
}

install_docker

# --- Enable Docker on boot ---
systemctl enable docker 2>/dev/null || log_warn "Could not enable Docker on boot (systemd may not be available)"

# --- Clone OpenClaw repo ---
if [[ ! -d "$OPENCLAW_DIR/.git" ]]; then
    log_info "Cloning OpenClaw repository (branch: $OPENCLAW_VPS_BRANCH)..."
    rm -rf "$OPENCLAW_DIR"
    git clone --branch "$OPENCLAW_VPS_BRANCH" --depth 1 https://github.com/openclaw/openclaw.git "$OPENCLAW_DIR"
else
    log_info "OpenClaw already cloned, pulling latest..."
    cd "$OPENCLAW_DIR"
    git pull origin "$OPENCLAW_VPS_BRANCH"
fi
cd "$OPENCLAW_DIR"

# --- Create directories ---
log_info "Creating directories..."
mkdir -p "$OPENCLAW_CONFIG_DIR"
mkdir -p "$OPENCLAW_WORKSPACE_DIR"
mkdir -p "$OPENCLAW_CONFIG_DIR/identity"
mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/agent"
mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/sessions"

# --- Build Docker image ---
if [[ "$OPENCLAW_VPS_IMAGE" == "openclaw:local" ]]; then
    log_info "Building Docker image locally..."
    docker build -t openclaw:local -f "$OPENCLAW_DIR/Dockerfile" "$OPENCLAW_DIR"
else
    log_info "Pulling Docker image: $OPENCLAW_VPS_IMAGE"
    docker pull "$OPENCLAW_VPS_IMAGE"
fi

# --- Generate or validate .env ---
ENV_FILE="$OPENCLAW_DIR/.env"
if [[ -f "$ENV_FILE" ]] && grep -q "OPENCLAW_GATEWAY_TOKEN=" "$ENV_FILE"; then
    # Preserve existing token if present
    EXISTING_TOKEN="$(grep "OPENCLAW_GATEWAY_TOKEN=" "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")"
    if [[ -n "$EXISTING_TOKEN" ]]; then
        GATEWAY_TOKEN="$EXISTING_TOKEN"
    fi"
fi

# --- Write .env file ---
log_info "Writing .env file..."
cat > "$ENV_FILE" <<ENV_EOF
OPENCLAW_IMAGE=${OPENCLAW_VPS_IMAGE}
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_GATEWAY_BIND=loopback
OPENCLAW_GATEWAY_PORT=${OPENCLAW_VPS_GATEWAY_PORT}
OPENCLAW_CONFIG_DIR=${OPENCLAW_CONFIG_DIR}
OPENCLAW_WORKSPACE_DIR=${OPENCLAW_WORKSPACE_DIR}
OPENCLAW_TZ=UTC
ENV_EOF

# --- Fix permissions ---
log_info "Fixing permissions..."
docker run --rm -u root --entrypoint sh openclaw:local -c \
    'chown -R node:node /home/node/.openclaw 2>/dev/null || true' 2>/dev/null || true
chown -R root:root "$OPENCLAW_CONFIG_DIR" 2>/dev/null || true

# --- Create docker-compose.override.yml for loopback-only ---
log_info "Configuring Docker Compose for loopback-only access..."
cat > "$OPENCLAW_DIR/docker-compose.override.yml" <<YAML_EOF
services:
  openclaw-gateway:
    ports:
      - "127.0.0.1:${OPENCLAW_VPS_GATEWAY_PORT}:18789"
YAML_EOF

# --- Install and configure Tailscale ---
TAILSCALE_SETUP_DONE=false
if [[ "$SKIP_TAILSCALE" != "1" ]]; then
    install_tailscale() {
        log_info "Installing Tailscale..."

        if command -v tailscale >/dev/null 2>&1; then
            log_success "Tailscale already installed"
            return 0
        fi

        if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
            apt-get install -y apt-transport-https
            curl -fsSL "https://pkgs.tailscale.com/stable/${OS_ID}/tailscale.gpg" > /etc/apt/trusted.gpg.d/tailscale.gpg 2>/dev/null || \
            curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs)_all.tgz" -o /tmp/tailscale.tgz 2>/dev/null
            echo "deb https://pkgs.tailscale.com/stable/${OS_ID} $(lsb_release -cs) main" > /etc/apt/sources.list.d/tailscale.list
            apt-get update
            apt-get install -y tailscale
        else
            # Use official install script
            curl -fsSL https://tailscale.com/install.sh | sh
        fi
    }

    install_tailscale

    # Configure Tailscale
    log_info "Configuring Tailscale..."

    if [[ -n "$OPENCLAW_VPS_TAILSCALE_KEY" ]]; then
        # Use pre-provisioned auth key (non-interactive)
        log_info "Using provided Tailscale auth key..."
        tailscale up --authkey="$OPENCLAW_VPS_TAILSCALE_KEY" --accept-dns=false
        TAILSCALE_SETUP_DONE=true
    else
        # Interactive login (requires user to authenticate)
        log_info "Tailscale needs authentication. You will be given a URL to complete login."
        log_info "If running non-interactively, set OPENCLAW_VPS_TAILSCALE_KEY with a pre-provisioned auth key."
        echo ""
        echo "=== TAILSCALE AUTHENTICATION ==="
        tailscale up --accept-dns=false
        TAILSCALE_SETUP_DONE=true
        echo "=== END TAILSCALE AUTHENTICATION ==="
    fi

    if [[ "$TAILSCALE_SETUP_DONE" == "true" ]]; then
        # Get Tailscale hostname/IP
        TAILNET_HOSTNAME="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName",d.get("Self",{}).get("TailscaleIPs",[""])[0])' 2>/dev/null || echo "")"
        TAILNET_IP="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); ips=d.get("Self",{}).get("TailscaleIPs",[]); print(ips[0] if ips else "")' 2>/dev/null || echo "")"

        log_success "Tailscale connected!"
        log_info "Tailnet hostname: $TAILNET_HOSTNAME"
        log_info "Tailnet IP: $TAILNET_IP"

        # Enable on boot
        systemctl enable --now tailscaled 2>/dev/null || log_warn "Could not enable Tailscale on boot (systemd may not be available)"

        # Configure Tailscale serve/funnel
        if [[ "$OPENCLAW_VPS_TAILSCALE_MODE" == "serve" ]]; then
            log_info "Enabling Tailscale Serve (tailnet access only)..."
            tailscale serve --bg --yes "http://127.0.0.1:${OPENCLAW_VPS_GATEWAY_PORT}"
            if [[ -n "$TAILNET_HOSTNAME" ]]; then
                log_success "Gateway accessible at: https://${TAILNET_HOSTNAME}/"
                log_success "WebSocket: wss://${TAILNET_HOSTNAME}/"
            fi
        elif [[ "$OPENCLAW_VPS_TAILSCALE_MODE" == "funnel" ]]; then
            log_info "Enabling Tailscale Funnel (public HTTPS)..."
            if [[ -n "$OPENCLAW_VPS_DOMAIN" ]]; then
                tailscale funnel --bg --yes "${OPENCLAW_VPS_GATEWAY_PORT}"
                tailscale funnel 443 "${OPENCLAW_VPS_DOMAIN}"
            else
                tailscale funnel --bg --yes "${OPENCLAW_VPS_GATEWAY_PORT}"
            fi
            log_success "Gateway accessible publicly via Funnel"
        fi
    fi
else
    log_info "Skipping Tailscale installation (SKIP_TAILSCALE=1)"
fi

# --- Start gateway ---
log_info "Starting OpenClaw gateway..."
cd "$OPENCLAW_DIR"
docker compose down 2>/dev/null || true
docker compose up -d openclaw-gateway

# Wait for gateway to be ready
log_info "Waiting for gateway to start..."
sleep 5

# --- Verify ---
if docker compose ps openclaw-gateway | grep -q "Up"; then
    log_success "OpenClaw gateway is running!"
else
    log_warn "Gateway may not have started properly. Check logs with: docker compose -f $OPENCLAW_DIR/docker-compose.yml logs -f"
fi

# --- Print connection info ---
echo ""
echo "=============================================="
echo -e "${BOLD}OpenClaw VPS Deployment Complete${NC}"
echo "=============================================="
echo ""
echo "Gateway token (save this!):"
echo -e "${BOLD}${GATEWAY_TOKEN}${NC}"
echo ""
echo "Connection info:"
if [[ "$OPENCLAW_VPS_TAILSCALE_MODE" == "serve" && -n "$TAILNET_HOSTNAME" ]]; then
    echo "  Control UI: https://${TAILNET_HOSTNAME}/"
    echo "  WebSocket:  wss://${TAILNET_HOSTNAME}/"
elif [[ "$OPENCLAW_VPS_TAILSCALE_MODE" == "funnel" ]]; then
    echo "  Public URL: Check Tailscale dashboard for Funnel URL"
fi
echo "  SSH tunnel: ssh -N -L ${OPENCLAW_VPS_GATEWAY_PORT}:127.0.0.1:${OPENCLAW_VPS_GATEWAY_PORT} $SSH_USER_HOST"
echo "  Local:      http://127.0.0.1:${OPENCLAW_VPS_GATEWAY_PORT}/"
echo ""
echo "Commands on VPS:"
echo "  docker compose -f $OPENCLAW_DIR/docker-compose.yml logs -f"
echo "  docker compose -f $OPENCLAW_DIR/docker-compose.yml restart"
echo "  docker compose -f $OPENCLAW_DIR/docker-compose.yml down"
echo ""
echo "Token file: $ENV_FILE"
echo "=============================================="
REMOTE_EOF

# --- Upload and execute remote script ---
info "Uploading setup script to VPS..."
SCP_ARGS=("-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null")
if [[ -f "$OPENCLAW_VPS_SSH_KEY" ]]; then
  SCP_ARGS+=("-i" "$OPENCLAW_VPS_SSH_KEY")
fi
if [[ "$OPENCLAW_VPS_SSH_PORT" != "22" ]]; then
  SCP_ARGS+=("-P" "$OPENCLAW_VPS_SSH_PORT")
fi

REMOTE_SCRIPT_PATH="/tmp/openclaw-vps-setup-$$.sh"
chmod +x "$0"
scp "${SCP_ARGS[@]}" "$0" "$SSH_USER_HOST:$REMOTE_SCRIPT_PATH" 2>/dev/null || {
    error "Failed to upload setup script"
    exit 1
}

# Pass all env vars to remote
info "Executing setup on VPS (this may take several minutes)..."
ssh "${SSH_ARGS[@]}" "$SSH_USER_HOST" \
  TEARDOWN_MODE="$TEARDOWN_MODE" \
  SKIP_TAILSCALE="$SKIP_TAILSCALE" \
  OPENCLAW_VPS_TAILSCALE_MODE="$OPENCLAW_VPS_TAILSCALE_MODE" \
  OPENCLAW_VPS_GATEWAY_PORT="$OPENCLAW_VPS_GATEWAY_PORT" \
  OPENCLAW_VPS_IMAGE="$OPENCLAW_VPS_IMAGE" \
  OPENCLAW_VPS_BRANCH="$OPENCLAW_VPS_BRANCH" \
  OPENCLAW_VPS_DOMAIN="$OPENCLAW_VPS_DOMAIN" \
  OPENCLAW_VPS_TAILSCALE_KEY="$OPENCLAW_VPS_TAILSCALE_KEY" \
  GATEWAY_TOKEN="$GATEWAY_TOKEN" \
  SSH_USER_HOST="$SSH_USER_HOST" \
  "bash $REMOTE_SCRIPT_PATH"

# Cleanup
ssh "${SSH_ARGS[@]}" "$SSH_USER_HOST" "rm -f $REMOTE_SCRIPT_PATH"

# --- Final output ---
echo ""
echo "=============================================="
echo -e "${BOLD}Deployment Summary${NC}"
echo "=============================================="
echo ""
echo -e "${BOLD}Gateway Token:${NC} ${GATEWAY_TOKEN}"
echo ""
echo "IMPORTANT: Save this token! You'll need it to connect your OpenClaw client."
echo ""
echo "To connect your client, run:"
echo "  openclaw gateway connect --token ${GATEWAY_TOKEN}"
echo ""
echo "Or manually add to your openclaw.json:"
echo '  { "gateway": { "auth": { "token": "'"${GATEWAY_TOKEN}"'" } } }'
echo ""
echo "=============================================="

success "Done!"
