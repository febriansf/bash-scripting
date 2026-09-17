#!/bin/bash

HDS_DIR="/tmp/hddsentinel"
HDS_BIN="$HDS_DIR/HDSentinel"

if [ ! -x "$HDS_BIN" ]; then
    mkdir -p "$HDS_DIR"
    cd "$HDS_DIR" || exit 1
    wget -q https://www.hdsentinel.com/hdslin/hdsentinel-020c-x64.zip
    unzip -o hdsentinel-020c-x64.zip
    chmod +x HDSentinel
fi

cd "$HDS_DIR" || exit 1

if [ "$EUID" -ne 0 ]; then
    echo "WARNING: not running as root — HDSentinel may not detect any drives." >&2
fi

# Save raw output for inspection
./HDSentinel > /tmp/hds_raw.txt

cat /tmp/hds_raw.txt | awk '
BEGIN {
  fmt="%-10s %-26s %-16s %-10s %-18s %-20s %10s %8s %8s\n"
  printf fmt,"Device","Model","S/N","Size","PoT","EstLife","TBW","Health","Perf"
  printf fmt,"------","-----","---","----","---","-------","---","------","----"
}

/HDD Device/ {
  if (dev && sn && health !~ /Unknown/ && perf !~ /Unknown/)
    printf fmt,dev,model,sn,size,pot,life,tbw,health,perf
  dev=$4; model=""; sn=""; size=""; pot=""; life=""; tbw=""; health=""; perf=""
}

/HDD Model ID/ {sub(/^HDD Model ID *: /,""); model=$0}
/HDD Serial No/ {sn=$4}
/HDD Size/ {size=$4"MB"}

/Power on time/ {
  sub(/^Power on time: /,"")
  split($0,a,",")
  pot=a[1]
}

/Est. lifetime/ {
  sub(/^Est\. lifetime: /,"")
  life=$0
}

/Total written/ {tbw=$3"TB"}
/Health/ {health=$3"%"}
/Performance/ {perf=$3"%"}

END {
  if (dev && sn && health !~ /Unknown/ && perf !~ /Unknown/)
    printf fmt,dev,model,sn,size,pot,life,tbw,health,perf
}'

echo "Raw HDSentinel output saved to /tmp/hds_raw.txt for inspection"
