terraform {
  required_version = ">= 1.5"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.0"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

resource "libvirt_pool" "main" {
  name = "devsecops-pool"
  type = "dir"
  path = var.pool_path
}

module "network" {
  source       = "./modules/network"
  network_name = var.network_name
  network_cidr = var.network_cidr
}

module "vault_server" {
  source          = "./modules/vm"
  name            = "vault-server"
  memory          = 2048
  vcpus           = 2
  ip_address      = "10.0.0.10"
  mac_address     = "52:54:00:00:00:10"
  gateway         = var.network_gateway
  network_name    = module.network.network_name
  base_image_path = abspath(var.base_image_path)
  pool            = libvirt_pool.main.name
  ssh_pub_key     = var.ssh_public_key
}

module "spire_server" {
  source          = "./modules/vm"
  name            = "spire-server"
  memory          = 1024
  vcpus           = 1
  ip_address      = "10.0.0.11"
  mac_address     = "52:54:00:00:00:11"
  gateway         = var.network_gateway
  network_name    = module.network.network_name
  base_image_path = abspath(var.base_image_path)
  pool            = libvirt_pool.main.name
  ssh_pub_key     = var.ssh_public_key
}

module "workload_a" {
  source          = "./modules/vm"
  name            = "workload-a"
  memory          = 1024
  vcpus           = 1
  ip_address      = "10.0.0.20"
  mac_address     = "52:54:00:00:00:14"
  gateway         = var.network_gateway
  network_name    = module.network.network_name
  base_image_path = abspath(var.base_image_path)
  pool            = libvirt_pool.main.name
  ssh_pub_key     = var.ssh_public_key
}

module "workload_b" {
  source          = "./modules/vm"
  name            = "workload-b"
  memory          = 1024
  vcpus           = 1
  ip_address      = "10.0.0.21"
  mac_address     = "52:54:00:00:00:15"
  gateway         = var.network_gateway
  network_name    = module.network.network_name
  base_image_path = abspath(var.base_image_path)
  pool            = libvirt_pool.main.name
  ssh_pub_key     = var.ssh_public_key
}
