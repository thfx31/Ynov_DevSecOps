# Setup de la machine hôte

> Prérequis à effectuer **une seule fois** sur le laptop avant de lancer le projet.
> OS testé : Fedora 44 (kernel 7.x)

---

## 1. Paquets système

```bash
sudo dnf install -y \
  qemu-kvm libvirt libvirt-daemon-kvm virt-install \
  libguestfs-tools \
  unzip curl jq git
```

Active et démarre libvirt :
```bash
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER   # puis se reconnecter
```

---

## 2. Vault CLI (laptop)

Le binaire `vault` est nécessaire pour interagir avec le Vault server depuis le laptop.

```bash
sudo dnf config-manager --add-repo \
  https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y vault
```

Configure les variables d'environnement pour la session :
```bash
export VAULT_ADDR=http://10.0.0.10:8200
export VAULT_TOKEN=$(ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 \
  'sudo cat /root/vault-init.json' | jq -r .root_token)
```

Pour ne pas avoir à les re-exporter à chaque session, ajoute dans `~/.zshrc` :
```bash
export VAULT_ADDR=http://10.0.0.10:8200
```
Le token est volontairement non persisté (secret).

---

## 3. Terraform

```bash
sudo dnf config-manager --add-repo \
  https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform
```

---

## 3. Packer

```bash
sudo dnf install -y packer
```

---

## 4. Clé SSH dédiée au projet

```bash
ssh-keygen -t ed25519 -f ~/.ssh/devsecops -N ""
```

---

## 5. Réseau libvirt — NAT et firewalld

Le réseau `zero-trust-net` (10.0.0.0/24) est créé par Terraform. Sur Fedora,
firewalld bloque par défaut le forwarding entre zones. Ajouter les règles
permanentes suivantes **après** le premier `terraform apply` :

```bash
sudo firewall-cmd --permanent --direct \
  --add-rule ipv4 filter FORWARD 0 -i virbr1 -j ACCEPT
sudo firewall-cmd --permanent --direct \
  --add-rule ipv4 filter FORWARD 1 -o virbr1 \
  -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo firewall-cmd --reload
```

**Pourquoi :** libvirt crée les règles masquerade (NAT) dans nftables mais ne
gère pas la chaîne FORWARD dont la policy est DROP sur Fedora. Sans ces règles,
les VMs peuvent pinguer le gateway (10.0.0.1) mais pas internet.

---

## 6. Autostart au reboot

Après le premier `terraform apply`, activer l'autostart des VMs et du réseau :

```bash
for vm in vault-server spire-server workload-a workload-b; do
  sudo virsh autostart $vm
done
sudo virsh net-autostart zero-trust-net
```

**Pourquoi :** le provider libvirt Terraform 0.7.x met `autostart = true` dans
la config mais ne l'applique pas systématiquement sur toutes les versions de
libvirt. À faire une fois manuellement.

---

## 7. Vérification complète

```bash
# VMs autostart
for vm in vault-server spire-server workload-a workload-b; do
  echo -n "$vm: "; sudo virsh dominfo $vm | grep Autostart
done

# Réseau autostart
sudo virsh net-info zero-trust-net | grep Autostart

# Règles FORWARD permanentes
sudo firewall-cmd --permanent --direct --get-all-rules

# Connectivité VMs
for ip in 10.0.0.10 10.0.0.11 10.0.0.20 10.0.0.21; do
  echo -n "$ip: "; ping -c1 -W1 $ip &>/dev/null && echo "ok" || echo "KO"
done

# Accès internet depuis une VM
ssh -i ~/.ssh/devsecops ubuntu@10.0.0.10 'ping -c2 8.8.8.8'
```

Résultat attendu : 4 VMs `ok`, ping 8.8.8.8 répond depuis vault-server.

