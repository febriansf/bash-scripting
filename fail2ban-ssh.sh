#!/bin/bash
#
# Fail2Ban installer & configurator for Linux
#

set -e

# ============================================================
# Root check
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "Jalankan sebagai root."
    exit 1
fi

echo "============================================================"
echo " Fail2Ban Installer & Configurator"
echo "============================================================"
echo

# ============================================================
# Detect OS
# ============================================================

echo "==> Checking OS type..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
else
    echo "Tidak dapat mendeteksi OS."
    exit 1
fi

echo "Detected OS: $OS_ID"
echo

# ============================================================
# Install Fail2Ban
# ============================================================

echo "==> Install Fail2Ban..."

case "$OS_ID" in

    centos|rhel|cloudlinux|virtuozzo)
        yum -y install epel-release
        yum -y install fail2ban
        ;;

    almalinux|rocky)
        dnf -y install epel-release
        dnf -y install fail2ban
        ;;

    debian|ubuntu)
        apt update -y
        apt install -y fail2ban
        ;;

    *)
        echo "OS tidak dikenal: $OS_ID"
        echo "Instalasi Fail2Ban tidak dapat dilanjutkan."
        exit 1
        ;;
esac

echo
echo "==> Fail2Ban package installation completed."
echo

# ============================================================
# Detect firewall backend
# ============================================================

HAS_IPTABLES=false
HAS_FIREWALLCMD=false
HAS_IPSET=false

if command -v iptables >/dev/null 2>&1; then
    HAS_IPTABLES=true
fi

if command -v firewall-cmd >/dev/null 2>&1; then
    HAS_FIREWALLCMD=true
fi

if command -v ipset >/dev/null 2>&1; then
    HAS_IPSET=true
fi

# ============================================================
# Firewall selection
# ============================================================

echo "============================================================"
echo " Firewall Backend"
echo "============================================================"
echo

echo "Pilih firewall backend yang akan digunakan Fail2Ban:"
echo

if [ "$HAS_IPTABLES" = true ]; then
    echo "  1) iptables"
else
    echo "  1) iptables (tidak tersedia)"
fi

if [ "$HAS_FIREWALLCMD" = true ]; then
    echo "  2) firewall-cmd"
else
    echo "  2) firewall-cmd (tidak tersedia)"
fi

if [ "$HAS_FIREWALLCMD" = true ] && [ "$HAS_IPSET" = true ]; then
    echo "  3) firewall-cmd + ipset (recommended)"
else
    echo "  3) firewall-cmd + ipset (tidak tersedia)"
fi

echo

while true; do
    read -rp "Masukkan pilihan [1-3]: " FIREWALL_CHOICE

    case "$FIREWALL_CHOICE" in

        1)
            if [ "$HAS_IPTABLES" != true ]; then
                echo
                echo "ERROR: iptables tidak tersedia."
                echo
                continue
            fi

            FIREWALL_BACKEND="iptables"
            FAIL2BAN_ACTION='iptables-multiport[name=sshd, port="ssh", protocol=tcp]'
            break
            ;;

        2)
            if [ "$HAS_FIREWALLCMD" != true ]; then
                echo
                echo "ERROR: firewall-cmd tidak tersedia."
                echo
                continue
            fi

            FIREWALL_BACKEND="firewallcmd"
            FAIL2BAN_ACTION='firewallcmd-multiport[name=sshd, port="ssh", protocol=tcp]'
            break
            ;;

        3)
            if [ "$HAS_FIREWALLCMD" != true ]; then
                echo
                echo "ERROR: firewall-cmd tidak tersedia."
                echo
                continue
            fi

            if [ "$HAS_IPSET" != true ]; then
                echo
                echo "ERROR: ipset tidak tersedia."
                echo
                continue
            fi

            FIREWALL_BACKEND="firewallcmd-ipset"
            FAIL2BAN_ACTION='firewallcmd-ipset[name=sshd, port="ssh", protocol=tcp]'
            break
            ;;

        *)
            echo
            echo "Pilihan tidak valid. Masukkan 1, 2, atau 3."
            echo
            ;;
    esac
done

echo
echo "Firewall backend yang dipilih:"
echo "  $FIREWALL_BACKEND"
echo
echo "Fail2Ban action:"
echo "  $FAIL2BAN_ACTION"
echo

# ============================================================
# Check action file
# ============================================================

case "$FIREWALL_BACKEND" in

    iptables)
        ACTION_FILE="/etc/fail2ban/action.d/iptables-multiport.conf"
        ;;

    firewallcmd)
        ACTION_FILE="/etc/fail2ban/action.d/firewallcmd-multiport.conf"
        ;;

    firewallcmd-ipset)
        ACTION_FILE="/etc/fail2ban/action.d/firewallcmd-ipset.conf"
        ;;

esac

if [ ! -f "$ACTION_FILE" ]; then
    echo "ERROR: Action file tidak ditemukan:"
    echo "       $ACTION_FILE"
    echo
    echo "Cek paket Fail2Ban yang terinstall."
    exit 1
fi

# ============================================================
# Create jail.local
# ============================================================

echo "==> Buat file /etc/fail2ban/jail.local..."

cat > /etc/fail2ban/jail.local << EOF
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

# Firewall backend
action    = $FAIL2BAN_ACTION
EOF

# ============================================================
# Validate configuration
# ============================================================

echo
echo "==> Validating Fail2Ban configuration..."

if ! fail2ban-client -t; then
    echo
    echo "ERROR: Konfigurasi Fail2Ban tidak valid."
    echo "File: /etc/fail2ban/jail.local"
    exit 1
fi

echo
echo "Configuration test: OK"

# ============================================================
# Enable and restart Fail2Ban
# ============================================================

echo
echo "==> Enable dan start Fail2Ban service..."

systemctl enable fail2ban
systemctl restart fail2ban

# ============================================================
# Final status
# ============================================================

echo
echo "============================================================"
echo " Fail2Ban Installation Completed"
echo "============================================================"
echo
echo "OS              : $OS_ID"
echo "Firewall backend: $FIREWALL_BACKEND"
echo "Action          : $FAIL2BAN_ACTION"
echo

echo "==> Fail2Ban service status:"
systemctl --no-pager --full status fail2ban

echo
echo "==> SSH jail status:"
fail2ban-client status sshd
