# Protocole de test — Validation complète de la plateforme

> À exécuter dans l'ordre après un déploiement from scratch.
> Chaque section indique la commande, le résultat attendu et le critère go/no-go (✅ / ❌).

---

## 0. Prérequis

```bash
# Venv Ansible actif
source ~/.virtualenvs/ansible/bin/activate

# Variables d'environnement Vault
export VAULT_ADDR=http://10.0.0.10:8200
export VAULT_TOKEN=$(ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 \
  'sudo cat /root/vault-init.json' | jq -r .root_token)
```

---

## 1. Infrastructure — VMs et connectivité

### 1.1 VMs démarrées

```bash
for vm in vault-server spire-server workload-a workload-b; do
  echo -n "$vm: "; sudo virsh domstate $vm
done
```

✅ `running` pour les 4 VMs

### 1.2 Connectivité réseau

```bash
for ip in 10.0.0.10 10.0.0.11 10.0.0.20 10.0.0.21; do
  echo -n "$ip: "; ping -c1 -W1 $ip &>/dev/null && echo "ok" || echo "KO"
done
```

✅ 4x `ok`

### 1.3 SSH sur les 4 VMs

```bash
for ip in 10.0.0.10 10.0.0.11 10.0.0.20 10.0.0.21; do
  echo -n "$ip: "; ssh -i ~/.ssh/devsecops -o ConnectTimeout=3 ubuntu@$ip 'echo ok' 2>/dev/null || echo "KO"
done
```

✅ 4x `ok`

### 1.4 Hardening CIS

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 'sudo auditctl -s | grep "enabled 2"'
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 'sudo sshd -T | grep "passwordauthentication no"'
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 'mount | grep "/tmp"'
```

✅ `enabled 2` (auditd immutable), `passwordauthentication no`, `/tmp` avec `noexec`

---

## 2. Vault

### 2.1 Statut Vault

```bash
vault status | grep -E "Initialized|Sealed|HA Enabled"
```

✅ `Initialized: true`, `Sealed: false`, `HA Enabled: false`

### 2.2 Secrets engines montés

```bash
vault secrets list | grep -E "ssh|database|transit"
```

✅ `ssh/`, `database/`, `transit/` présents

### 2.3 AppRole auth

```bash
vault auth list | grep approle
```

✅ `approle/`

### 2.4 Audit log actif

```bash
vault audit list
```

✅ `file/` avec `file_path=/var/log/vault/audit.log`

### 2.5 Test SSH OTP — workload-a

```bash
OTP=$(vault write -field=key ssh/creds/otp-role ip=10.0.0.20)
echo "OTP généré : $OTP"

# Connexion avec l'OTP (attend un mot de passe)
ssh -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive \
    ubuntu@10.0.0.20 'echo "connexion ok"'
# Saisir $OTP au prompt
```

✅ Connexion réussie au premier usage

```bash
# Rejouer le même OTP
ssh -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive \
    ubuntu@10.0.0.20 'echo ok'
```

✅ `Permission denied` — OTP consommé et détruit

### 2.6 Test SSH OTP — workload-b

```bash
vault write -field=key ssh/creds/otp-role ip=10.0.0.21
```

✅ OTP généré, même procédure

### 2.7 Test DB dynamic secrets

```bash
vault read database/creds/app-role
```

✅ `username: v-root-app-XXXX`, `lease_duration: 1h`

```bash
# Vérifier que l'user existe dans PostgreSQL
LEASE=$(vault read -format=json database/creds/app-role)
USER=$(echo $LEASE | jq -r .data.username)
PASS=$(echo $LEASE | jq -r .data.password)
LEASE_ID=$(echo $LEASE | jq -r .lease_id)

ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  "PGPASSWORD='$PASS' psql -U $USER -d appdb -h localhost -c 'SELECT current_user;'"
```

✅ `current_user: v-root-app-XXXX`

```bash
# Révoquer et vérifier la suppression
vault lease revoke $LEASE_ID

ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  "PGPASSWORD='$PASS' psql -U $USER -d appdb -h localhost -c 'SELECT 1;'" 2>&1 | grep "authentication failed"
```

✅ `FATAL: password authentication failed` — credential révoqué

### 2.8 Test Transit

```bash
CIPHER=$(vault write -field=ciphertext transit/encrypt/app-key \
  plaintext=$(echo -n "IBAN-FR7612345678" | base64))
echo "Ciphertext : $CIPHER"

vault write -field=plaintext transit/decrypt/app-key \
  ciphertext="$CIPHER" | base64 -d
```

✅ `IBAN-FR7612345678` après déchiffrement

### 2.9 AppRole credentials workloads

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 'sudo cat /root/vault-approle-credentials.yml'
```

✅ Fichier présent avec `role_id` et `secret_id` pour workload-a et workload-b

---

## 3. SPIRE

### 3.1 SPIRE server actif

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.11 'sudo systemctl is-active spire-server'
```

✅ `active`

### 3.2 SPIRE agents attestés

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.11 \
  'sudo /opt/spire/bin/spire-server agent list -socketPath /tmp/spire-server/private/api.sock'
```

✅ 2 agents listés : `spiffe://devsecops.lab/node/workload-a` et `spiffe://devsecops.lab/node/workload-b`

### 3.3 SPIRE agents actifs sur les workloads

```bash
for ip in 10.0.0.20 10.0.0.21; do
  echo -n "$ip spire-agent: "
  ssh -i ~/.ssh/devsecops ubuntu@$ip 'sudo systemctl is-active spire-agent'
done
```

✅ `active` sur les 2 workloads

### 3.4 Registration entries

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.11 \
  'sudo /opt/spire/bin/spire-server entry show -socketPath /tmp/spire-server/private/api.sock'
```

✅ 2 entries : `spiffe://devsecops.lab/app-a` et `spiffe://devsecops.lab/app-b`

### 3.5 SVID valide sur un workload

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  '/opt/spire/bin/spire-agent api fetch x509 -socketPath /tmp/spire-agent/public/api.sock 2>&1 | head -5'
```

✅ `Received 1 svid` avec `spiffe://devsecops.lab/workload/app-a`

### 3.6 Métriques SPIRE accessibles

```bash
curl -s http://10.0.0.11:8088/metrics | grep "^spire_server_rpc" | head -3
curl -s http://10.0.0.20:8088/metrics | grep "^spire_agent" | head -3
curl -s http://10.0.0.21:8088/metrics | grep "^spire_agent" | head -3
```

✅ Métriques retournées (pas de `Connection refused`)

---

## 4. Boundary

### 4.1 Service Boundary actif

```bash
sudo systemctl is-active boundary-dev
```

✅ `active`

### 4.2 Targets disponibles

```bash
export BOUNDARY_TOKEN=$(BOUNDARY_PASSWORD=password boundary authenticate password \
  -auth-method-id=ampw_1234567890 \
  -login-name=admin \
  -password=env://BOUNDARY_PASSWORD \
  -format=json | jq -r .item.attributes.token)

boundary targets list -scope-id=p_1234567890 -token env://BOUNDARY_TOKEN
```

✅ 2 targets : `workload-a` et `workload-b`

### 4.3 Connexion SSH via Boundary

```bash
boundary connect ssh \
  -target-name=workload-a \
  -target-scope-id=p_1234567890 \
  -token env://BOUNDARY_TOKEN \
  -- -l ubuntu -i ~/.ssh/devsecops
```

✅ Connexion SSH établie via le tunnel Boundary

---

## 5. Observabilité

### 5.1 Prometheus et Grafana démarrés

```bash
cd observability && docker compose ps
```

✅ `prometheus` et `grafana` en `running`

### 5.2 Tous les targets Prometheus UP

```bash
curl -s http://localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
```

✅ `"health": "up"` pour `vault`, `spire-server`, `spire-agent` (x2)

### 5.3 Métriques Vault disponibles

```bash
curl -s http://localhost:9090/api/v1/query?query=vault_core_active | \
  jq '.data.result[0].value[1]'
```

✅ `"1"` (Vault actif)

### 5.4 Dashboard Grafana accessible

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000
```

✅ `200`

---

## 6. CI GitHub Actions

### 6.1 Dernière run verte

```bash
gh run list --limit 5 --repo $(git remote get-url origin | sed 's/.*github.com[:/]//' | sed 's/.git$//')
```

✅ Dernière run : `✓ completed / success`

### 6.2 Tous les jobs passent

```bash
gh run view $(gh run list --limit 1 --json databaseId -q '.[0].databaseId') \
  --json jobs -q '.jobs[] | {name: .name, conclusion: .conclusion}'
```

✅ `"conclusion": "success"` pour tous les jobs (terraform-lint, checkov, ansible-lint, semgrep, trivy, cosign, zap)

---

## 7. Résumé go/no-go démo

| Bloc | Test clé | Critère |
|---|---|---|
| Infrastructure | SSH sur les 4 VMs | 4x `ok` |
| Vault SSH OTP | OTP usage unique | 1ère connexion OK, 2ème refusée |
| Vault DB secrets | Génération + révocation | User PostgreSQL supprimé après revoke |
| Vault Transit | Chiffrer/déchiffrer | IBAN récupéré intact |
| SPIRE | Agents attestés | 2 agents listés + SVIDs valides |
| Boundary | Tunnel SSH | Connexion via `boundary connect ssh` |
| Prometheus | Targets health | 4x `up` |
| Grafana | Dashboard | Panels avec données |
| CI | Dernière run | Tous jobs verts |

> Si un critère ❌ : rejouer le playbook Ansible correspondant avant la démo.
> `make vault-unseal` si Vault sealed après reboot.
