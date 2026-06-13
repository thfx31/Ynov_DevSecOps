# Vault — SSH OTP · DB dynamic secrets · Transit · AppRole

## Résultat attendu

- Vault en production mode sur `vault-server` (10.0.0.10)
- SSH OTP fonctionnel sur `workload-a` et `workload-b` via vault-ssh-helper + PAM
- Credentials PostgreSQL dynamiques (TTL 1h) sur `workload-a`
- Chiffrement Transit opérationnel
- workloads authentifiés via AppRole

---

## Architecture

```
laptop
  └── vault CLI (VAULT_ADDR=http://10.0.0.10:8200)
        ├── ssh/creds/otp-role    → OTP valide 1 seule connexion SSH
        ├── database/creds/app-role → username/password TTL 1h dans PostgreSQL
        └── transit/encrypt/app-key → chiffrement de données

vault-server (10.0.0.10)
  ├── Raft storage (/opt/vault/data)
  ├── Auth: AppRole (workload-a, workload-b)
  ├── Secrets: ssh (OTP), database, transit
  └── Policy: app-policy

workload-a (10.0.0.20)
  ├── vault-ssh-helper + PAM  ← valide OTP auprès de Vault
  └── PostgreSQL              ← Vault gère les credentials dynamiquement

workload-b (10.0.0.21)
  └── vault-ssh-helper + PAM
```

---

## Déploiement

```bash
cd ansible
ansible-playbook playbooks/vault.yml -v
```

Le playbook fait, dans l'ordre :

1. **vault-server** :
   - Install Vault via apt HashiCorp
   - Config Raft + TLS désactivé (lab)
   - `vault operator init -key-shares=1 -key-threshold=1` → `/root/vault-init.json`
   - Unseal automatique
   - Active : audit log, approle, ssh, database, transit
   - Crée les rôles AppRole pour workload-a et workload-b

2. **workload-a/b** :
   - Télécharge et installe vault-ssh-helper v0.2.1
   - Configure PAM `/etc/pam.d/sshd` pour déléguer l'auth à Vault
   - Active `KbdInteractiveAuthentication yes` dans sshd
   - (workload-a uniquement) Installe PostgreSQL, crée appdb + vault_admin

---

## Fichiers produits sur les VMs

| Fichier | Où | Contenu |
|---|---|---|
| `/root/vault-init.json` | vault-server | unseal key + root token |
| `/root/vault-approle-credentials.yml` | vault-server | role-id + secret-id des workloads |
| `/etc/vault-ssh-helper.d/config.hcl` | workload-a/b | config vault-ssh-helper |
| `/etc/pam.d/sshd` | workload-a/b | PAM modifié pour OTP |

---

## Procédure de tests

### Prérequis

```bash
# Sur le laptop — à faire dans chaque nouveau terminal
export VAULT_ADDR=http://10.0.0.10:8200
export VAULT_TOKEN=$(ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 \
  'sudo cat /root/vault-init.json' | jq -r .root_token)

# Vérifier que Vault répond
vault status | grep -E "Initialized|Sealed"
# → Initialized: true  /  Sealed: false
```

### Test 1 — SSH OTP

**Ce qu'on démontre :** un ingénieur peut accéder à un serveur de production
sans jamais avoir de clé SSH. Vault génère un mot de passe à usage unique,
valable pour une seule connexion. Même si ce mot de passe est intercepté,
il est déjà détruit après la première utilisation.

**Pourquoi c'est zero-trust :** le credential n'existe pas avant la demande,
n'existe plus après usage. Il n'y a rien à voler, rien à rotater manuellement,
aucun fichier `authorized_keys` à gérer sur les serveurs.

```bash
# 1. Générer un OTP pour workload-a
vault write ssh/creds/otp-role ip=10.0.0.20
# → key: xxxx-xxxx-xxxx-xxxx

# 2. Se connecter avec l'OTP (forcer keyboard-interactive, désactiver pubkey)
ssh -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive \
    ubuntu@10.0.0.20
# Password: [coller l'OTP]
# → Connexion OK ✓

# 3. Retenter avec le MÊME OTP → refusé
ssh -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive \
    ubuntu@10.0.0.20
# → Permission denied ✓  ← credential consommé et détruit
```

**Phrase jury :** "Ce credential n'existe plus — ni dans Vault, ni sur la VM.
Il a été consommé à la première utilisation."

---

### Test 2 — DB dynamic secrets

**Ce qu'on démontre :** une application n'a jamais de mot de passe PostgreSQL
stocké dans un fichier de config, une variable d'environnement ou un secret
Kubernetes. Vault crée un utilisateur dédié à la demande, avec une durée de vie
limitée. À expiration ou sur révocation, Vault supprime l'utilisateur directement
dans PostgreSQL — sans intervention humaine.

**Pourquoi c'est important :** dans un incident de sécurité (dump de config,
fuite de logs), les credentials récupérés sont soit expirés, soit révocables
en une commande. Le rayon d'explosion est borné dans le temps.

```bash
# 1. Générer des credentials PostgreSQL éphémères
vault read database/creds/app-role
# → username: v-root-app-XxXx
# → password: A1b2-...
# → lease_duration: 1h

# 2. Vérifier que l'user existe dans PostgreSQL
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  "psql -U v-root-app-XxXx -d appdb -h localhost -W -c 'SELECT current_user;'"
# → current_user: v-root-app-XxXx ✓

# 3. Révoquer le lease (simulation incident)
vault lease revoke <lease_id>

# 4. Vérifier que l'user n'existe plus dans PostgreSQL
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  "psql -U v-root-app-XxXx -d appdb -h localhost -W -c 'SELECT 1;'"
# → FATAL: password authentication failed ✓
```

**Phrase jury :** "Aucun mot de passe stocké nulle part. Vault génère, Vault
révoque. Un attaquant qui exfiltre la config de l'app n'a rien d'exploitable."

---

### Test 3 — Transit (chiffrement as a service)

**Ce qu'on démontre :** l'application délègue entièrement la gestion des clés
de chiffrement à Vault. Elle ne voit jamais les clés — elle envoie une donnée
sensible à Vault, récupère un ciphertext opaque, et le stocke en base.
Même avec un dump complet de PostgreSQL, les données sont illisibles sans
accès à Vault.

**Usecase concret :** stocker des IBAN, numéros de carte, données de santé
en base de données sans jamais les exposer en clair — conformité RGPD/PCI-DSS
sans gérer une PKI interne.

```bash
# Chiffrer une donnée sensible
CIPHER=$(vault write -field=ciphertext transit/encrypt/app-key \
  plaintext=$(echo -n "IBAN-FR7612345678" | base64))
echo $CIPHER
# → vault:v1:8SDd3WHDOjf7KAwnmB...  ← c'est ce qui est stocké en DB

# Déchiffrer (uniquement par une app autorisée par Vault)
vault write -field=plaintext transit/decrypt/app-key \
  ciphertext="$CIPHER" | base64 -d
# → IBAN-FR7612345678 ✓
```

**Phrase jury :** "Le dump de la base ne sert à rien. La clé ne quitte jamais
Vault. C'est Vault qui chiffre, c'est Vault qui déchiffre — l'application
n'est qu'un intermédiaire."

---

### Test 4 — vault-ssh-helper (vérification config)

**Ce que c'est :** validation que vault-ssh-helper est correctement installé
sur les workloads et peut joindre Vault. Utile en début de démo pour montrer
que l'intégration PAM est en place.

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  '/usr/local/bin/vault-ssh-helper -verify-only -dev \
   -config=/etc/vault-ssh-helper.d/config.hcl'
# → [INFO] vault-ssh-helper verification successful
```

---

## Vérification manuelle

```bash
# 1. Santé Vault
export VAULT_ADDR=http://10.0.0.10:8200
vault status

# 2. Tester SSH OTP
vault write ssh/creds/otp-role ip=10.0.0.20
# → key: xxxx-xxxx-xxxx-xxxx

ssh ubuntu@10.0.0.20
# → Password: [coller l'OTP]
# → Connecté ✓

ssh ubuntu@10.0.0.20
# → Password: [même OTP]
# → Permission denied ← OTP consommé ✓

# 3. Tester DB dynamic secrets
vault read database/creds/app-role
# → username: v-root-app-XxXx
# → password: A1b2-...
# → lease_duration: 1h

# 4. Tester Transit
vault write transit/encrypt/app-key \
  plaintext=$(echo -n "IBAN-FR7612345678" | base64)
# → ciphertext: vault:v1:8SDd3WHDOjf7...

vault write transit/decrypt/app-key \
  ciphertext="vault:v1:8SDd3WHDOjf7..."
# → plaintext: (base64 decode) IBAN-FR7612345678
```

---

## Démo soutenance

### Démo 1 — SSH OTP (90 secondes)

```bash
# Montrer que l'OTP est à usage unique
vault write ssh/creds/otp-role ip=10.0.0.20
# → key: b4e9-3fa1-c721-8d02

ssh ubuntu@10.0.0.20   # password = OTP → OK
ssh ubuntu@10.0.0.20   # même OTP → Permission denied ← MOMENT CLÉ

# Phrase jury :
# "Ce credential n'existe plus — ni dans Vault, ni sur la VM. Consommé."
```

### Démo 2 — DB dynamic secrets (60 secondes)

```bash
vault read database/creds/app-role
# → username: v-root-app-XxXx  TTL: 1h

# Vérifier dans PostgreSQL que l'user existe
ssh ubuntu@10.0.0.20
psql -U v-root-app-XxXx -d appdb -h localhost

# Révoquer
vault lease revoke database/creds/app-role/<lease_id>
# → user supprimé de PostgreSQL

# Phrase jury :
# "Aucun mot de passe stocké nulle part. Vault génère, Vault révoque."
```

---

## Commandes de référence

> Toutes les commandes `vault` requièrent `VAULT_ADDR` et `VAULT_TOKEN` dans l'environnement.  
> `export VAULT_ADDR=http://10.0.0.10:8200`  
> `export VAULT_TOKEN=$(ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 'sudo cat /root/vault-init.json' | jq -r .root_token)`

### État général

```bash
vault status
# Initialized / Sealed / HA — santé globale du cluster

vault secrets list
# Liste les secrets engines montés (ssh/, database/, transit/, kv/)

vault auth list
# Liste les méthodes d'authentification (approle/, token/)

vault audit list
# Vérifie que l'audit log est activé (file://)
```

### SSH OTP

```bash
# Générer un OTP pour une IP donnée
vault write ssh/creds/otp-role ip=10.0.0.20
# → key: XXXX-XXXX-XXXX  (usage unique, TTL 1h)

# Lister les OTPs en cours (pas le secret, juste les leases)
vault list ssh/creds/otp-role
```

### Database dynamic secrets

```bash
# Générer des credentials PostgreSQL éphémères
vault read database/creds/app-role
# → username: v-root-app-XXXX  password: XXXX  lease_duration: 1h  lease_id: database/creds/app-role/XXXX

# Renouveler un lease avant expiration
vault lease renew database/creds/app-role/<lease_id>

# Révoquer immédiatement un credential spécifique
vault lease revoke database/creds/app-role/<lease_id>

# Révoquer TOUS les credentials actifs (urgence sécurité)
vault lease revoke -prefix database/creds/app-role
```

### Transit (chiffrement as a service)

```bash
# Chiffrer une donnée (le plaintext doit être encodé en base64)
vault write transit/encrypt/app-key \
  plaintext=$(echo -n "donnée-sensible" | base64)
# → ciphertext: vault:v1:XXXXXXXX  ← c'est ce qui est stocké en base

# Déchiffrer
vault write -field=plaintext transit/decrypt/app-key \
  ciphertext="vault:v1:XXXXXXXX" | base64 -d
# → donnée-sensible

# Rotation de clé (les anciens ciphertexts restent déchiffrables)
vault write -f transit/keys/app-key/rotate
# → version 2 active, version 1 conservée pour déchiffrement legacy

# Rééchiffrer les anciens ciphertexts avec la nouvelle clé
vault write transit/rewrap/app-key ciphertext="vault:v1:XXXXXXXX"
# → ciphertext: vault:v2:XXXXXXXX
```

### AppRole (authentification applicative)

```bash
# Se connecter avec des credentials AppRole (comme le ferait une app)
vault write auth/approle/login \
  role_id=<role_id> \
  secret_id=<secret_id>
# → token: hvs.XXXX  (utilisable dans VAULT_TOKEN)

# Lire les role_id des workloads (stockés sur vault-server)
cat /root/vault-approle-credentials.yml  # depuis vault-server
```

### Tokens

```bash
# Inspecter le token courant (politiques, TTL, créateur)
vault token lookup

# Inspecter un token spécifique
vault token lookup <token>

# Révoquer un token (et tous ses enfants)
vault token revoke <token>
```

### Audit log

```bash
# Lire les dernières entrées d'audit
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 \
  'sudo tail -20 /var/log/vault/audit.log | jq -r ".request.path,.response.data.username // empty"'
# → chaque opération loguée : qui, quoi, quand, depuis quelle IP
```

---

## Pièges

| Piège | Solution |
|---|---|
| Vault sealed au redémarrage | Unseal scripté dans bootstrap.yml — rejouer le playbook |
| `@include common-auth` commenté casse d'autres auth | `pam_unix optional` en fallback conserve l'auth clé SSH |
| PostgreSQL n'écoute que sur localhost | `listen_addresses = '*'` + pg_hba host rule depuis 10.0.0.10 |
| vault-ssh-helper `-dev` vs `tls_skip_verify` | On utilise `tls_skip_verify = true` dans config.hcl (TLS désactivé sur Vault) |
| Vault init déjà fait → idempotence | `vault status` vérifie `.initialized` avant d'appeler `operator init` |
