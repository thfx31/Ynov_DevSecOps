# DevSecOps - Plateforme Zero-Trust

Plateforme **zero-trust** sur VMs Linux avec CI/CD et IaC sécurisées.  

 **Objectif** : accès humain via Boundary, secrets dynamiques via Vault, identité workload via SPIRE.
 Le tout provisionné par Terraform + Packer + Ansible, validé par une pipeline GitHub Actions.

## Stack

| Composant | Rôle |
|---|---|
| Packer + QEMU | Image Ubuntu 24.04 durcie CIS L1 |
| Terraform + libvirt | Provisioning 4 VMs KVM |
| Ansible | Configuration des services |
| Vault | SSH OTP - DB dynamic secrets - Transit - AppRole |
| SPIRE/SPIFFE | Identité workload X.509 (SVID), renouvellement automatique |
| Boundary | Accès humain zero-trust (dev mode) |
| GitHub Actions | tflint - checkov - ansible-lint - semgrep - trivy - cosign |
| Prometheus + Grafana | Observabilité unifiée Vault + SPIRE |

## Machines Lab

```
10.0.0.10  vault-server   (2 Go RAM)
10.0.0.11  spire-server   (1 Go RAM)
10.0.0.20  workload-a     (1 Go RAM) - vault-ssh-helper - PostgreSQL - SPIRE Agent
10.0.0.21  workload-b     (1 Go RAM) - vault-ssh-helper - SPIRE Agent
```

## Quick start

```bash
# 1. Build l'image durcie (nécessite KVM)
cd packer && packer build ubuntu-cis.pkr.hcl

# 2. Provisionner les VMs
cd terraform && terraform apply

# 3. Configurer tous les services
cd ansible && ansible-playbook playbooks/site.yml -v

# 4. Démarrer l'observabilité (laptop)
make obs-up   # Prometheus :9090 - Grafana :3000
```

## Opérations courantes

```bash
make infra-up        # Démarrer les VMs après reboot host
make vault-unseal    # Unseal Vault après redémarrage
make obs-up          # Lancer Prometheus + Grafana
make help            # Liste de toutes les commandes
```

## Démos soutenance

```bash
make demo-otp        # Vault SSH OTP - connexion sans clé, rejeu refusé
make demo-db         # Vault DB - credentials PostgreSQL éphémères, révocation live
make demo-transit    # Vault Transit - chiffrement as a service
make demo-boundary   # Boundary - SSH sans connaître l'IP cible
make demo-status     # Etat global Vault
```

## Documentation

| Doc | Contenu |
|---|---|
| [01 - Setup laptop](docs/01-host-setup.md) | Prérequis Fedora, KVM, firewalld, réseau virbr1 |
| [02 - IaC](docs/02-iac.md) | Terraform, Packer, Ansible, architecture réseau |
| [03 - SPIRE](docs/03-spire.md) | SVID, attestation, registration entries, commandes |
| [04 - Vault](docs/04-vault.md) | SSH OTP, DB dynamic secrets, Transit, AppRole |
| [05 - Boundary](docs/05-boundary.md) | Accès zero-trust, workflow complet |
| [06 - CI/CD](docs/06-ci.md) | Pipeline GitHub Actions, choix techniques |
| [07 - Observabilité](docs/07-observabilite.md) | Prometheus + Grafana, métriques, dashboard |
| [08 - Sources](docs/08-sources.md) | Références et bibliographie |
| [09 - Vault référence](docs/09-vault-reference.md) | Guide opérateur complet Vault |
