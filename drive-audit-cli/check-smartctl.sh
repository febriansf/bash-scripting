#!/bin/bash

OUTFILE="smartctl-results.txt"
> "$OUTFILE"

log_header() {
    {
        echo "===================================================="
        echo "== $1"
        echo "===================================================="
    } >> "$OUTFILE"
}

# 1. Cek smartctl tersedia
if ! command -v smartctl >/dev/null 2>&1; then
    echo "ERROR: smartctl tidak ditemukan."
    echo "Install dulu, misal:"
    echo "  Debian/Ubuntu   : apt install smartmontools"
    echo "  RHEL/CentOS/Alma: dnf install smartmontools  (atau yum)"
    exit 1
fi

echo "smartctl ditemukan: $(smartctl --version | head -1)"
echo "Hasil akan ditulis ke: $OUTFILE"
echo ""

# 2. Ambil semua disk fisik via lsblk, exclude removable/flashdisk, loop, rom
#    TYPE=disk -> hanya physical disk (bukan partisi/lvm)
#    RM!=1     -> exclude removable (flashdisk, kartu SD, dll)
mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE,RM 2>/dev/null | awk '$2=="disk" && $3!="1" {print $1}')

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "Tidak ada disk fisik non-removable terdeteksi via lsblk." >> "$OUTFILE"
else
    for name in "${DISKS[@]}"; do
        dev="/dev/${name}"

        [ -b "$dev" ] || continue

        # double check removable via sysfs (jaga-jaga lsblk RM kosong)
        if [ -f "/sys/block/${name}/removable" ] && [ "$(cat /sys/block/${name}/removable)" = "1" ]; then
            log_header "$dev dilewati (removable/flashdisk)"
            continue
        fi

        log_header "SMART Info: $dev"

        output=$(smartctl -a "$dev" 2>&1)

        # kalau gagal deteksi device type default, coba fallback umum
        if echo "$output" | grep -qiE "Unknown USB bridge|Unable to detect device type|Smartctl open device.*failed|No such device"; then
            echo ">> Mode default gagal, mencoba fallback -d sat ..." >> "$OUTFILE"
            alt=$(smartctl -a -d sat "$dev" 2>&1)
            if echo "$alt" | grep -qiE "^Model|SMART overall-health"; then
                output="$alt"
            else
                echo ">> Fallback -d sat gagal juga, mencoba -d scsi ..." >> "$OUTFILE"
                alt=$(smartctl -a -d scsi "$dev" 2>&1)
                if echo "$alt" | grep -qiE "^Model|SMART overall-health"; then
                    output="$alt"
                else
                    output="$output

[!] $dev tidak bisa dibaca smartctl (kemungkinan di balik RAID controller / tidak didukung). Lihat bagian MegaRAID di bawah jika pakai hardware RAID."
                fi
            fi
        fi

        echo "$output" >> "$OUTFILE"
        echo "" >> "$OUTFILE"
    done
fi

# 3. Deteksi controller RAID hardware (MegaRAID/PERC/LSI) dan scan physical disk di baliknya
if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qiE "MegaRAID|LSI|PERC"; then
    log_header "Terdeteksi controller RAID hardware (MegaRAID/PERC/LSI)"
    echo "Mencoba scan physical disk lewat -d megaraid,N pada /dev/sda ..." >> "$OUTFILE"
    echo "" >> "$OUTFILE"

    found_any=0
    for i in $(seq 0 31); do
        out=$(smartctl -a -d megaraid,"$i" /dev/sda 2>&1)
        if echo "$out" | grep -qiE "^Device Model|^Model|SMART overall-health"; then
            log_header "MegaRAID physical disk index $i (/dev/sda -d megaraid,$i)"
            echo "$out" >> "$OUTFILE"
            echo "" >> "$OUTFILE"
            found_any=1
        fi
    done

    if [ "$found_any" -eq 0 ]; then
        echo "Controller RAID terdeteksi tapi tidak ada physical disk terbaca lewat megaraid,0-31." >> "$OUTFILE"
        echo "Coba cek manual: smartctl -a -d megaraid,0 /dev/sda   (ganti index sesuai kebutuhan)" >> "$OUTFILE"
    fi
fi

echo "Selesai. Hasil tersimpan di $OUTFILE"
