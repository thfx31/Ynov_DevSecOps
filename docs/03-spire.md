# SPIRE - Identité workload X.509

---

## Concepts fondamentaux

### SPIFFE - le standard

**SPIFFE** (Secure Production Identity Framework For Everyone) est un standard
ouvert qui définit comment les workloads s'identifient entre eux dans une
infrastructure zero-trust. Il spécifie :
- Le format des identités : les **SPIFFE IDs** (`spiffe://trust-domain/path`)
- Le format des documents d'identité : les **SVIDs**
- Le protocole de distribution : la **Workload API**

SPIFFE est le standard. SPIRE est l'implémentation de référence.

---

### SVID - ce que c'est, ce que ça signifie

**SVID** = **SPIFFE Verifiable Identity Document**

Un SVID est un document cryptographique qui prouve l'identité d'un workload.
Il existe en deux formes :

| Type | Format | Contenu |
|---|---|---|
| **X.509-SVID** | Certificat X.509 | clé privée + certificat signé par la CA SPIRE |
| **JWT-SVID** | JSON Web Token | token signé, audience limitée, TTL court |

Dans notre lab, on utilise des **X.509-SVIDs**.

Un SVID X.509 contient :
- Le **SPIFFE ID** dans le champ `Subject Alternative Name` (SAN) du certificat
  ex : `spiffe://example.org/workload/app-a`
- Une **date d'expiration** (TTL = 5 minutes dans notre lab)
- Une **signature** de la CA du SPIRE Server

Le SPIRE Agent **renouvelle automatiquement** le SVID avant expiration - sans
intervention humaine, sans redémarrage du workload.

**Solution zero-trust :**
Un workload ne déclare pas son identité, il la prouve avec un certificat cryptographique.
Aucun secret partagé, aucun token statique. L'identité est liée à CE QUE le workload est (binaire, UID, namespace), pas à comment on l'a configuré.

---

### Architecture SPIRE

```
spire-server (10.0.0.11)                workload-a (10.0.0.20)
┌─────────────────────────┐             ┌────────────────────────────┐
│  SPIRE Server           │             │  SPIRE Agent               │
│  ─────────────          │  port 8081  │  ──────────────            │
│  CA (KeyManager disk)   │◄────────────│  Atteste auprès du server  │
│  SQLite datastore       │             │  Obtient son SVID agent    │
│  Registration entries   │             │  Expose Workload API       │
│                         │             │  (socket Unix)             │
│  spiffe://example.org/  │             │                            │
│    node/workload-a  ────┼─────────────►  /tmp/spire-agent/         │
│    workload/app-a       │             │    public/api.sock         │
└─────────────────────────┘             │         │                  │
                                        │         ▼                  │
                                        │  Process ubuntu (UID 1000) │
                                        │  → fetch X.509-SVID        │
                                        │  → spiffe://.../app-a      │
                                        └────────────────────────────┘
```

---

### Attestation - comment ça fonctionne

**Etape 1 - Node attestation (agent → server)**

L'agent prouve qu'il tourne sur un nœud autorisé. Dans notre lab : join_token.
- Le server génère un token unique par agent
- L'agent le présente au server lors du premier démarrage
- Le server vérifie le token, émet un **agent SVID** :
  `spiffe://example.org/node/workload-a`
- Le token est consommé (usage unique)

En production : on utiliserait AWS IID, GCP GCE, TPM attestation, ou x509pop
au lieu du join_token - le principe est le même.

**Etape 2 - Workload attestation (workload → agent)**

Un process local appelle la Workload API (socket Unix). L'agent l'identifie
via le WorkloadAttestor `unix` : UID, GID, chemin du binaire.

Le server a une **registration entry** qui dit :
> "Sur le nœud `spiffe://.../node/workload-a`, tout process avec UID 1000
> peut obtenir le SVID `spiffe://.../workload/app-a`"

L'agent vérifie que le process correspond, récupère le SVID auprès du server,
et le délivre au workload.

**Etape 3 - Renouvellement automatique**

Avant expiration du SVID (TTL = 5min), l'agent en demande un nouveau au server.
Le workload reçoit le nouveau SVID via la Workload API sans interruption.

---

## Architecture dans notre lab

```
trust domain : example.org

Node SVIDs (agents) :
  spiffe://example.org/node/workload-a  → SPIRE Agent sur workload-a
  spiffe://example.org/node/workload-b  → SPIRE Agent sur workload-b

Workload SVIDs :
  spiffe://example.org/workload/app-a   → process ubuntu (UID 1000) sur workload-a
  spiffe://example.org/workload/app-b   → process ubuntu (UID 1000) sur workload-b
```

---

## Déploiement

```bash
cd ansible
ansible-playbook playbooks/spire.yml -v
```

**Ce que fait le playbook :**

Play 1 - SPIRE Server (spire-server) :
1. Télécharge et installe SPIRE
2. Déploie `server.conf` (SQLite, join_token, KeyManager disk)
3. Démarre le service systemd
4. Exporte le trust bundle `/tmp/spire-bundle.crt` sur le contrôleur Ansible
5. Crée les registration entries pour workload-a et workload-b

Play 2 - SPIRE Agents (workload-a, workload-b) :
1. Installe le binaire spire-agent
2. Copie le trust bundle depuis le contrôleur
3. Génère un join token
4. Démarre l'agent : attestation automatique
5. Attend que la socket Workload API soit disponible

---

## Procédure de tests

### Prérequis

```bash
# Vérifier que les services tournent
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.11 'sudo systemctl status spire-server --no-pager'
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 'sudo systemctl status spire-agent --no-pager'
```

### Test 1 - Fetch d'un X.509-SVID

**Ce qu'on démontre :** un process peut récupérer son certificat d'identité
cryptographique en interrogeant la socket locale. Aucun secret à gérer,  le
SPIRE Agent sait qui est ce process grâce à l'attestation unix.

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  '/opt/spire/bin/spire-agent api fetch x509 \
   -socketPath /tmp/spire-agent/public/api.sock'
```

Résultat attendu :
```
Received 1 svid after 12.462µs

SPIFFE ID:              spiffe://example.org/workload/app-a
SVID Valid After:       2026-06-13 10:00:00 +0000 UTC
SVID Valid Until:       2026-06-13 10:05:00 +0000 UTC   ← TTL 5 minutes
CA #1 Valid After:      2026-06-13 09:00:00 +0000 UTC
CA #1 Valid Until:      2026-06-14 09:00:00 +0000 UTC
```

Ce process a une identité cryptographique. Pas un token
partagé mais un certificat lié à ce qu'il est. Il expire dans 5 minutes et sera
renouvelé automatiquement.

### Test 2 - Renouvellement automatique

```bash
# Lancer en boucle : on voit le SVID se renouveler automatiquement
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  'watch -n30 "/opt/spire/bin/spire-agent api fetch x509 \
   -socketPath /tmp/spire-agent/public/api.sock 2>&1 | grep -E \"SPIFFE|Until\""'
```

### Test 3 - Vérification des entries côté server

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.11 \
  'sudo /opt/spire/bin/spire-server entry show \
   -socketPath /tmp/spire-server/private/api.sock'
```

### Test 4 - Agents attestés

```bash
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.11 \
  'sudo /opt/spire/bin/spire-server agent list \
   -socketPath /tmp/spire-server/private/api.sock'
```

---

## Commandes de référence

> Toutes les commandes server se font en `sudo` depuis `spire-server` (10.0.0.11).  
> Toutes les commandes agent se font depuis `workload-a` (10.0.0.20) ou `workload-b` (10.0.0.21).

### SPIRE Server

```bash
# Vérifier que le server tourne
sudo /opt/spire/bin/spire-server healthcheck \
  -socketPath /tmp/spire-server/private/api.sock
# → Server is healthy.

# Lister tous les agents attestés (et leur SVID agent)
sudo /opt/spire/bin/spire-server agent list \
  -socketPath /tmp/spire-server/private/api.sock
# → SPIFFE ID: spiffe://example.org/node/workload-a
# → Attestation type: join_token
# → Expiration time: 2026-06-14 ...

# Afficher toutes les registration entries
sudo /opt/spire/bin/spire-server entry show \
  -socketPath /tmp/spire-server/private/api.sock
# → SPIFFE ID, Parent ID, Selector, TTL pour chaque entry

# Filtrer les entries d'un workload précis
sudo /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://example.org/workload/app-a \
  -socketPath /tmp/spire-server/private/api.sock

# Créer une registration entry (si absente)
sudo /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://example.org/workload/app-a \
  -parentID spiffe://example.org/node/workload-a \
  -selector unix:uid:1000 \
  -socketPath /tmp/spire-server/private/api.sock
# parentID = SVID de l'agent du nœud  /  selector = critère d'identité du process

# Supprimer une entry par son ID
sudo /opt/spire/bin/spire-server entry delete \
  -entryID <entry-id> \
  -socketPath /tmp/spire-server/private/api.sock

# Afficher le trust bundle (CA X.509 du trust domain)
sudo /opt/spire/bin/spire-server bundle show \
  -socketPath /tmp/spire-server/private/api.sock
# → Certificat PEM - distribué aux agents pour valider les SVIDs

# Générer un join token pour un nouvel agent
sudo /opt/spire/bin/spire-server token generate \
  -spiffeID spiffe://example.org/node/workload-a \
  -socketPath /tmp/spire-server/private/api.sock
# → Token: XXXX  (usage unique, TTL 1h)
# Ce token est consommé à la première attestation de l'agent
```

### SPIRE Agent

```bash
# Vérifier que l'agent tourne
/opt/spire/bin/spire-agent healthcheck \
  -socketPath /tmp/spire-agent/public/api.sock
# → Agent is healthy.

# Récupérer le X.509-SVID du process courant
/opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /tmp/spire-agent/public/api.sock
# → SPIFFE ID: spiffe://example.org/workload/app-a
# → SVID Valid Until: ... (TTL 5min dans notre lab)
# → CA #1 Valid Until: ... (TTL 24h)

# Récupérer et écrire le SVID sur disque (pour une app qui lit des fichiers)
/opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /tmp/spire-agent/public/api.sock \
  -write /tmp/svid/
# → svid.0.pem (cert) + svid.0.key (clé privée) + bundle.0.pem (CA)

# Observer le renouvellement automatique (toutes les ~4min)
watch -n 30 '/opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /tmp/spire-agent/public/api.sock 2>&1 | grep -E "SPIFFE|Until"'

```

### Diagnostics

```bash
# Logs SPIRE Server (chercher les erreurs d'attestation)
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.11 \
  'sudo journalctl -u spire-server -n 50 --no-pager'

# Logs SPIRE Agent (chercher "no identity issued" ou "peer validation failed")
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20 \
  'sudo journalctl -u spire-agent -n 50 --no-pager'

# Vérifier quel UID tourne le process qui appelle la Workload API
id ubuntu
# → uid=1000 - doit correspondre au selector unix:uid:1000 de la registration entry
```

---

## Troubleshooting

| Piège | Cause | Solution |
|---|---|---|
| Agent ne démarre pas | Join token expiré (TTL 1h) | Rejouer `ansible-playbook spire.yml` - régénère un token |
| Socket non créée | Service pas encore prêt | `wait_for` dans Ansible attend jusqu'à 30s |
| `entry show` retourne vide | Entry pas encore créée | La tâche de création est idempotente |
| SVID non distribué | UID du process ne correspond pas au selector | Vérifier que l'user est bien UID 1000 : `id ubuntu` |
| KeyManager disk vs memory | Memory → CA perdue au restart → SVIDs invalides | On utilise disk pour le server, memory pour les agents |
| join_token consommé au restart | Token usage unique | Après premier démarrage, l'agent utilise son SVID stocké en data_dir - le token est ignoré |
