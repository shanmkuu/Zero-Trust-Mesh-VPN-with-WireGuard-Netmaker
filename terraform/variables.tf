###############################################################################
# Zero-Trust Mesh VPN — Terraform Variables
# Provider: DigitalOcean  (easily swappable for Hetzner, Vultr, AWS Lightsail)
###############################################################################

variable "do_token" {
  description = "DigitalOcean API token (create at cloud.digitalocean.com/account/api/tokens)"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean datacenter region slug"
  type        = string
  default     = "nyc3"

  validation {
    condition     = contains(["nyc1", "nyc3", "ams3", "sgp1", "lon1", "fra1", "tor1", "blr1", "sfo3"], var.region)
    error_message = "The region must be a valid DigitalOcean datacenter slug."
  }
}

variable "droplet_size" {
  description = "Droplet size slug. Minimum recommended: s-2vcpu-4gb for production Netmaker"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "ubuntu_image" {
  description = "Ubuntu image slug — always use LTS"
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ssh_key_fingerprint" {
  description = "SSH key fingerprint already uploaded to your DigitalOcean account"
  type        = string
}

variable "base_domain" {
  description = "Base domain for the Netmaker deployment (e.g. vpn.example.com). DNS must point to the server IP."
  type        = string
}

variable "project_name" {
  description = "Tag prefix applied to all created resources for easy filtering"
  type        = string
  default     = "mesh-vpn"
}

variable "environment" {
  description = "Deployment environment label"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be one of: production, staging, development."
  }
}
