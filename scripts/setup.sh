#!/usr/bin/env bash
################################################################################
# setup.sh — Zero-Trust Mesh VPN Automated Setup Script
#
# Automates the full deployment of the Netmaker + WireGuard stack on Ubuntu.
#
# Features:
#   ✓ Root / OS validation
#   ✓ Docker Engine & Docker Compose v2 installation
#   ✓ WireGuard kernel module setup
#   ✓ Interactive .env configuration
#   ✓ UFW firewall hardening
#   ✓ Mosquitto config generation
#   ✓ Docker Compose stack launch
#   ✓ Health check polling with timeout
#
# Usage: sudo bash setup.sh
# Tested on: Ubuntu 22.04 LTS, Ubuntu 24.04 LTS
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ── Color Palette ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Script Constants ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="${PROJECT_DIR}/docker"
LOG_FILE="/var/log/mesh-vpn-setup.log"
NETMAKER_VERSION="v0.26.0"

# ── Logging ──────────────────────────────────────────────────────────────────
log()    { echo -e "${GREEN}[✓]${RESET} $*" | tee -a "$LOG_FILE"; }
info()   { echo -e "${CYAN}[→]${RESET} $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[✗]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }

banner() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║     Zero-Trust Mesh VPN — WireGuard + Netmaker Setup        ║"
  echo "║                   by mesh-vpn-automation                    ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

success_banner() {
  local domain="$1"
  echo -e "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                 🎉  Deployment Complete!  🎉                 ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Dashboard  →  https://dashboard.${domain}"
  echo "║  API        →  https://api.${domain}"
  echo "║  MQTT       →  broker.${domain}:8883"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Log file   →  ${LOG_FILE}"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ── Pre-flight Checks ────────────────────────────────────────────────────────
preflight_checks() {
  banner
  info "Running pre-flight checks..."

  # Root check
  if [[ "$EUID" -ne 0 ]]; then
    error "This script must be run as root. Use: sudo bash $0"
  fi

  # OS check — Ubuntu 22.04+ required
  if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    error "This script requires Ubuntu 22.04 LTS or newer."
  fi

  local version
  version=$(grep "^VERSION_ID" /etc/os-release | cut -d'"' -f2 | tr -d '.')
  if [[ "$version" -lt 2204 ]]; then
    error "Ubuntu 22.04+ required. Found: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
  fi

  # Internet connectivity
  if ! curl -sf --max-time 5 https://get.docker.com > /dev/null; then
    error "No internet connectivity. Please check your network and try again."
  fi

  # CPU architecture
  local arch
  arch=$(uname -m)
  if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
    warn "Untested architecture: ${arch}. Proceeding anyway..."
  fi

  # Disk space — require at least 10GB free
  local free_gb
  free_gb=$(df / --output=avail | tail -1)
  free_gb=$((free_gb / 1024 / 1024))
  if [[ "$free_gb" -lt 10 ]]; then
    error "Insufficient disk space. At least 10GB free required. Found: ${free_gb}GB."
  fi

  log "All pre-flight checks passed."
}

# ── System Update ────────────────────────────────────────────────────────────
update_system() {
  info "Updating system packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -yq --no-install-recommends \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
  apt-get install -yq --no-install-recommends \
    curl \
    wget \
    git \
    gnupg \
    lsb-release \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    ufw \
    fail2ban \
    jq \
    net-tools
  log "System packages updated."
}

# ── WireGuard Installation ────────────────────────────────────────────────────
install_wireguard() {
  info "Installing WireGuard..."

  if command -v wg &>/dev/null; then
    log "WireGuard already installed: $(wg --version 2>/dev/null || echo 'OK')"
    return 0
  fi

  apt-get install -yq wireguard wireguard-tools

  # Load kernel module
  modprobe wireguard 2>/dev/null || warn "WireGuard kernel module may already be loaded."

  # Ensure module loads on boot
  echo "wireguard" > /etc/modules-load.d/wireguard.conf

  # Enable IP forwarding for WireGuard routing
  cat >> /etc/sysctl.d/99-wireguard.conf <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
  sysctl --system -q

  log "WireGuard installed and configured: $(wg --version)"
}

# ── Docker Installation ───────────────────────────────────────────────────────
install_docker() {
  info "Installing Docker Engine..."

  if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
    return 0
  fi

  # Use the official Docker installation script
  curl -fsSL https://get.docker.com | bash

  # Enable and start Docker service
  systemctl enable --now docker

  # Install Docker Compose v2 plugin (if not bundled)
  if ! docker compose version &>/dev/null; then
    info "Installing Docker Compose v2 plugin..."
    apt-get install -yq docker-compose-plugin
  fi

  log "Docker installed: $(docker --version)"
  log "Docker Compose: $(docker compose version)"
}

# ── Interactive Configuration ─────────────────────────────────────────────────
configure_env() {
  info "Configuring environment..."

  local env_file="${DOCKER_DIR}/.env"

  if [[ -f "$env_file" ]]; then
    warn ".env file already exists at ${env_file}"
    read -rp "Overwrite existing configuration? [y/N] " overwrite
    if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
      log "Keeping existing .env file."
      return 0
    fi
  fi

  echo
  echo -e "${BOLD}${CYAN}━━━━━━━━━━  Configuration  ━━━━━━━━━━${RESET}"
  echo -e "${YELLOW}Enter values for your Netmaker deployment.${RESET}"
  echo

  # BASE_DOMAIN
  while true; do
    read -rp "$(echo -e "${BOLD}Base Domain${RESET} (e.g. vpn.example.com): ")" BASE_DOMAIN
    if [[ "$BASE_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    fi
    warn "Invalid domain. Please enter a valid domain name."
  done

  # Get public IP automatically
  info "Auto-detecting public IP address..."
  SERVER_HOST=$(curl -sf --max-time 10 https://api.ipify.org \
    || curl -sf --max-time 10 https://checkip.amazonaws.com \
    || ip route get 1 | awk '{print $7; exit}' \
    || echo "0.0.0.0")

  echo -e "  Detected public IP: ${GREEN}${SERVER_HOST}${RESET}"
  read -rp "Press Enter to use ${SERVER_HOST}, or type a different IP: " custom_ip
  if [[ -n "$custom_ip" ]]; then
    SERVER_HOST="$custom_ip"
  fi

  # MASTER_KEY
  local generated_key
  generated_key=$(openssl rand -hex 32)
  echo
  echo -e "${BOLD}Netmaker Master Key${RESET}"
  echo -e "  Auto-generated: ${GREEN}${generated_key}${RESET}"
  read -rp "Press Enter to use this key, or type your own: " custom_key
  MASTER_KEY="${custom_key:-$generated_key}"

  # MQ Credentials
  echo
  echo -e "${BOLD}MQTT Broker Credentials${RESET}"
  read -rp "  MQ Username [netmaker]: " MQ_USERNAME
  MQ_USERNAME="${MQ_USERNAME:-netmaker}"

  local generated_mq_pass
  generated_mq_pass=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
  echo -e "  Auto-generated MQ password: ${GREEN}${generated_mq_pass}${RESET}"
  read -rp "  Press Enter to use this password, or type your own: " custom_mq_pass
  MQ_PASSWORD="${custom_mq_pass:-$generated_mq_pass}"

  # Write .env
  cat > "$env_file" <<ENV
# Generated by setup.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# DO NOT commit this file to git!

BASE_DOMAIN=${BASE_DOMAIN}
SERVER_HOST=${SERVER_HOST}
MASTER_KEY=${MASTER_KEY}
MQ_USERNAME=${MQ_USERNAME}
MQ_PASSWORD=${MQ_PASSWORD}
DISPLAY_KEYS=false
VERBOSITY=1
METRICS_EXPORTER=off
ENV

  chmod 600 "$env_file"
  log "Environment file written to ${env_file}"
}

# ── Mosquitto Config ──────────────────────────────────────────────────────────
generate_mosquitto_config() {
  info "Generating Mosquitto configuration..."

  # Source .env to get credentials
  # shellcheck disable=SC1090
  source "${DOCKER_DIR}/.env"

  local mq_conf="${DOCKER_DIR}/mosquitto.conf"

  cat > "$mq_conf" <<MQCONF
# mosquitto.conf — generated by setup.sh
# Eclipse Mosquitto 2.0 configuration for Netmaker

listener 1883 0.0.0.0
protocol mqtt

# MQTT 5 support
allow_anonymous false
password_file /mosquitto/config/passwd

persistence true
persistence_location /mosquitto/data/

log_dest file /mosquitto/log/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information

connection_messages true
MQCONF

  # Generate Mosquitto password file
  local passwd_file="${DOCKER_DIR}/mosquitto_passwd"
  touch "$passwd_file"

  # Use mosquitto_passwd if available, otherwise create raw htpasswd equivalent
  if command -v mosquitto_passwd &>/dev/null; then
    mosquitto_passwd -b "$passwd_file" "$MQ_USERNAME" "$MQ_PASSWORD"
  else
    # Docker will handle passwd generation via entrypoint
    echo "${MQ_USERNAME}:${MQ_PASSWORD}" > "$passwd_file"
    warn "mosquitto_passwd not found locally. Password will be hashed on container start."
  fi

  chmod 600 "$passwd_file"
  log "Mosquitto configuration generated."
}

# ── UFW Firewall ──────────────────────────────────────────────────────────────
configure_ufw() {
  info "Configuring UFW firewall..."

  # Reset to defaults
  ufw --force reset

  # Default policies
  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny routed

  # SSH (critical — must be allowed before enabling UFW)
  ufw allow 22/tcp comment "SSH management"

  # WireGuard mesh tunnel
  ufw allow 51821/udp comment "WireGuard Mesh VPN"

  # MQTT TLS (Netmaker node signaling)
  ufw allow 8883/tcp comment "MQTT over TLS (Netmaker)"

  # HTTPS (Caddy reverse proxy — Netmaker API and UI)
  ufw allow 443/tcp comment "HTTPS — Netmaker API & UI"

  # HTTP (ACME Let's Encrypt challenge only)
  ufw allow 80/tcp comment "HTTP — ACME challenge only"

  # Enable UFW non-interactively
  ufw --force enable

  log "UFW configured and enabled."
  echo
  ufw status verbose | tee -a "$LOG_FILE"
}

# ── Launch Stack ─────────────────────────────────────────────────────────────
launch_stack() {
  info "Pulling Docker images and launching Netmaker stack..."
  cd "$DOCKER_DIR"

  # Pull all images first (faster startup)
  docker compose pull

  # Launch in detached mode
  docker compose up -d

  log "Docker Compose stack launched."
}

# ── Health Check ──────────────────────────────────────────────────────────────
health_check() {
  # shellcheck disable=SC1090
  source "${DOCKER_DIR}/.env"

  info "Waiting for Netmaker API to become healthy..."

  local max_attempts=30
  local attempt=0
  local api_url="https://api.${BASE_DOMAIN}/api/server/health"

  while [[ "$attempt" -lt "$max_attempts" ]]; do
    attempt=$((attempt + 1))
    info "  Health check attempt ${attempt}/${max_attempts}..."

    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$api_url" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
      log "Netmaker API is healthy!"
      return 0
    fi

    sleep 10
  done

  warn "Health check timed out after $((max_attempts * 10)) seconds."
  warn "The server may still be starting. Check logs with: docker compose -f ${DOCKER_DIR}/docker-compose.yml logs"
}

# ── Main Execution ────────────────────────────────────────────────────────────
main() {
  # Create log file
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
  echo "Setup started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$LOG_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"

  preflight_checks
  update_system
  install_wireguard
  install_docker
  configure_env
  generate_mosquitto_config
  configure_ufw
  launch_stack
  health_check

  # shellcheck disable=SC1090
  source "${DOCKER_DIR}/.env"
  success_banner "$BASE_DOMAIN"
}

main "$@"
