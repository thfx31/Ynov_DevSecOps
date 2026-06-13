# Vault - production mode
# Ce fichier est déployé via le template ansible/roles/vault-server/templates/vault.hcl.j2
# Conservé ici pour référence et pour le lint checkov/tfsec

ui = true
disable_mlock = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-node-01"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr     = "http://10.0.0.10:8200"
cluster_addr = "https://10.0.0.10:8201"

default_lease_ttl = "1h"
max_lease_ttl     = "24h"
