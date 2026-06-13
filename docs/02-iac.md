# IaC — Packer + Terraform + Ansible

## Résultat

4 VMs Ubuntu 24.04 CIS L1 opérationnelles sur KVM/libvirt :

| VM | IP | RAM | Rôle |
|---|---|---|---|
| vault-server | 10.0.0.10 | 2 Go | Vault, PKI |
| spire-server | 10.0.0.11 | 1 Go | SPIRE Server |
| workload-a | 10.0.0.20 | 1 Go | SPIRE Agent, app API, PostgreSQL |
| workload-b | 10.0.0.21 | 1 Go | SPIRE Agent, app client |

---

## Packer — Image de base durcie

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

## Terraform — Provisioning VMs

**Provider :** `dmacvicar/libvirt` **v0.7.6**

> ⚠️ La v0.9.x a été abandonnée : rewrite instable, `libvirt_cloudinit_disk` crée l'ISO dans `/tmp` sans le téléverser correctement dans le pool (bug `file://` manquant). La v0.7.x gère l'ISO directement dans le pool en une ressource.

**Structure :**
```
terraform/
├── main.tf               — pool, réseau, 4 modules VM
├── modules/
│   ├── network/          — libvirt_network NAT
│   └── vm/               — libvirt_volume + libvirt_cloudinit_disk + libvirt_domain
│       └── templates/
│           ├── cloud_init.tpl      — user-data cloud-init
│           └── meta_data.tpl       — instance-id
```

**Décisions :**

- MACs fixes (`52:54:00:00:00:xx`) pour traçabilité et futures réservations DHCP
- `wait_for_lease = false` : les IPs sont configurées par cloud-init, pas DHCP
- `libvirt_pool` type `dir` → `/var/lib/libvirt/images/devsecops/`

**Apply :**
```bash
cd terraform
terraform init
terraform apply -var="ssh_public_key=$(cat ~/.ssh/devsecops.pub)"
# ~3 min (copie 4 × qcow2 ~1.5 Go)
```

---

## Cloud-init — Configuration réseau

**Problème rencontré :** le module réseau de cloud-init (`network_config` dans `libvirt_cloudinit_disk`) n'applique pas la config netplan dans Ubuntu 24.04 — cloud-init cherche d'abord un metadata server EC2 (timeout 120s), puis ignore la config réseau.

**Solution :** `write_files` + `runcmd` dans le `user_data` — écriture directe du netplan et application immédiate.

```yaml
# cloud_init.tpl
datasource_list: [NoCloud, None]   # évite le timeout EC2

write_files:
  - path: /etc/netplan/99-static.yaml
    content: |
      network:
        version: 2
        ethernets:
          id0:
            match: {name: "en*"}
            dhcp4: false
            addresses: [${ip_address}/24]
            routes: [{to: default, via: ${gateway}}]

runcmd:
  - rm -f /etc/netplan/50-cloud-init.yaml
  - netplan apply
  - touch /etc/cloud/cloud-init.disabled
```

L'IP est passée depuis `main.tf` → `modules/vm` → `templatefile` → `cloud_init.tpl`.

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
