packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

variable "ubuntu_url" {
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ubuntu_checksum" {
  default = "file:https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
}

variable "disk_size" {
  default = "10240M"
}

variable "memory" {
  default = 2048
}

variable "cpus" {
  default = 2
}

source "qemu" "ubuntu_cis" {
  iso_url      = var.ubuntu_url
  iso_checksum = var.ubuntu_checksum
  disk_image   = true

  disk_size        = var.disk_size
  disk_interface   = "virtio"
  format           = "qcow2"
  output_directory = "${path.root}/output"
  vm_name          = "ubuntu-cis-hardened.qcow2"

  # Cloud-init seed ISO - sets ubuntu user + password for Packer SSH
  cd_files = [
    "${path.root}/cloud-init/meta-data",
    "${path.root}/cloud-init/user-data",
  ]
  cd_label = "cidata"

  machine_type = "q35"
  accelerator  = "kvm"
  cpus         = var.cpus
  memory       = var.memory
  headless     = true
  net_device   = "virtio-net"

  ssh_username = "ubuntu"
  ssh_password = "ubuntu"
  ssh_timeout  = "15m"
  boot_wait    = "15s"

  shutdown_command = "sudo shutdown -P now"
}

build {
  name    = "ubuntu-cis"
  sources = ["source.qemu.ubuntu_cis"]

  # Attendre la fin de cloud-init avant de provisionner
  provisioner "shell" {
    execute_command = "sudo bash {{ .Path }}"
    inline          = ["cloud-init status --wait || true"]
  }

  provisioner "shell" {
    execute_command = "sudo bash -c '{{ .Vars }} {{ .Path }}'"
    scripts         = ["${path.root}/scripts/cis-hardening.sh"]
  }

  # Templating de l'image (reset machine-id, clean logs)
  provisioner "shell" {
    execute_command = "sudo bash {{ .Path }}"
    inline = [
      "apt-get clean -y",
      "rm -rf /var/log/*.log /var/log/*.gz",
      "truncate -s 0 /etc/machine-id",
      "sync",
    ]
  }
}
