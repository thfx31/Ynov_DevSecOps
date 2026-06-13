version: 2
ethernets:
  eth0:
    match:
      name: "en*"
    set-name: eth0
    dhcp4: false
    addresses:
      - ${ip_address}/24
    routes:
      - to: default
        via: ${gateway}
    nameservers:
      addresses:
        - ${dns}
        - 1.1.1.1
