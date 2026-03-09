###############################################################################
# Zero-Trust Mesh VPN — Terraform Main Configuration
# Infrastructure: DigitalOcean VPS + Cloud Firewall
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Uncomment to enable remote state (recommended for teams)
  # backend "s3" {
  #   endpoint                    = "https://nyc3.digitaloceanspaces.com"
  #   bucket                      = "mesh-vpn-tfstate"
  #   key                         = "terraform.tfstate"
  #   region                      = "us-east-1"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  # }
}

###############################################################################
# Provider
###############################################################################

provider "digitalocean" {
  token = var.do_token
}

###############################################################################
# Data Sources
###############################################################################

data "digitalocean_ssh_key" "default" {
  # Pull the SSH key by fingerprint — must already exist in your DO account
  fingerprint = var.ssh_key_fingerprint
}

###############################################################################
# Random Suffix — prevents naming collisions on re-deploy
###############################################################################

resource "random_id" "suffix" {
  byte_length = 4
}

###############################################################################
# VPS Droplet — Netmaker Control Plane Server
###############################################################################

resource "digitalocean_droplet" "netmaker" {
  name   = "${var.project_name}-server-${random_id.suffix.hex}"
  image  = var.ubuntu_image
  size   = var.droplet_size
  region = var.region

  # Enable monitoring for CPU/memory graphs in the DO dashboard
  monitoring = true

  # Enable automated weekly backups (recommended for production)
  backups = var.environment == "production" ? true : false

  # Inject SSH key for secure headless access
  ssh_keys = [data.digitalocean_ssh_key.default.id]

  # Cloud-init: bootstrap essentials immediately on first boot
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # System hardening baseline
    export DEBIAN_FRONTEND=noninteractive

    # Update and install minimal dependencies
    apt-get update -qq
    apt-get install -yq \
      curl \
      git \
      unzip \
      ufw \
      fail2ban \
      ca-certificates \
      gnupg \
      lsb-release

    # Harden SSH: disable password auth, disable root password login
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl restart sshd

    # Enable fail2ban with defaults to protect SSH
    systemctl enable --now fail2ban

    # Set hostname
    hostnamectl set-hostname ${var.project_name}-server

    # Clone the project repository for setup scripts
    mkdir -p /opt/mesh-vpn
    git clone https://github.com/${var.project_name}/zero-trust-mesh-vpn /opt/mesh-vpn || true

    # Signal Terraform that setup is complete
    touch /tmp/terraform_bootstrap_complete

    echo "Bootstrap complete: $(date)" >> /var/log/mesh-vpn-bootstrap.log
  EOF

  tags = [
    var.project_name,
    var.environment,
    "netmaker",
    "wireguard"
  ]

  lifecycle {
    # Prevent accidental destruction of a running production VPN server
    prevent_destroy = false

    # Recreate droplet if image or size changes
    create_before_destroy = true
  }
}

###############################################################################
# Cloud Firewall — Defense in depth (in addition to UFW on the host)
###############################################################################

resource "digitalocean_firewall" "netmaker" {
  name = "${var.project_name}-firewall-${random_id.suffix.hex}"

  droplet_ids = [digitalocean_droplet.netmaker.id]

  # ── Inbound Rules ──────────────────────────────────────────────────────────

  # SSH — restrict to your management IP in production via a variable
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"] # Tighten in production!
  }

  # HTTPS — Caddy reverse proxy (Netmaker API + UI)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTP — Caddy ACME challenge redirect only
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # WireGuard mesh tunnel — all nodes use this UDP port
  inbound_rule {
    protocol         = "udp"
    port_range       = "51821"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # MQTT over TLS — node-to-server signaling channel
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8883"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # ICMP — allow ping for connectivity diagnostics
  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # ── Outbound Rules — allow all egress (downloads, DNS, NTP) ───────────────

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  tags = [var.project_name, var.environment]
}

###############################################################################
# DigitalOcean Project — groups all resources for billing/visibility
###############################################################################

resource "digitalocean_project" "mesh_vpn" {
  name        = "${var.project_name}-${var.environment}"
  description = "Zero-Trust Mesh VPN — WireGuard + Netmaker control plane"
  purpose     = "Service or API"
  environment = title(var.environment)

  resources = [
    digitalocean_droplet.netmaker.urn,
  ]
}
