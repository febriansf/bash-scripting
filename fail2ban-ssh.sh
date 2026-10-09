#!/usr/bin/env bash
#
# Fail2Ban installer & configurator (SSH jail)
#
# Pemakaian:
#   bash fail2ban-ssh.sh          # interaktif
#   bash fail2ban-ssh.sh -b 3     # non-interaktif
#                                 #   1 = iptables
#                                 #   2 = firewall-cmd (rich rules)
#                                 #   3 = firewall-cmd + ipset (legacy, butuh modul kernel ip_set)
#                                 #   4 = nftables (native, recommended untuk EL10)
#
# Override lewat environment variable:
#   MAXRETRY=3 FINDTIME=10m BANTIME=5m BAN_INCREMENT=true bash fail2ban-ssh.sh
#
# Via pipe (menu tetap interaktif lewat /dev/tty, argumen lewat "bash -s --"):
#   wget -qO- <url> | bash
#   wget -qO- <url> | bash -s -- -b 4
#
set -Eeuo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
trap 'echo "ERROR: script berhenti di baris $LINENO" >&2' ERR

# ============================================================
# Settings
# ============================================================

MAXRETRY="${MAXRETRY:-3}"               # ban setelah N percobaan gagal
FINDTIME="${FINDTIME:-10m}"             # rentang waktu percobaan gagal
BANTIME="${BANTIME:-5m}"                # lama ban
BAN_INCREMENT="${BAN_INCREMENT:-false}" # true = ban makin lama untuk IP berulang
JAIL_FILE="/etc/fail2ban/jail.d/sshd.local"

info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ============================================================
# Args & root check
# ============================================================

CHOICE=""
while getopts ":b:h" opt; do
    case "$opt" in
        b) CHOICE="$OPTARG" ;;
        h) sed -n '2,18p' "$0"; exit 0 ;;
        *) die "Opsi tidak valid. Gunakan -h untuk bantuan." ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Jalankan sebagai root."

echo "============================================================"
echo " Fail2Ban Installer & Configurator"
echo "============================================================"
echo

# ============================================================
# Detect OS & package manager
# ============================================================

[[ -f /etc/os-release ]] || die "Tidak dapat mendeteksi OS."
OS_ID="$(. /etc/os-release; echo "${ID:-unknown}")"

if   command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
elif command -v apt-get >/dev/null 2>&1; then PM=apt
else die "Package manager tidak dikenal (OS: $OS_ID)."
fi

info "OS: $OS_ID (package manager: $PM)"
echo

# ============================================================
# Install Fail2Ban (skip jika sudah ada)
# ============================================================

info "Install Fail2Ban..."

if command -v fail2ban-client >/dev/null 2>&1; then
    echo "Fail2Ban sudah terinstall, skip."
else
    case "$PM" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y fail2ban
            ;;
        dnf|yum)
            rpm -q epel-release >/dev/null 2>&1 \
                || "$PM" -y install epel-release \
                || warn "epel-release gagal diinstall, lanjut tanpa EPEL."
            "$PM" -y install fail2ban
            ;;
    esac
fi
echo

# ============================================================
# Detect firewall backend
# ============================================================

HAS_IPTABLES=false
HAS_IPSET=false       # binary ipset ada DAN modul kernel ip_set berfungsi
HAS_NFT=false         # nft ada DAN nf_tables berfungsi
HAS_FIREWALLD=false   # firewall-cmd ada DAN firewalld sedang berjalan
HAS_FWIPSET=false

# Di EL10 binary ipset bisa terinstall tanpa modul kernel ip_set
# (kernel-modules-extra), hasilnya "Kernel error received: Invalid argument".
# Jadi test fungsinya, bukan sekadar cek binary.
probe_ipset() {
    command -v ipset >/dev/null 2>&1 || return 1
    ipset destroy f2b-probe >/dev/null 2>&1 || true
    ipset create f2b-probe hash:ip timeout 60 >/dev/null 2>&1 || return 1
    ipset destroy f2b-probe >/dev/null 2>&1 || true
}

command -v iptables >/dev/null 2>&1 && HAS_IPTABLES=true
probe_ipset && HAS_IPSET=true
if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
    HAS_NFT=true
fi

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    HAS_FIREWALLD=true
fi

if $HAS_FIREWALLD && $HAS_IPSET; then
    HAS_FWIPSET=true
fi

if   $HAS_NFT;       then DEFAULT_CHOICE=4
elif $HAS_FIREWALLD; then DEFAULT_CHOICE=2
elif $HAS_IPTABLES;  then DEFAULT_CHOICE=1
else die "Tidak ada firewall backend yang berfungsi (nftables / firewalld aktif / iptables)."
fi

mark() { if [[ "$1" == true ]]; then echo ""; else echo " (tidak tersedia)"; fi; }

# Set BANACTION berdasarkan pilihan; return 1 jika tidak valid / tidak tersedia
select_backend() {
    case "$1" in
        1)
            [[ $HAS_IPTABLES == true ]] || { warn "iptables tidak tersedia."; return 1; }
            BANACTION="iptables-multiport"
            ;;
        2)
            [[ $HAS_FIREWALLD == true ]] || { warn "firewall-cmd tidak tersedia / firewalld tidak berjalan."; return 1; }
            BANACTION="firewallcmd-rich-rules"
            ;;
        3)
            [[ $HAS_FWIPSET == true ]] || { warn "firewall-cmd + ipset tidak bisa dipakai (firewalld harus aktif dan modul kernel ip_set harus berfungsi)."; return 1; }
            BANACTION="firewallcmd-ipset"
            ;;
        4)
            [[ $HAS_NFT == true ]] || { warn "nftables tidak tersedia / tidak berfungsi."; return 1; }
            BANACTION="nftables"
            ;;
        *)
            warn "Pilihan tidak valid. Masukkan 1, 2, 3, atau 4."
            return 1
            ;;
    esac

    if [[ ! -f "/etc/fail2ban/action.d/${BANACTION}.conf" ]]; then
        warn "Action file tidak ditemukan: /etc/fail2ban/action.d/${BANACTION}.conf"
        return 1
    fi
}

BANACTION=""
if [[ -n "$CHOICE" ]]; then
    select_backend "$CHOICE" || die "Backend yang diminta (-b $CHOICE) tidak bisa dipakai."
elif ! { true </dev/tty; } 2>/dev/null; then
    # Tidak ada terminal sama sekali (cron, CI, dsb)
    warn "Tidak ada terminal interaktif, pakai default: $DEFAULT_CHOICE (gunakan -b untuk memilih)."
    select_backend "$DEFAULT_CHOICE" || die "Backend default tidak bisa dipakai."
else
    echo "============================================================"
    echo " Firewall Backend"
    echo "============================================================"
    echo
    echo "Pilih firewall backend yang akan digunakan Fail2Ban:"
    echo
    echo "  1) iptables$(mark "$HAS_IPTABLES")"
    echo "  2) firewall-cmd (rich rules)$(mark "$HAS_FIREWALLD")"
    echo "  3) firewall-cmd + ipset (legacy)$(mark "$HAS_FWIPSET")"
    echo "  4) nftables (recommended)$(mark "$HAS_NFT")"
    echo

    while true; do
        read -rp "Masukkan pilihan [1-4] (default: $DEFAULT_CHOICE): " CHOICE </dev/tty \
            || die "Input tidak tersedia. Gunakan opsi -b."
        CHOICE="${CHOICE:-$DEFAULT_CHOICE}"
        select_backend "$CHOICE" && break
        echo
    done
fi

echo
echo "Ban action: $BANACTION"
echo

# ============================================================
# Detect SSH port, log source, current client IP
# ============================================================

# Port dari konfigurasi sshd yang aktif (bisa lebih dari satu)
SSH_PORTS="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | paste -sd, - || true)"
SSH_PORTS="${SSH_PORTS:-ssh}"

# Log file auth jika ada, kalau tidak pakai journald
LOG_LINES=""
if   [[ -f /var/log/secure   ]]; then LOG_LINES=$'backend   = auto\nlogpath   = /var/log/secure'
elif [[ -f /var/log/auth.log ]]; then LOG_LINES=$'backend   = auto\nlogpath   = /var/log/auth.log'
else
    LOG_LINES="backend   = systemd"
    info "Log auth tidak ditemukan, pakai backend systemd (journald)."
    if [[ "$PM" == apt ]]; then
        apt-get install -y python3-systemd >/dev/null 2>&1 || warn "python3-systemd gagal diinstall."
    else
        "$PM" -y install python3-systemd >/dev/null 2>&1 || warn "python3-systemd gagal diinstall."
    fi
fi

# Whitelist IP admin yang sedang login supaya tidak ke-ban sendiri
IGNOREIP="127.0.0.1/8 ::1"
CLIENT_IP="${SSH_CONNECTION:-}"
CLIENT_IP="${CLIENT_IP%% *}"
[[ -n "$CLIENT_IP" ]] && IGNOREIP="$IGNOREIP $CLIENT_IP"

INCREMENT_LINES=""
if [[ "$BAN_INCREMENT" == true ]]; then
    INCREMENT_LINES=$'bantime.increment = true\nbantime.factor    = 2\nbantime.maxtime   = 1w'
fi

# ============================================================
# Write jail config (jail.d/sshd.local, jail.local tidak disentuh)
# ============================================================

info "Tulis $JAIL_FILE..."

BACKUP=""
if [[ -f "$JAIL_FILE" ]]; then
    BACKUP="$JAIL_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$JAIL_FILE" "$BACKUP"
    echo "Backup: $BACKUP"
fi

cat > "$JAIL_FILE" << EOF
# Generated by fail2ban-ssh.sh on $(date -Is)
[sshd]
enabled   = true
port      = $SSH_PORTS
filter    = sshd
maxretry  = $MAXRETRY
findtime  = $FINDTIME
bantime   = $BANTIME
ignoreip  = $IGNOREIP
banaction = $BANACTION
$LOG_LINES
${INCREMENT_LINES}
EOF

# ============================================================
# Validate configuration (rollback jika gagal)
# ============================================================

echo
info "Validating Fail2Ban configuration..."

if ! fail2ban-client -t; then
    if [[ -n "$BACKUP" ]]; then
        mv -f "$BACKUP" "$JAIL_FILE"
    else
        rm -f "$JAIL_FILE"
    fi
    die "Konfigurasi Fail2Ban tidak valid. Perubahan di-rollback."
fi

echo "Configuration test: OK"

# ============================================================
# Enable & restart
# ============================================================

echo
info "Enable dan restart Fail2Ban service..."

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

for _ in $(seq 1 15); do
    fail2ban-client ping >/dev/null 2>&1 && break
    sleep 1
done

if ! fail2ban-client ping >/dev/null 2>&1; then
    journalctl -u fail2ban -n 30 --no-pager || true
    die "Fail2Ban tidak berjalan setelah restart."
fi

# ============================================================
# Test ban end-to-end (IP dokumentasi 192.0.2.1, aman)
# ============================================================

echo
info "Test ban/unban dengan IP dummy 192.0.2.1..."

TEST_IP="192.0.2.1"
BAN_OK=false

fail2ban-client set sshd banip "$TEST_IP" >/dev/null 2>&1 || true
sleep 1

case "$BANACTION" in
    nftables)               RULES="$(nft list ruleset 2>/dev/null || true)" ;;
    firewallcmd-rich-rules) RULES="$(firewall-cmd --list-rich-rules 2>/dev/null || true)" ;;
    firewallcmd-ipset)      RULES="$(ipset list 2>/dev/null || true)" ;;
    *)                      RULES="$(iptables-save 2>/dev/null || true)" ;;
esac
grep -q "$TEST_IP" <<< "$RULES" && BAN_OK=true

fail2ban-client set sshd unbanip "$TEST_IP" >/dev/null 2>&1 || true

if $BAN_OK; then
    echo "Test ban: OK (IP muncul di firewall lalu di-unban)"
else
    warn "Test ban GAGAL: IP tidak muncul di firewall. Ban SSH TIDAK akan efektif."
    warn "Coba backend lain (-b) dan cek log di bawah:"
    journalctl -u fail2ban -n 20 --no-pager || true
fi

# ============================================================
# Final status
# ============================================================

echo
echo "============================================================"
echo " Fail2Ban Installation Completed"
echo "============================================================"
echo
echo "OS         : $OS_ID"
echo "Ban action : $BANACTION"
echo "SSH port   : $SSH_PORTS"
echo "Ignore IP  : $IGNOREIP"
echo "Maxretry   : $MAXRETRY / findtime $FINDTIME / bantime $BANTIME (increment: $BAN_INCREMENT)"
echo "Config     : $JAIL_FILE"
echo

info "SSH jail status:"
fail2ban-client status sshd
