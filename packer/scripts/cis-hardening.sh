#!/usr/bin/env bash
# CIS Ubuntu 24.04 LTS Benchmark - Level 1 hardening
# Conçu pour tourner une seule fois pendant le build Packer.
# Packer maintient sa connexion SSH existante même si sshd est reconfiguré.
set -euo pipefail

echo "=== [CIS L1] Ubuntu 24.04 hardening - début ==="

# ─── 1. MODULES KERNEL INUTILISES ─────────────────────────────────────────────
echo "[1/9] Blacklist modules noyau..."
cat > /etc/modprobe.d/cis-blacklist.conf << 'EOF'
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true
install usb-storage /bin/true
EOF

# /tmp en tmpfs (nosuid,nodev,noexec)
if ! grep -q "^tmpfs /tmp" /etc/fstab; then
  echo "tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0" >> /etc/fstab
fi

# ─── 2. PAQUETS ───────────────────────────────────────────────────────────────
echo "[2/9] Mise à jour et installation paquets CIS..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -yq
apt-get install -yq \
  auditd \
  audispd-plugins \
  libpam-pwquality \
  rsyslog \
  aide \
  ufw \
  fail2ban

# Suppression paquets non nécessaires
apt-get purge -yq \
  telnet \
  rsh-client \
  talk \
  ntalk \
  2>/dev/null || true
apt-get autoremove -yq

# ─── 3. SYSCTL RESEAU ─────────────────────────────────────────────────────────
echo "[3/9] Sysctl hardening..."
cat > /etc/sysctl.d/60-cis.conf << 'EOF'
# IP forwarding désactivé (workloads - pas de routage)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log paquets martiens
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# SYN cookies (protection SYN flood)
net.ipv4.tcp_syncookies = 1

# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignorer les broadcasts ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# IPv6 - désactiver RA
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Kernel hardening
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
EOF

sysctl --system

# ─── 4. SSH ───────────────────────────────────────────────────────────────────
echo "[4/9] SSH hardening..."
cat > /etc/ssh/sshd_config << 'EOF'
# CIS Ubuntu 24.04 L1 - SSH hardening
Port 22
Protocol 2

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

SyslogFacility AUTH
LogLevel VERBOSE

LoginGraceTime 60
PermitRootLogin no
StrictModes yes
MaxAuthTries 4
MaxSessions 4

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
UsePAM yes

IgnoreRhosts yes
HostbasedAuthentication no

AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
X11Forwarding no
PrintMotd no
PrintLastLog yes
PermitUserEnvironment no
Compression no

ClientAliveInterval 300
ClientAliveCountMax 0

Banner /etc/issue.net

# Algorithmes approuvés CIS
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512

AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Valider la config - NE PAS restart ici (Packer est connecté via password)
# Le démarrage depuis l'image appliquera la config (clé SSH requise)
sshd -t

# ─── 5. AUDITD ────────────────────────────────────────────────────────────────
echo "[5/9] Audit daemon..."
cat > /etc/audit/rules.d/99-cis.rules << 'EOF'
-D
-b 8192
-f 1

# Changements d'identité
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# Locale / réseau
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale

# Login / logout
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins

# Sessions
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins

# Permissions
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=1000 -F auid!=4294967295 -k perm_mod

# Accès refusés
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=4294967295 -k access

# Elévation de privilèges
-w /bin/su -p x -k priv_esc
-w /usr/bin/sudo -p x -k priv_esc
-w /etc/sudoers -p wa -k priv_esc
-w /etc/sudoers.d/ -p wa -k priv_esc

# Montages
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts

# Immutable - doit être en dernière règle
-e 2
EOF

systemctl enable auditd
systemctl restart auditd

# ─── 6. RSYSLOG ───────────────────────────────────────────────────────────────
echo "[6/9] Logging..."
systemctl enable rsyslog
systemctl start rsyslog

# ─── 7. PAM / POLITIQUE MOTS DE PASSE ────────────────────────────────────────
echo "[7/9] PAM et politique mots de passe..."

cat > /etc/security/pwquality.conf << 'EOF'
minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
maxrepeat = 3
EOF

sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS\t90/'  /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS\t7/'   /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE\t14/'  /etc/login.defs
sed -i 's/^UMASK.*/UMASK\t\t027/'                /etc/login.defs

# Verrouillage de compte après échecs (faillock)
cat > /etc/security/faillock.conf << 'EOF'
deny = 5
fail_interval = 900
unlock_time = 900
EOF

# ─── 8. SERVICES INUTILISES ───────────────────────────────────────────────────
echo "[8/9] Désactivation services non nécessaires..."
SERVICES="avahi-daemon cups isc-dhcp-server isc-dhcp-server6 slapd nfs-server rpcbind bind9 vsftpd apache2 dovecot smbd squid snmpd"
for svc in $SERVICES; do
  if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
    systemctl stop    "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  fi
done

# ─── 9. UFW + BANNER + DIVERS ─────────────────────────────────────────────────
echo "[9/9] Firewall, banner, comptes..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
systemctl enable ufw

cat > /etc/issue.net << 'EOF'
*******************************************************************************
AUTHORIZED USERS ONLY - All activity is monitored and logged.
Unauthorized access is strictly prohibited and will be prosecuted.
*******************************************************************************
EOF
cp /etc/issue.net /etc/issue

# Root verrouillé
passwd -l root

# Sudo loggue toutes les commandes
echo 'Defaults logfile="/var/log/sudo.log"' > /etc/sudoers.d/99-cis-sudo-log
chmod 440 /etc/sudoers.d/99-cis-sudo-log

echo "=== [CIS L1] Hardening terminé ==="
