BOUNDARY_ADDR     := http://127.0.0.1:9200
BOUNDARY_AUTH_METHOD := ampw_1234567890
BOUNDARY_PROJECT  := p_1234567890
VAULT_ADDR        := http://10.0.0.10:8200
SSH_KEY           := ~/.ssh/devsecops
VAULT_SERVER      := ubuntu@10.0.0.10
WORKLOAD_A        := ubuntu@10.0.0.20

export BOUNDARY_ADDR
export VAULT_ADDR

vault-token = $(shell ssh -i $(SSH_KEY) $(VAULT_SERVER) \
                'sudo cat /root/vault-init.json' 2>/dev/null | jq -r .root_token)
boundary-token = $(shell BOUNDARY_PASSWORD=password boundary authenticate password \
                   -auth-method-id=$(BOUNDARY_AUTH_METHOD) \
                   -login-name=admin \
                   -password=env://BOUNDARY_PASSWORD \
                   -format=json 2>/dev/null | jq -r '.item.attributes.token // empty')

# ── 1. Packer ────────────────────────────────────────────────────────────────

.PHONY: packer-build packer-clean

packer-build: ## Construire l'image durcie CIS (supprime output/ si existant)
	@rm -rf packer/output
	cd packer && packer init . && packer build ubuntu-cis.pkr.hcl

packer-clean: ## Supprimer l'image Packer (output/)
	rm -rf packer/output

# ── 2. Terraform ─────────────────────────────────────────────────────────────

.PHONY: tf-init tf-plan tf-apply tf-destroy

tf-init: ## Initialiser Terraform (plugins + modules)
	cd terraform && terraform init

tf-plan: ## Prévisualiser les changements Terraform
	cd terraform && terraform plan

tf-apply: ## Créer / mettre à jour les VMs
	cd terraform && terraform apply

tf-destroy: ## Détruire toutes les VMs (irréversible)
	cd terraform && terraform destroy

# ── 3. Ansible ───────────────────────────────────────────────────────────────

.PHONY: ansible-vault ansible-spire ansible-boundary ansible-all

ansible-all: ## Déployer tous les blocs dans l'ordre (-K = sudo localhost)
	cd ansible && ansible-playbook playbooks/site.yml -v -K

ansible-vault: ## Déployer / re-déployer le bloc Vault
	cd ansible && ansible-playbook playbooks/vault.yml -v

ansible-spire: ## Déployer / re-déployer le bloc SPIRE
	cd ansible && ansible-playbook playbooks/spire.yml -v

ansible-boundary: ## Déployer / re-déployer le bloc Boundary (-K = sudo localhost)
	cd ansible && ansible-playbook playbooks/boundary.yml -v -K

# ── 4. Observabilité ─────────────────────────────────────────────────────────

.PHONY: obs-up obs-down obs-status

obs-up: ## Démarrer Prometheus + Grafana (Docker Compose)
	docker compose -f observability/docker-compose.yml up -d
	@echo "Prometheus : http://localhost:9090"
	@echo "Grafana    : http://localhost:3000  (admin/admin)"

obs-down: ## Arrêter Prometheus + Grafana
	docker compose -f observability/docker-compose.yml down

obs-status: ## Etat des conteneurs d'observabilité
	docker compose -f observability/docker-compose.yml ps

# ── 5. Check ─────────────────────────────────────────────────────────────────

.PHONY: check

check: ## Go/no-go rapide : VMs + Vault + SPIRE + Observabilité + Boundary
	@echo ""
	@echo "=== Connectivité VMs ==="
	@for ip in 10.0.0.10 10.0.0.11 10.0.0.20 10.0.0.21; do \
	  printf "  $$ip: "; ping -c1 -W1 $$ip >/dev/null 2>&1 && echo "✓" || echo "✗ KO"; \
	done
	@echo ""
	@echo "=== Vault ==="
	@VAULT_TOKEN=$(call vault-token) VAULT_ADDR=$(VAULT_ADDR) \
	  vault status 2>/dev/null | grep -E "Initialized|Sealed" | sed 's/^/  /' \
	  || echo "  ✗ Vault non joignable"
	@echo ""
	@echo "=== SPIRE agents ==="
	@ssh -i $(SSH_KEY) ubuntu@10.0.0.11 \
	  'sudo /opt/spire/bin/spire-server agent list \
	   -socketPath /tmp/spire-server/private/api.sock 2>/dev/null \
	   | grep -c "SPIFFE ID"' 2>/dev/null \
	  | xargs -I{} echo "  {} agent(s) attesté(s)" \
	  || echo "  ✗ SPIRE non joignable"
	@echo ""
	@echo "=== Observabilité ==="
	@docker compose -f observability/docker-compose.yml ps --format '  {{.Name}}: {{.Status}}' 2>/dev/null \
	  || echo "  ✗ Docker Compose non démarré (make obs-up ?)"
	@echo ""
	@curl -s http://localhost:9090/api/v1/targets 2>/dev/null \
	  | jq -r '.data.activeTargets[] | "  \(.labels.job): \(.health)"' \
	  || echo "  ✗ Prometheus non joignable"
	@echo ""
	@echo "=== Boundary ==="
	@systemctl is-active boundary-dev 2>/dev/null \
	  && echo "  boundary-dev: actif" || echo "  ✗ boundary-dev: inactif"
	@echo ""

# ── Infrastructure ───────────────────────────────────────────────────────────

.PHONY: infra-up infra-down infra-status

infra-up: ## Démarrer les VMs (après reboot host)
	@for vm in vault-server spire-server workload-a workload-b; do \
	  sudo virsh start $$vm 2>/dev/null || true; \
	done
	@echo "Attente démarrage VMs (30s)..."
	@sleep 30
	@for ip in 10.0.0.10 10.0.0.11 10.0.0.20 10.0.0.21; do \
	  printf "  $$ip: "; ping -c1 -W2 $$ip >/dev/null 2>&1 && echo "ok" || echo "KO"; \
	done

infra-down: ## Arrêter les VMs proprement
	@for vm in vault-server spire-server workload-a workload-b; do \
	  sudo virsh shutdown $$vm 2>/dev/null || true; \
	done

infra-status: ## Etat des VMs et connectivité
	@echo "=== VMs ==="
	@sudo virsh list --all
	@echo ""
	@echo "=== Ping ==="
	@for ip in 10.0.0.10 10.0.0.11 10.0.0.20 10.0.0.21; do \
	  printf "  $$ip: "; ping -c1 -W1 $$ip >/dev/null 2>&1 && echo "ok" || echo "KO"; \
	done

# ── Opérations courantes ────────────────────────────────────────────────────

.PHONY: vault-unseal vault-logs spire-status boundary-status boundary-targets

vault-unseal: ## Unseal Vault après un reboot
	$(eval UNSEAL_KEY := $(shell ssh -i $(SSH_KEY) $(VAULT_SERVER) \
	  'sudo cat /root/vault-init.json' | jq -r '.unseal_keys_b64[0]'))
	VAULT_ADDR=$(VAULT_ADDR) vault operator unseal $(UNSEAL_KEY)

vault-logs: ## Tail du log d'audit Vault
	ssh -i $(SSH_KEY) $(VAULT_SERVER) 'sudo tail -f /var/log/vault/audit.log | jq .'

spire-status: ## Etat SPIRE : agents attestés + registration entries
	@echo ""
	@echo "=== SPIRE server ==="
	@ssh -i $(SSH_KEY) ubuntu@10.0.0.11 'sudo systemctl is-active spire-server' \
	  | xargs -I{} echo "  spire-server: {}"
	@echo ""
	@echo "=== Agents attestés ==="
	@ssh -i $(SSH_KEY) ubuntu@10.0.0.11 \
	  'sudo /opt/spire/bin/spire-server agent list \
	   -socketPath /tmp/spire-server/private/api.sock 2>/dev/null' \
	  | grep "SPIFFE ID" | sed 's/^/  /'
	@echo ""
	@echo "=== Registration entries ==="
	@ssh -i $(SSH_KEY) ubuntu@10.0.0.11 \
	  'sudo /opt/spire/bin/spire-server entry show \
	   -socketPath /tmp/spire-server/private/api.sock 2>/dev/null' \
	  | grep "SPIFFE ID\|Selector" | sed 's/^/  /'
	@echo ""
	@echo "=== Agents sur workloads ==="
	@for ip in 10.0.0.20 10.0.0.21; do \
	  printf "  $$ip spire-agent: "; \
	  ssh -i $(SSH_KEY) ubuntu@$$ip 'sudo systemctl is-active spire-agent' 2>/dev/null || echo "KO"; \
	done
	@echo ""

boundary-status: ## Etat du service Boundary et connectivité API
	@echo "=== Service ==="
	@systemctl is-active boundary-dev 2>/dev/null && echo "  boundary-dev: actif" || echo "  boundary-dev: inactif"
	@echo ""
	@echo "=== API ==="
	@curl -sf http://127.0.0.1:9200/v1/health | jq -r '"  status: " + .status' 2>/dev/null \
	  || echo "  API non joignable"

boundary-targets: ## Lister les targets Boundary et leurs IDs
	@BOUNDARY_TOKEN=$(call boundary-token) boundary targets list \
	  -scope-id=$(BOUNDARY_PROJECT) -format=json \
	  | jq -r '.items[] | "  \(.name)\t\(.id)\t\(.address)"'

# ── Démo soutenance ──────────────────────────────────────────────────────────

.PHONY: demo-otp demo-db demo-transit demo-status demo-boundary

demo-otp: ## Génère un OTP SSH pour workload-a
	@echo ""
	@echo "=== Vault SSH OTP ==="
	@echo "Connexion sans clé SSH - mot de passe à usage unique"
	@echo ""
	@VAULT_TOKEN=$(call vault-token) vault write ssh/creds/otp-role ip=10.0.0.20
	@echo ""
	@echo "→ ssh -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive $(WORKLOAD_A)"
	@echo "→ Rejoue le même OTP → Permission denied"

demo-db: ## Génère des credentials PostgreSQL dynamiques
	@echo ""
	@echo "=== Vault DB Dynamic Secrets ==="
	@echo "Credentials éphémères PostgreSQL (TTL 1h)"
	@echo ""
	@VAULT_TOKEN=$(call vault-token) vault read database/creds/app-role
	@echo ""
	@echo "→ Ces credentials n'existent pas dans un fichier de config."
	@echo "→ Vault les révoque automatiquement à expiration."

demo-transit: ## Chiffre et déchiffre un IBAN via Transit engine
	@echo ""
	@echo "=== Vault Transit - Chiffrement as a Service ==="
	@echo ""
	@TOKEN=$(call vault-token); \
	 CIPHER=$$(VAULT_TOKEN=$$TOKEN vault write -field=ciphertext transit/encrypt/app-key \
	   plaintext=$$(echo -n "IBAN-FR7612345678" | base64)); \
	 echo "Plaintext  : IBAN-FR7612345678"; \
	 echo "Ciphertext : $$CIPHER"; \
	 echo ""; \
	 PLAIN=$$(VAULT_TOKEN=$$TOKEN vault write -field=plaintext transit/decrypt/app-key \
	   ciphertext="$$CIPHER" | base64 -d); \
	 echo "Déchiffré  : $$PLAIN"; \
	 echo ""; \
	 echo "→ La clé ne quitte jamais Vault. Le dump DB est illisible sans accès Vault."

demo-status: ## Etat général de la plateforme (Vault + SPIRE + Boundary)
	@echo ""
	@echo "=== Vault ==="
	@VAULT_TOKEN=$(call vault-token) vault status
	@echo ""
	@VAULT_TOKEN=$(call vault-token) vault secrets list
	@echo ""
	@VAULT_TOKEN=$(call vault-token) vault auth list

demo-boundary: ## Connexion SSH via Boundary à workload-a (sans IP directe)
	@echo ""
	@echo "=== Boundary - Accès zero-trust ==="
	@echo "Targets disponibles :"
	@BOUNDARY_TOKEN=$(call boundary-token) boundary targets list \
	  -scope-id=$(BOUNDARY_PROJECT) -format=json \
	  | jq -r '.items[] | "  \(.name) → \(.id)"'
	@echo ""
	@echo "→ Connexion à workload-a via Boundary (l'IP 10.0.0.20 n'est jamais exposée)..."
	@BOUNDARY_TOKEN=$(call boundary-token) boundary connect ssh \
	  -target-name=workload-a \
	  -target-scope-id=$(BOUNDARY_PROJECT) \
	  -- -l ubuntu -i $(SSH_KEY)

# ── Aide ─────────────────────────────────────────────────────────────────────

.DEFAULT_GOAL := help

help: ## Afficher cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
