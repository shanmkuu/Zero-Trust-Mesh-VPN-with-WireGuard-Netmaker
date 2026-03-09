###############################################################################
# Zero-Trust Mesh VPN — Terraform Outputs
###############################################################################

output "server_ip" {
  description = "Public IPv4 address of the Netmaker VPS — point DNS A records here"
  value       = digitalocean_droplet.netmaker.ipv4_address
}

output "server_id" {
  description = "DigitalOcean Droplet ID"
  value       = digitalocean_droplet.netmaker.id
}

output "server_urn" {
  description = "Droplet URN for use with DigitalOcean Projects"
  value       = digitalocean_droplet.netmaker.urn
}

output "firewall_id" {
  description = "ID of the cloud-level firewall protecting the droplet"
  value       = digitalocean_firewall.netmaker.id
}

output "dns_instructions" {
  description = "DNS configuration instructions"
  value       = <<-EOT
    =========================================================
     DNS Records to Configure at Your Registrar
    =========================================================
     Point the following A records to: ${digitalocean_droplet.netmaker.ipv4_address}

       api.${var.base_domain}           →  ${digitalocean_droplet.netmaker.ipv4_address}
       dashboard.${var.base_domain}     →  ${digitalocean_droplet.netmaker.ipv4_address}
       broker.${var.base_domain}        →  ${digitalocean_droplet.netmaker.ipv4_address}

     After DNS propagation, run the setup script:
       ssh root@${digitalocean_droplet.netmaker.ipv4_address} 'bash /opt/mesh-vpn/scripts/setup.sh'
    =========================================================
  EOT
}
