variable "libvirt_uri" {
  description = "URI de connexion au démon libvirt"
  default     = "qemu:///system"
}

variable "pool_path" {
  description = "Chemin du pool de stockage libvirt"
  default     = "/var/lib/libvirt/images/devsecops"
}

variable "base_image_path" {
  description = "Chemin vers l'image Packer buildée (qcow2)"
  default     = "../packer/output/ubuntu-cis-hardened.qcow2"
}

variable "network_name" {
  description = "Nom du réseau libvirt"
  default     = "zero-trust-net"
}

variable "network_cidr" {
  description = "CIDR du réseau interne"
  default     = "10.0.0.0/24"
}

variable "network_gateway" {
  description = "Passerelle du réseau interne"
  default     = "10.0.0.1"
}

variable "ssh_public_key" {
  description = "Clé publique SSH injectée dans les VMs via cloud-init"
  type        = string
}
