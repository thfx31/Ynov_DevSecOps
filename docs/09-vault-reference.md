# Vault - Référence fonctionnelle

HashiCorp Vault est une plateforme de gestion des secrets et des accès. Il fait
quatre choses fondamentalement différentes.

---

## 1. Secrets statiques - KV Store

Coffre-fort chiffré pour les secrets qui ne peuvent pas être dynamiques.

```bash
# Ecrire
vault kv put secret/app/config \
  api_key="xyz123" \
  stripe_key="sk_live_..."

# Lire
vault kv get secret/app/config

# Versionning - rollback possible
vault kv get -version=2 secret/app/config
vault kv rollback -version=1 secret/app/config
```

**Usecase :** clés API tierces (Stripe, Twilio...), tokens GitHub Actions,
secrets de configuration qui ne changent pas souvent.

**Ce que ça apporte vs un `.env` committé :**
- Chiffré au repos (AES-256-GCM)
- Accès contrôlé par policy
- Audit log de chaque lecture
- Versioning avec rollback

---

## 2. Secrets dynamiques - génération à la demande

Vault se connecte à un système tiers avec un compte admin et crée des
credentials éphémères à chaque demande. Ils expirent automatiquement.

### Database secrets engine

```bash
# Activer l'engine
vault secrets enable database

# Configurer la connexion PostgreSQL
vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://vault_admin:{{password}}@10.0.0.20/appdb" \
  allowed_roles="app-role"

# Créer un rôle avec template SQL
vault write database/roles/app-role \
  db_name=postgresql \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' \
    VALID UNTIL '{{expiration}}'; GRANT SELECT,INSERT,UPDATE ON ALL TABLES \
    IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# Utilisation
vault read database/creds/app-role
# → username: v-root-app-XxXx
# → password: A1b2-...
# → lease_duration: 1h

# Révoquer manuellement
vault lease revoke database/creds/app-role/<lease_id>
```

**Autres backends supportés :** MySQL, MariaDB, MongoDB, Redis, Cassandra,
Elasticsearch, Oracle, MSSQL, InfluxDB.

### SSH secrets engine (OTP mode) - ce qu'on utilise

Vault génère un mot de passe à usage unique pour chaque connexion SSH.
Le workload cible doit avoir `vault-ssh-helper` installé comme module PAM.
Chaque OTP est valide pour une seule connexion SSH - consommé = détruit.

> Commandes de test et démo : voir [04-vault.md](04-vault.md#test-1---ssh-otp)

### SSH secrets engine (Signed Certificates mode) - alternatif

Vault agit comme une CA SSH. Il signe les clés publiques des utilisateurs
avec une durée limitée. Plus besoin de distribuer des `authorized_keys`.

```bash
vault write ssh/sign/dev-role public_key=@~/.ssh/id_ed25519.pub ttl=1h
# → signed_key (valide 1h)
ssh -i signed_key -i ~/.ssh/id_ed25519 ubuntu@10.0.0.20
```

### AWS / Azure / GCP secrets engines

Même principe avec les cloud providers :

```bash
vault read aws/creds/dev-role
# → access_key: AKIAI...
# → secret_key: wJalr...
# → security_token: FQoGZXI...
# → TTL: 1h (puis AWS révoque les credentials IAM)
```

---

## 3. Chiffrement as a Service - Transit Engine

Vault chiffre et déchiffre des données **sans les stocker**. L'application
délègue toute gestion de clés à Vault.

```bash
# Activer l'engine
vault secrets enable transit

# Créer une clé de chiffrement nommée
vault write -f transit/keys/app-key

# Chiffrer
vault write transit/encrypt/app-key \
  plaintext=$(echo -n "FR76 1234 5678" | base64)
# → ciphertext: vault:v1:8SDd3WHDOjf7KAwnmB...

# Déchiffrer
vault write transit/decrypt/app-key \
  ciphertext="vault:v1:8SDd3WHDOjf7KAwnmB..."
# → plaintext: RlI3NiAxMjM0IDU2Nzg=  (base64 → "FR76 1234 5678")

# Rotation de clé (zero downtime)
vault write -f transit/keys/app-key/rotate
# Les anciennes données restent déchiffrables (Vault garde toutes les versions)
# Les nouvelles données utilisent la nouvelle clé automatiquement
```

**Usecase dans notre lab :** l'API sur workload-a chiffre les données sensibles
(IBAN, PII) avant de les stocker dans PostgreSQL. Même avec un dump DB,
les données sont illisibles sans accès à Vault.

**Autres opérations disponibles :**
- `transit/hmac/<key>` - générer/vérifier des HMAC
- `transit/sign/<key>` - signer des données
- `transit/verify/<key>` - vérifier une signature
- `transit/rewrap/<key>` - re-chiffrer avec la nouvelle version de clé sans déchiffrer

---

## 4. Auth Methods - comment on s'authentifie à Vault

Avant d'obtenir quoi que ce soit, il faut prouver son identité à Vault.
Vault supporte de nombreuses méthodes selon le contexte.

| Méthode | Pour qui | Principe |
|---|---|---|
| **Token** | Dev local, scripts bootstrap | Token statique, le plus simple |
| **AppRole** | Apps, services, pipelines CI | roleId (public) + secretId (secret) |
| **LDAP** | Humains via annuaire d'entreprise | Credentials LDAP existants |
| **GitHub** | Développeurs | Token GitHub personnel |
| **Kubernetes** | Pods K8s | Service Account token JWT |
| **AWS IAM** | Instances EC2, Lambda | Signature de requête AWS |
| **GCP** | VMs GCE, Cloud Functions | JWT signé par Google |
| **JWT/OIDC** | SSO enterprise | Token OIDC (Okta, Auth0...) |
| **SPIRE JWT-SVID** | Workloads SPIFFE | JWT-SVID émis par SPIRE |
| **TLS Cert** | Services avec certificat client | Certificat X.509 |

### AppRole - ce qu'on utilise pour les workloads

Chaque workload reçoit un `role_id` (public) et un `secret_id` (secret, injecté
par Ansible) pour s'authentifier auprès de Vault. Le token obtenu est limité
par les policies attachées au rôle.

> Commandes de test et démo : voir [04-vault.md](04-vault.md#approle-authentification-applicative)

---

## 5. Policies - contrôle d'accès

Les policies définissent ce qu'un token authentifié peut faire.
Syntaxe HCL, granularité par chemin.

```hcl
# vault/policies/app-policy.hcl

# Générer un OTP SSH
path "ssh/creds/otp-role" {
  capabilities = ["update"]
}

# Lire des credentials DB
path "database/creds/app-role" {
  capabilities = ["read"]
}

# Chiffrer/déchiffrer via Transit
path "transit/encrypt/app-key" {
  capabilities = ["update"]
}
path "transit/decrypt/app-key" {
  capabilities = ["update"]
}

# Renouveler un lease
path "sys/leases/renew" {
  capabilities = ["update"]
}
```

---

## 6. Lease & Révocation

Tout secret dynamique a un **lease** (bail) avec une durée. Vault peut :

```bash
# Lister les leases actifs
vault list sys/leases/lookup/database/creds/app-role/

# Renouveler avant expiration
vault lease renew database/creds/app-role/<lease_id>

# Révoquer un lease spécifique
vault lease revoke database/creds/app-role/<lease_id>

# Révoquer TOUS les leases d'un rôle (incident de sécurité)
vault lease revoke -prefix database/creds/app-role/
```

La révocation en cascade (`-prefix`) est le "kill switch" : en une commande,
tous les credentials actifs sont invalidés - dans Vault ET dans PostgreSQL.

---

## 7. Audit Log

Vault journalise **toutes les opérations** (lecture, écriture, auth, erreurs).

```bash
vault audit enable file file_path=/var/log/vault/audit.log
```

Chaque entrée contient : timestamp, type, auth (qui), request (quoi), response.
Les secrets ne sont jamais loggués en clair - ils sont hashés (HMAC-SHA256).

Dans notre lab : Prometheus scrape les métriques Vault directement via
`/v1/sys/metrics` (accès non-authentifié activé dans le listener).

---

## Vue d'ensemble dans notre lab

```
┌─────────────────────────────────────────────────────────┐
│                    vault-server                         │
│                                                         │
│  Auth Methods        Secrets Engines     Policies       │
│  ─────────────       ───────────────     ────────       │
│  AppRole             ssh (OTP)           app-policy     │
│  Token               database            admin-policy   │
│                      transit                            │
│                      kv (optionnel)                     │
│                                                         │
│  Audit → /var/log/vault/audit.log → Prometheus          │
└─────────────────────────────────────────────────────────┘
         ↑                    ↑
    workload-a/b          workload-a
    (AppRole login)       (PostgreSQL, Transit encrypt)
```
