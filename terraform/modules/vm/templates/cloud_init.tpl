#cloud-config

# Force cloud-init à n'utiliser que le CDROM local
datasource_list: [NoCloud, None]

hostname: ${hostname}
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_pub_key}

ssh_pwauth: false
disable_root: true

# Écrire le netplan directement — plus fiable que le module réseau cloud-init
write_files:
  - path: /etc/netplan/99-static.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          id0:
            match:
              name: "en*"
            dhcp4: false
            addresses:
              - ${ip_address}/24
            routes:
              - to: default
                via: ${gateway}
            nameservers:
              addresses: [${dns}, 1.1.1.1]

runcmd:
  - rm -f /etc/netplan/50-cloud-init.yaml
  - netplan apply
  - touch /etc/cloud/cloud-init.disabled
