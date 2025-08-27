#!/bin/bash
#
# Fail2Ban installer & configurator for OpenVZ (YUM-based)
#

# Pastikan dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo "Jalankan sebagai root"
  exit 1
fi

echo "==> Install Fail2Ban..."
yum -y install fail2ban

echo "==> Buat file jail.local..."
cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled   = true
port      = ssh
filter    = sshd

# Ban setelah 3 percobaan gagal
maxretry  = 3

# Cari percobaan gagal dalam rentang 10 menit
findtime  = 10m

# Lama ban
bantime   = 5m

# Bisa pakai "permanent ban" untuk IP yang berulang kali bandel
# bantime.increment = true
# bantime.rndtime = 60m
# bantime.factor = 2
# bantime.maxtime = 1w

# Log file lokasi (otomatis dari variable)
logpath   = %(sshd_log)s

# Action default iptables/firewalld
action    = iptables-multiport[name=sshd, port="ssh", protocol=tcp]
EOF

echo "==> Enable dan start Fail2Ban service..."
systemctl enable fail2ban
systemctl restart fail2ban

echo "==> Status Fail2Ban:"
systemctl status fail2ban --no-pager
