# Boundary — Accès humain zero-trust

---

## Pourquoi Boundary — le problème concret

### Sans Boundary (modèle classique)

Un ingénieur doit se connecter à un serveur de production. Il lui faut :

1. **Connaître l'IP** → quelqu'un la lui donne sur Slack, dans un fichier de config, par mail
2. **Avoir une clé SSH** → générée une fois, jamais rotée, parfois partagée entre collègues
3. **Être révoqué individuellement** → si l'ingénieur quitte l'équipe, il faut retirer sa clé de chaque serveur manuellement
4. **Aucun audit centralisé** → qui s'est connecté à quoi, quand, combien de temps ? Inconnu.

```
Ingénieur ──── SSH directe ──────────────────► 10.0.0.20:22
               (connaît l'IP,                  (clé dans authorized_keys,
               a une clé statique)              jamais auditée)
```

### Avec Boundary (zero-trust)

L'ingénieur ne connaît jamais l'IP. Il se connecte à une **target nommée**.
Boundary fait le proxy et enregistre chaque session.

```
Ingénieur ──── boundary connect ──► Boundary (proxy) ──► 10.0.0.20:22
               (authentifié,         (loggue la session,   (IP jamais exposée
               target par nom)        révocation possible)   à l'ingénieur)
```

**Ce que ça change :**

| | Sans Boundary | Avec Boundary |
|---|---|---|
| L'ingénieur connaît l'IP | Oui | Non |
| Révocation d'accès | Retirer la clé sur chaque serveur | Supprimer le compte Boundary |
| Audit des connexions | Aucun (ou logs SSH épars) | Centralisé : qui, quoi, durée |
| Expiration des accès | Jamais (clé statique) | Token Boundary TTL configurable |
| Accès granulaire | Par clé SSH (tout ou rien) | Par target (workload-a uniquement) |

---

## Comment ça fonctionne

### Les composants

**Boundary Controller** (port 9200) : cerveau — gère les identités, les targets, les sessions, l'audit.

**Boundary Worker** (port 9202) : proxy TCP — relaie les connexions entre le client et les cibles. En prod, le worker est dans le réseau privé près des cibles ; le controller est exposé.

**Target** : un serveur accessible via Boundary. Dans notre lab : `workload-a` → `10.0.0.20:22`.

**Session** : une connexion active. Boundary en garde une trace complète même après fermeture.

### Le flux d'une connexion

```
1. boundary authenticate      → Boundary vérifie les credentials → émet un token
2. boundary connect ssh       → Boundary crée une session, ouvre un proxy local (127.0.0.1:PORT_ALÉATOIRE)
3. SSH client                 → se connecte au proxy local
4. Boundary Worker            → relaie vers 10.0.0.20:22
5. Session fermée             → Boundary loggue durée + octets échangés
```

L'ingénieur voit `127.0.0.1:45421` dans sa session SSH — jamais `10.0.0.20`.

---

## Architecture dans notre lab

```
Boundary dev mode — tourne sur le laptop

Ports locaux :
  127.0.0.1:9200  API Controller
  127.0.0.1:9201  Cluster (interne)
  127.0.0.1:9202  Worker proxy

IDs stables en dev mode (hardcodés par Boundary) :
  Auth method : ampw_1234567890
  Org scope   : o_1234567890
  Project     : p_1234567890

Targets créées par le playbook :
  workload-a  ttcp_r39sK8Bfbk  →  10.0.0.20:22
  workload-b  ttcp_xQiUEy3Syl  →  10.0.0.21:22
  (+ targets de démo Boundary auto-créées — ignorables)
```

> **Note :** les IDs de targets (ttcp_...) sont générés aléatoirement à chaque démarrage de boundary dev.
> Après un restart du service, relancer le playbook pour recréer les targets.

---

## Déploiement

```bash
cd ansible
ansible-playbook playbooks/boundary.yml -v -K
```

**Ce que fait le playbook :**

1. Ajoute le repo HashiCorp et installe `boundary` via dnf (Fedora) ou apt (Debian/Ubuntu)
2. Déploie le service systemd `boundary-dev` et le démarre
3. S'authentifie en admin et crée les targets `workload-a` et `workload-b`

---

## Workflow complet — commandes testées

### Étape 1 — Authentification

```bash
BOUNDARY_PASSWORD=password boundary authenticate password \
  -auth-method-id=ampw_1234567890 \
  -login-name=admin \
  -password=env://BOUNDARY_PASSWORD \
  -keyring-type=none
```

Le token est affiché dans le terminal. L'exporter pour la session :

```bash
export BOUNDARY_TOKEN=at_xxxxxxxxxxxx...
```

> **Pourquoi `-keyring-type=none` ?** Boundary essaie de sauvegarder le token dans
> le keyring système (gnome-keyring, kwallet). En terminal sans session graphique,
> ce n'est pas disponible. `-keyring-type=none` évite l'avertissement et confirme
> qu'on gère le token manuellement.

### Étape 2 — Voir les targets disponibles

```bash
boundary targets list \
  -scope-id=p_1234567890 \
  -token env://BOUNDARY_TOKEN
```

Résultat :
```
  ID:    ttcp_r39sK8Bfbk   Type: tcp   Name: workload-a   Address: 10.0.0.20
  ID:    ttcp_xQiUEy3Syl   Type: tcp   Name: workload-b   Address: 10.0.0.21
  ...   (targets de démo Boundary — ignorables)
```

L'ingénieur voit les noms et les IDs — **pas forcément les IPs** (selon les permissions).

### Étape 3 — Connexion SSH via Boundary

```bash
boundary connect ssh \
  -target-id=ttcp_r39sK8Bfbk \
  -token env://BOUNDARY_TOKEN \
  -- -l ubuntu -i ~/.ssh/devsecops
```

Ce qui se passe :
- Boundary crée un proxy local sur un port aléatoire (`127.0.0.1:45421`)
- SSH se connecte à ce proxy
- Le Worker relaie vers `10.0.0.20:22`
- La session est enregistrée dans Boundary

```
The authenticity of host 'ttcp_r39sk8bfbk ([127.0.0.1]:45421)' can't be established.
→ known_hosts voit 127.0.0.1:PORT — jamais l'IP réelle 10.0.0.20
```

### Étape 4 — Inspecter la session (depuis un autre terminal)

```bash
boundary sessions list \
  -scope-id=p_1234567890 \
  -token env://BOUNDARY_TOKEN
```

```bash
# Révoquer une session active
boundary sessions cancel \
  -id=s_XXXX \
  -token env://BOUNDARY_TOKEN
# → La connexion SSH de l'ingénieur est coupée immédiatement
```

---

## Procédure de tests soutenance

### Test 1 — Connexion sans connaître l'IP (90 secondes)

**Ce qu'on démontre :** l'ingénieur n'a pas l'IP du serveur — il a une target
nommée. Boundary intermédie et audite.

**Pourquoi c'est zero-trust :** l'accès est accordé après authentification
auprès du contrôleur. Supprimer le compte Boundary révoque l'accès à toutes
les targets en une action, sans toucher aux serveurs.

```bash
# Montrer les targets (noms, pas les IPs)
boundary targets list -scope-id=p_1234567890 -token env://BOUNDARY_TOKEN

# Se connecter par nom de target
boundary connect ssh \
  -target-id=ttcp_r39sK8Bfbk \
  -token env://BOUNDARY_TOKEN \
  -- -l ubuntu -i ~/.ssh/devsecops

# Dans un autre terminal, voir la session active
boundary sessions list -scope-id=p_1234567890 -token env://BOUNDARY_TOKEN
```

**Phrase jury :** "Je ne connais pas l'IP de ce serveur. Mon accès est une
session Boundary — révocable instantanément depuis le contrôleur, sans
modifier quoi que ce soit sur le serveur."

### Test 2 — Révocation de session (30 secondes)

```bash
# Récupérer l'ID de la session active
SESSION_ID=$(boundary sessions list \
  -scope-id=p_1234567890 \
  -token env://BOUNDARY_TOKEN \
  -format=json | jq -r '.items[0].id')

# Révoquer
boundary sessions cancel -id=$SESSION_ID -token env://BOUNDARY_TOKEN
# → La connexion SSH est coupée côté ingénieur
```

**Phrase jury :** "En incident de sécurité, je révoque ici. Pas de clé à
supprimer sur chaque serveur — un seul point de contrôle."

---

## Commandes de référence

### Authentification

```bash
# S'authentifier (dev mode)
BOUNDARY_PASSWORD=password boundary authenticate password \
  -auth-method-id=ampw_1234567890 \
  -login-name=admin \
  -password=env://BOUNDARY_PASSWORD \
  -keyring-type=none

# Exporter le token pour la session courante
export BOUNDARY_TOKEN=at_xxxx...
```

### Targets

```bash
# Lister les targets
boundary targets list -scope-id=p_1234567890 -token env://BOUNDARY_TOKEN

# Détail d'une target
boundary targets read -id=ttcp_XXXX -token env://BOUNDARY_TOKEN

# Créer une target TCP (SSH sur port 22)
boundary targets create tcp \
  -scope-id=p_1234567890 \
  -name=mon-serveur \
  -address=10.0.0.X \
  -default-port=22 \
  -token env://BOUNDARY_TOKEN

# Supprimer une target (révoque l'accès à ce serveur pour tous)
boundary targets delete -id=ttcp_XXXX -token env://BOUNDARY_TOKEN
```

### Sessions

```bash
# Lister les sessions actives
boundary sessions list -scope-id=p_1234567890 -token env://BOUNDARY_TOKEN

# Détail d'une session
boundary sessions read -id=s_XXXX -token env://BOUNDARY_TOKEN

# Révoquer une session active
boundary sessions cancel -id=s_XXXX -token env://BOUNDARY_TOKEN
```

### Diagnostics

```bash
# Santé de l'API
curl -s http://127.0.0.1:9200/v1/health | jq .

# Logs du service
journalctl -u boundary-dev -n 50 --no-pager

# Vérifier les ports
ss -tlnp | grep -E '9200|9201|9202'
```

---

## Dev mode vs production

| | Dev mode (notre lab) | Production |
|---|---|---|
| Stockage | SQLite en mémoire | PostgreSQL persistant |
| Données au restart | Perdues — relancer le playbook | Conservées |
| Auth | Password (admin/password) | OIDC, LDAP, Vault |
| Credential injection | Non | Clé SSH injectée depuis Vault |
| Session recording | Non | Fichiers chiffrés (S3, MinIO) |
| Workers | Même process que le controller | Séparés, dans le réseau privé |

---

## Pièges et solutions

| Piège | Cause | Solution |
|---|---|---|
| Targets disparues après reboot | Dev mode SQLite en mémoire — données perdues | Relancer `ansible-playbook boundary.yml -K` |
| `Error opening "pass" keyring` | Pas de keyring système en terminal | Ajouter `-keyring-type=none` + exporter `BOUNDARY_TOKEN` |
| `Password flag must be used with env:// or file://` | Boundary 0.13+ interdit les mots de passe en clair | Utiliser `-password=env://BOUNDARY_PASSWORD` |
| `Direct usage of BOUNDARY_TOKEN env var is deprecated` | Boundary 0.14+ | Passer `-token env://BOUNDARY_TOKEN` en flag |
| IDs targets changent au restart | Dev mode regénère les IDs | Utiliser `-target-name` + `-target-scope-id` ou relire les IDs après restart |
