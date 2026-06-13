# Politique Vault - workloads applicatifs (workload-a, workload-b)

# SSH OTP - générer un mot de passe à usage unique
path "ssh/creds/otp-role" {
  capabilities = ["update"]
}

# Database secrets - lire des credentials PostgreSQL éphémères
path "database/creds/app-role" {
  capabilities = ["read"]
}

# Transit - chiffrement/déchiffrement de données sensibles
path "transit/encrypt/app-key" {
  capabilities = ["update"]
}
path "transit/decrypt/app-key" {
  capabilities = ["update"]
}

# Renouvellement de lease avant expiration
path "sys/leases/renew" {
  capabilities = ["update"]
}

# Révocation d'un lease spécifique
path "sys/leases/revoke" {
  capabilities = ["update"]
}
