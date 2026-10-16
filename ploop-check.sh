#!/bin/bash
# ploop-check.sh - check every OpenVZ 7 container's ploop image size
#
# Flags a container when:
#   OVER_DISK  - image on the host is larger than the container's virtual disk
#   WASTE(n%)  - (image - used inside CT) is >= WASTE_PCT % of the virtual disk
#   SNAP(n)    - the image has n snapshot deltas
#
# Usage: ./ploop-check.sh [-p] [-w PCT]
#   -p       show only containers with problems
#   -w PCT   waste threshold in percent (default 30)
# Exit code: 0 = no problems, 1 = at least one container flagged

WASTE_PCT=30
ONLY_PROBLEMS=0

while getopts "pw:h" opt; do
  case $opt in
    p) ONLY_PROBLEMS=1 ;;
    w) WASTE_PCT=$OPTARG ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

hr() { [[ $1 =~ ^[0-9]+$ ]] && numfmt --to=iec "$1" || echo "$1"; }

# List containers: ctid status private root hostname
list_cts() {
  if vzlist -a -H -o ctid,status,private,root,hostname 2>/dev/null; then return; fi
  # Fallback if vzlist is unavailable
  for d in /vz/private/*/; do
    ct=$(basename "$d")
    st=$(vzctl status "$ct" 2>/dev/null | grep -qw running && echo running || echo stopped)
    echo "$ct $st /vz/private/$ct /vz/root/$ct -"
  done
}

FMT="%-36s %-20s %-10s %7s %7s %7s %6s  %s\n"
printf "$FMT" CTID HOSTNAME STATUS DISK USED IMAGE WASTE FLAGS
problems=0

while read -r ctid status private root hostname; do
  desc="$private/root.hdd/DiskDescriptor.xml"
  [ -f "$desc" ] || continue   # not a ploop container

  sectors=$(sed -n 's:.*<Disk_size>\([0-9]*\)</Disk_size>.*:\1:p' "$desc" | head -1)
  [ -n "$sectors" ] || continue
  virt=$((sectors * 512))

  # Real allocated size of base image + any snapshot deltas
  image=$(du -c --block-size=1 "$private"/root.hdd/root.hds* 2>/dev/null | tail -1 | cut -f1)
  snaps=$(( $(grep -c '<Shot>' "$desc") - 1 ))

  used="-"; waste="-"
  if [ "$status" = "running" ]; then
    used=$(df -B1 --output=used "$root" 2>/dev/null | tail -1 | tr -d ' ')
  fi

  flags=""
  (( image > virt )) && flags+="OVER_DISK "
  (( snaps > 0 ))   && flags+="SNAP($snaps) "
  if [[ $used =~ ^[0-9]+$ ]]; then
    pct=$(( (image - used) * 100 / virt ))
    (( pct < 0 )) && pct=0
    waste="${pct}%"
    (( pct >= WASTE_PCT )) && flags+="WASTE(${pct}%) "
  fi

  [ -n "$flags" ] && problems=$((problems + 1))
  [ "$ONLY_PROBLEMS" = 1 ] && [ -z "$flags" ] && continue

  printf "$FMT" "$ctid" "${hostname:0:20}" "$status" \
    "$(hr "$virt")" "$(hr "$used")" "$(hr "$image")" "$waste" "${flags:-OK}"
done < <(list_cts)

echo
echo "Containers flagged: $problems (waste threshold ${WASTE_PCT}%)"
[ "$problems" -eq 0 ]
