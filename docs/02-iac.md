# IaC - Packer + Terraform + Ansible

## Résultat

4 VMs Ubuntu 24.04 CIS L1 opérationnelles sur KVM/libvirt :

| VM | IP | RAM | Rôle |
|---|---|---|---|
| vault-server | 10.0.0.10 | 2 Go | Vault, PKI |
| spire-server | 10.0.0.11 | 1 Go | SPIRE Server |
| workload-a | 10.0.0.20 | 1 Go | SPIRE Agent, app API, PostgreSQL |
| workload-b | 10.0.0.21 | 1 Go | SPIRE Agent, app client |

---

## Packer - Image de base durcie

**Fichier :** `packer/ubuntu-cis.pkr.hcl`

Source : Ubuntu Noble cloud image (`noble-server-cloudimg-amd64.img`)

Le script `packer/scripts/cis-hardening.sh` applique CIS Ubuntu 24.04 L1 :

| Contrôle | Implémentation |
|---|---|
| Modules noyau blacklistés | `/etc/modprobe.d/cis-blacklist.conf` |
| SSH hardening | `PermitRootLogin no`, `PasswordAuthentication no`, `AllowTcpForwarding no` |
| auditd | Règles CIS + mode immutable (`-e 2`) |
| UFW | `deny incoming`, `allow SSH` |
| `/tmp` | tmpfs `nosuid,nodev,noexec` |
| Root | Compte verrouillé (`passwd -l root`) |
| PAM / pwquality | minlen=14, complexité imposée |

**Build :**
```bash
cd packer
packer init .
packer build ubuntu-cis.pkr.hcl
# → output/ubuntu-cis-hardened.qcow2
```

---

## Terraform - Provisioning VMs

**Provider :** `dmacvicar/libvirt` **v0.7.6**

**Structure :**
```
terraform/
├── main.tf               - pool, réseau, 4 modules VM
├── variables.tf          - variables (libvirt_uri, base_image_path, ssh_public_key…)
├── outputs.tf            - IPs des VMs
├── terraform.tfvars      - valeurs locales (gitignored)
├── .tflint.hcl           - config lint CI
└── modules/
    ├── network/
    │   ├── main.tf       - libvirt_network NAT (10.0.0.0/24)
    │   ├── variables.tf
    │   └── outputs.tf
    └── vm/
        ├── main.tf       - libvirt_volume + libvirt_cloudinit_disk + libvirt_domain
        ├── variables.tf
        ├── outputs.tf
        └── templates/
            ├── cloud_init.tpl      - user-data (clé SSH, packages)
            ├── network_config.tpl  - netplan IP statique
            └── meta_data.tpl       - instance-id cloud-init
```

**Premier lancement (une fois) :** créer `terraform/terraform.tfvars` :
```bash
echo "ssh_public_key = \"$(cat ~/.ssh/devsecops.pub)\"" > terraform/terraform.tfvars
```

**Apply :**
```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Les IPs fixes sont assignées via cloud-init : `main.tf` passe l'IP de chaque VM au template `network_config.tpl` qui génère un `netplan` statique au premier boot. Rien à faire manuellement.

---

## Ansible - Configuration des services

Ansible configure les services sur les VMs après `terraform apply`. Le hardening CIS est déjà baked dans l'image Packer — Ansible ne s'occupe que des services applicatifs.

**Prérequis :** venv activé (`source ~/.virtualenvs/ansible/bin/activate`)

### Structure

```
ansible/
├── inventory/
│   └── hosts.yml          # 4 hôtes en 3 groupes (vault_servers, spire_servers, workloads)
├── playbooks/
│   ├── site.yml            # déploiement complet from scratch
│   ├── vault.yml           # Vault seul (install + configure + bootstrap)
│   ├── spire.yml           # SPIRE server + agents
│   └── boundary.yml        # Boundary dev mode sur le laptop
└── roles/
    ├── vault-server/       # install, configure (vault.hcl), bootstrap (init/unseal/secrets engines)
    ├── vault-agent/        # vault-ssh-helper, PAM, PostgreSQL
    ├── spire-server/       # install, configure (server.conf), bootstrap (registration entries)
    ├── spire-agent/        # install, configure (agent.conf, join token)
    └── boundary/           # install, service systemd, targets TCP
```

### Inventory

```yaml
# ansible/inventory/hosts.yml
all:
  vars:
    ansible_user: ubuntu
    ansible_ssh_private_key_file: ~/.ssh/devsecops
  children:
    vault_servers:
      hosts:
        vault-server: { ansible_host: 10.0.0.10 }
    spire_servers:
      hosts:
        spire-server: { ansible_host: 10.0.0.11 }
    workloads:
      hosts:
        workload-a: { ansible_host: 10.0.0.20 }
        workload-b: { ansible_host: 10.0.0.21 }
```

### Déploiement

```bash
cd ansible

# Vérifier la connectivité avant de déployer
ansible all -m ping

# Déploiement complet (ordre : Vault → SPIRE → Boundary)
# -K demande le mot de passe sudo pour Boundary (localhost)
ansible-playbook playbooks/site.yml -v -K

# Rejouer un seul service
ansible-playbook playbooks/vault.yml -v
ansible-playbook playbooks/spire.yml -v
ansible-playbook playbooks/boundary.yml -v -K
```

**`-K` (--ask-become-pass)** : nécessaire car Boundary tourne sur le laptop (`connection: local`) et a besoin de sudo pour dnf et systemd. Les VMs distantes ont NOPASSWD via cloud-init, le mot de passe est ignoré pour elles.

**Ordre important :** Vault doit tourner avant SPIRE (les agents récupèrent des tokens via Vault). Boundary est indépendant.

---

## Vérification

```bash
# SSH sur les 4 VMs
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10   # vault-server
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.11   # spire-server
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.20   # workload-a
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.21   # workload-b

# Contrôle hardening (sur n'importe quelle VM)
sudo ufw status
sudo auditctl -s | grep enabled   # → enabled 2 (immutable)
sudo sshd -T | grep passwordauthentication   # → no
mount | grep /tmp                 # → noexec
```
