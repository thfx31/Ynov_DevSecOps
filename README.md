# DevSecOps G04 — Plateforme Zero-Trust

Plateforme zero-trust sur VMs Linux avec CI/CD et IaC sécurisées.  
Sujet Groupe #04
Objectif : Déployer une plateforme zero-trust complète : Boundary pour l'accès humain, Vault pour les secrets dynamiques (SSH OTP, DB), SPIRE pour les identités de workloads. La pipeline GitHub Actions valide l'IaC (tflint, Checkov), applique du SAST (Semgrep), scanne les CVE (Trivy), teste le DAST (ZAP) et signe (Cosign).
Tout provisionné par Terraform + Packer + Ansible.

## Stack

| Composant | Rôle |
|---|---|
| Packer + QEMU | Image Ubuntu 24.04 durcie CIS L1 |
| Terraform + libvirt | Provisioning 4 VMs |
| Ansible | Configuration services (hardening baked dans l'image) |
| Vault | SSH OTP · DB dynamic secrets · Transit · AppRole |
| SPIRE/SPIFFE | Identité workload X.509 (SVID) |
| Boundary | Accès humain zero-trust (dev mode) |
| GitHub Actions | Pipeline CI/CD — tflint, checkov, ansible-lint, semgrep, trivy, cosign |
| Prometheus + Grafana | Observabilité unifiée |

## Architecture réseau

```
10.0.0.10  vault-server   (2 Go RAM)
10.0.0.11  spire-server   (1 Go RAM)
10.0.0.20  workload-a     (1 Go RAM) — vault-ssh-helper + PostgreSQL + SPIRE Agent
10.0.0.21  workload-b     (1 Go RAM) — vault-ssh-helper + SPIRE Agent
```

## Démarrage rapide

```bash
# 1. Build image durcie (nécessite KVM)
cd packer && packer build ubuntu-cis.pkr.hcl

# 2. Provisionner les VMs
cd terraform && terraform apply

# 3. Configurer tous les services
cd ansible && ansible-playbook playbooks/site.yml -v

# 4. Démos rapides
make demo-otp        # Vault SSH OTP
make demo-db         # Vault DB dynamic secrets
make demo-transit    # Vault Transit chiffrement
make demo-boundary   # Connexion SSH via Boundary
```

## Documentation

| Doc | Contenu |
|---|---|
| [Bloc 1 — IaC](docs/bloc-01-iac.md) | Terraform, Packer, Ansible, architecture réseau |
| [Bloc 2 — Vault](docs/bloc-02-vault.md) | SSH OTP, DB dynamic secrets, Transit, AppRole, commandes de référence |
| [Bloc 3 — SPIRE](docs/bloc-03-spire.md) | SVID, attestation, commandes de référence |
| [Bloc 4 — Boundary](docs/bloc-04-boundary.md) | Accès zero-trust, workflow complet, avec vs sans Boundary |
| [Bloc 5 — CI/CD](docs/bloc-05-ci.md) | Pipeline GitHub Actions, choix techniques justifiés |
| [Bloc 6 — Observabilité](docs/bloc-06-observabilite.md) | Prometheus + Grafana |
| [Setup laptop](docs/host-setup.md) | Prérequis Fedora, firewalld, VMs autostart |
| [Vault reference](docs/vault-reference.md) | Référence complète Vault |

## État d'avancement

| Bloc | Contenu | État |
|---|---|---|
| 1 | Terraform + Packer + Ansible (IaC) | ✅ |
| 2 | Vault SSH OTP + DB dynamic secrets + Transit + AppRole | ✅ |
| 3 | SPIRE server + agent + SVIDs | ✅ |
| 4 | Boundary dev mode | ✅ |
| 5 | Pipeline CI GitHub Actions | ✅ |
| 6 | Prometheus + Grafana | 🔲 |

## Démos soutenance

1. **Vault SSH OTP** — connexion sans clé SSH, OTP à usage unique, rejeu refusé
2. **Vault DB dynamic secrets** — credentials PostgreSQL éphémères, révocation live
3. **SPIRE SVID X.509** — identité workload renouvelée automatiquement toutes les 5min
4. **Boundary** — connexion SSH sans connaître l'IP, session révocable instantanément
5. **Dashboard Grafana** — observabilité unifiée Vault + SPIRE + Boundary
