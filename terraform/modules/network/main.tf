terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.0"
    }
  }
}

resource "libvirt_network" "zero_trust" {
  name      = var.network_name
  mode      = "nat"
  autostart = true
  addresses = [var.network_cidr]

  dns {
    enabled    = true
    local_only = false
  }
}
