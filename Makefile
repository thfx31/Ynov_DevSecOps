BOUNDARY_ADDR := http://127.0.0.1:9200
BOUNDARY_AUTH_METHOD := ampw_1234567890
BOUNDARY_PROJECT  := p_1234567890

BOUNDARY_TOKEN := $(shell BOUNDARY_PASSWORD=password boundary authenticate password \
                    -auth-method-id=$(BOUNDARY_AUTH_METHOD) \
                    -login-name=admin \
                    -password=env://BOUNDARY_PASSWORD \
                    -format=json 2>/dev/null | jq -r '.item.attributes.token // empty')

export BOUNDARY_ADDR
export BOUNDARY_TOKEN

VAULT_ADDR   := http://10.0.0.10:8200
SSH_KEY      := ~/.ssh/devsecops
VAULT_SERVER := ubuntu@10.0.0.10
WORKLOAD_A   := ubuntu@10.0.0.20

VAULT_TOKEN  := $(shell ssh -i $(SSH_KEY) $(VAULT_SERVER) \
                  'sudo cat /root/vault-init.json' 2>/dev/null | jq -r .root_token)

export VAULT_ADDR
export VAULT_TOKEN

# ── Démo soutenance ───────────────────────────────────────────────────────────

.PHONY: demo-otp demo-db demo-transit demo-status

demo-otp: ## Génère un OTP SSH pour workload-a
	@echo ""
	@echo "=== Vault SSH OTP ==="
	@echo "Connexion sans clé SSH — mot de passe à usage unique"
	@echo ""
	vault write ssh/creds/otp-role ip=10.0.0.20
	@echo ""
	@echo "→ Connecte-toi avec : ssh -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive $(WORKLOAD_A)"
	@echo "→ Rejoue le même OTP : Permission denied"

demo-db: ## Génère des credentials PostgreSQL dynamiques
	@echo ""
	@echo "=== Vault DB Dynamic Secrets ==="
	@echo "Credentials éphémères PostgreSQL (TTL 1h)"
	@echo ""
	vault read database/creds/app-role
	@echo ""
	@echo "→ Ces credentials n'existent pas dans un fichier de config."
	@echo "→ Vault les révoque automatiquement à expiration."

demo-transit: ## Chiffre et déchiffre un IBAN via Transit engine
	@echo ""
	@echo "=== Vault Transit — Chiffrement as a Service ==="
	@echo ""
	$(eval CIPHER := $(shell vault write -field=ciphertext transit/encrypt/app-key \
	  plaintext=$$(echo -n "IBAN-FR7612345678" | base64)))
	@echo "Plaintext  : IBAN-FR7612345678"
	@echo "Ciphertext : $(CIPHER)"
	@echo ""
	$(eval PLAIN := $(shell vault write -field=plaintext transit/decrypt/app-key \
	  ciphertext="$(CIPHER)" | base64 -d))
	@echo "Déchiffré  : $(PLAIN)"
	@echo ""
	@echo "→ La clé ne quitte jamais Vault. Le dump DB est illisible sans accès Vault."

demo-status: ## État général de la plateforme Vault
	@echo ""
	@echo "=== Vault Status ==="
	vault status
	@echo ""
	@echo "=== Engines actifs ==="
	vault secrets list
	@echo ""
	@echo "=== Auth methods ==="
	vault auth list

# ── Opérations courantes ──────────────────────────────────────────────────────

.PHONY: vault-unseal vault-logs

vault-unseal: ## Unseal Vault après un reboot
	$(eval UNSEAL_KEY := $(shell ssh -i $(SSH_KEY) $(VAULT_SERVER) \
	  'sudo cat /root/vault-init.json' | jq -r '.unseal_keys_b64[0]'))
	VAULT_ADDR=$(VAULT_ADDR) vault operator unseal $(UNSEAL_KEY)

vault-logs: ## Tail du log d'audit Vault
	ssh -i $(SSH_KEY) $(VAULT_SERVER) 'sudo tail -f /var/log/vault/audit.log | jq .'

# ── Infrastructure ────────────────────────────────────────────────────────────

.PHONY: infra-up infra-down infra-status

infra-up: ## Démarrer les VMs (après reboot host)
	for vm in vault-server spire-server workload-a workload-b; do \
	  sudo virsh start $$vm 2>/dev/null || true; \
	done
	@echo "Attente démarrage VMs..."
	@sleep 20
	@for ip in 10.0.0.10 10.0.0.11 10.0.0.20 10.0.0.21; do \
	  printf "$$ip: "; ping -c1 -W2 $$ip >/dev/null 2>&1 && echo "ok" || echo "KO"; \
	done

infra-down: ## Arrêter les VMs proprement
	for vm in vault-server spire-server workload-a workload-b; do \
	  sudo virsh shutdown $$vm 2>/dev/null || true; \
	done

infra-status: ## État des VMs et connectivité
	@echo "=== VMs ==="
	@sudo virsh list --all
	@echo ""
	@echo "=== Ping ==="
	@for ip in 10.0.0.10 10.0.0.11 10.0.0.20 10.0.0.21; do \
	  printf "$$ip: "; ping -c1 -W1 $$ip >/dev/null 2>&1 && echo "ok" || echo "KO"; \
	done

# ── Boundary ─────────────────────────────────────────────────────────────────

.PHONY: demo-boundary boundary-status boundary-targets

demo-boundary: ## Connexion SSH via Boundary à workload-a (sans IP directe)
	@echo ""
	@echo "=== Boundary — Accès zero-trust ==="
	@echo "Targets disponibles :"
	@boundary targets list -scope-id=$(BOUNDARY_PROJECT) -format=json \
	  | jq -r '.items[] | "  \(.name) (port \(.default_port // "22")) → \(.id)"'
	@echo ""
	@echo "→ Connexion à workload-a via Boundary (l'IP 10.0.0.20 n'est jamais exposée)..."
	boundary connect ssh \
	  -target-name=workload-a \
	  -target-scope-id=$(BOUNDARY_PROJECT) \
	  -- -l ubuntu -i $(SSH_KEY)

boundary-targets: ## Lister les targets Boundary et leurs IDs
	@boundary targets list -scope-id=$(BOUNDARY_PROJECT) -format=json \
	  | jq -r '.items[] | "  \(.name)\t\(.id)\t\(.address)"'

boundary-status: ## État du service Boundary et connectivité API
	@echo "=== Service ==="
	@systemctl is-active boundary-dev && echo "boundary-dev: actif" || echo "boundary-dev: inactif"
	@echo ""
	@echo "=== API ==="
	@curl -sf http://127.0.0.1:9200/v1/health | jq -r '"status: " + .status' 2>/dev/null || echo "API non joignable"

# ── Ansible ───────────────────────────────────────────────────────────────────

.PHONY: deploy-vault deploy-all

deploy-vault: ## Déployer / re-déployer le bloc Vault
	cd ansible && ansible-playbook playbooks/vault.yml -v

deploy-all: ## Déployer tous les blocs (site.yml)
	cd ansible && ansible-playbook playbooks/site.yml -v

# ── Aide ──────────────────────────────────────────────────────────────────────

.DEFAULT_GOAL := help

help: ## Afficher cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
