output "domain_id" {
  value = libvirt_domain.vm.id
}

output "domain_name" {
  value = libvirt_domain.vm.name
}

output "ip_address" {
  value = var.ip_address
}
