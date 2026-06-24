terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.0"
    }
  }
}

# Disque VM
resource "libvirt_volume" "vm_disk" {
  name   = "${var.name}.qcow2"
  pool   = var.pool
  source = var.base_image_path
  format = "qcow2"
}

# Cloud-init ISO
resource "libvirt_cloudinit_disk" "vm_cloudinit" {
  name   = "${var.name}-cloudinit.iso"
  pool   = var.pool

  user_data = templatefile("${path.module}/templates/cloud_init.tpl", {
    hostname    = var.name
    ssh_pub_key = var.ssh_pub_key
    ip_address  = var.ip_address
    gateway     = var.gateway
    dns         = var.dns_server
  })

  meta_data = templatefile("${path.module}/templates/meta_data.tpl", {
    hostname = var.name
  })
}

resource "libvirt_domain" "vm" {
  name      = var.name
  memory    = var.memory
  vcpu      = var.vcpus
  autostart = true

  # Attachement direct du disque et du cloud-init ISO
  cloudinit = libvirt_cloudinit_disk.vm_cloudinit.id

  network_interface {
    network_name   = var.network_name
    mac            = var.mac_address
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.vm_disk.id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }
}
