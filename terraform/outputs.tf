output "vault_server_ip" {
  value = "10.0.0.10"
}

output "spire_server_ip" {
  value = "10.0.0.11"
}

output "workload_a_ip" {
  value = "10.0.0.20"
}

output "workload_b_ip" {
  value = "10.0.0.21"
}

output "network_name" {
  value = module.network.network_name
}

output "ansible_inventory_hint" {
  value = <<-EOT
    vault-server  ansible_host=10.0.0.10
    spire-server  ansible_host=10.0.0.11
    workload-a    ansible_host=10.0.0.20
    workload-b    ansible_host=10.0.0.21
  EOT
}
