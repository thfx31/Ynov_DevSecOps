variable "name" {
  description = "Nom de la VM (hostname)"
  type        = string
}

variable "memory" {
  description = "RAM en MiB"
  type        = number
  default     = 1024
}

variable "vcpus" {
  description = "Nombre de vCPU"
  type        = number
  default     = 1
}

variable "disk_size_gb" {
  description = "Taille du disque VM en Go"
  type        = number
  default     = 20
}

variable "ip_address" {
  description = "IP statique de la VM (ex: 10.0.0.10)"
  type        = string
}

variable "gateway" {
  description = "Passerelle réseau"
  type        = string
  default     = "10.0.0.1"
}

variable "dns_server" {
  description = "Serveur DNS"
  type        = string
  default     = "8.8.8.8"
}

variable "network_name" {
  description = "Nom du réseau libvirt"
  type        = string
}

variable "base_image_path" {
  description = "Path du volume de base (libvirt_volume.path — image Packer)"
  type        = string
}

variable "pool" {
  description = "Nom du pool de stockage libvirt"
  type        = string
}

variable "ssh_pub_key" {
  description = "Clé publique SSH à injecter"
  type        = string
}

variable "mac_address" {
  description = "Adresse MAC fixe de l'interface réseau (ex: 52:54:00:00:00:10)"
  type        = string
}
