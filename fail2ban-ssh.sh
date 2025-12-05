#!/bin/bash
#
# Fail2Ban installer & configurator for Linux
#

# Pastikan dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo "Jalankan sebagai root"
  exit 1
fi

echo "==> Checking OS type..."

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
else
    echo "Tidak dapat mendeteksi OS."
    exit 1
fi

echo "Detected OS: $OS_ID"
echo "==> Install Fail2Ban..."

case "$OS_ID" in
    centos|rhel|cloudlinux)
        yum -y install epel-release
        yum -y install fail2ban
        systemctl enable --now fail2ban
        ;;

    almalinux|rocky)
        dnf -y install epel-release
        dnf -y install fail2ban
        systemctl enable --now fail2ban
        ;;

    debian|ubuntu)
        apt update -y
        apt install -y fail2ban
        systemctl enable --now fail2ban
        ;;

    *)
        echo "OS tidak dikenal. Instalasi Fail2Ban tidak dapat dilanjutkan."
        exit 1
        ;;
esac

echo "==> Fail2Ban installation completed."
echo " "
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
