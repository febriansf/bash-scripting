#!/bin/bash
# ploop-check.sh - check every OpenVZ 7 container's ploop image size
#
# Flags a container when:
#   OVER_DISK  - image on the host is larger than the container's virtual disk
#   WASTE(n%)  - (image - used inside CT) is >= WASTE_PCT % of the virtual disk
#   SNAP(n)    - the image has n snapshot deltas
#   FULL(n%)   - used space inside the CT is >= USE_PCT % of the virtual disk
#
# Usage: ./ploop-check.sh [-p] [-w PCT] [-u PCT] [-s FIELD] [-r] [-d|-dd]
#   -p        show only containers with problems
#   -w PCT    waste threshold in percent (default 30)
#   -u PCT    show only containers whose USED is >= PCT % of DISK
#             (also sets the FULL threshold, default 90)
#             -u 100 = containers whose used space has reached/exceeded the disk
#   -s FIELD  sort by: disk, used, image, waste, use (largest first)
#   -r        reverse the sort order (smallest first)
#   -d        detailed sizes (2 decimals) + FREE, BASE and DELTAS columns
#   -dd       exact sizes in bytes + FREE, BASE and DELTAS columns
#   -h        show this help
# Exit code: 0 = no problems, 1 = at least one container flagged, 2 = bad usage

WASTE_PCT=30
USE_PCT=90
USE_FILTER=0
ONLY_PROBLEMS=0
SORT_BY=""
REVERSE=0
DETAIL=0

usage() {
  cat <<'EOF'
ploop-check.sh - check every OpenVZ 7 container's ploop image size

Flags a container when:
  OVER_DISK  - image on the host is larger than the container's virtual disk
  WASTE(n%)  - (image - used inside CT) is >= WASTE_PCT % of the virtual disk
  SNAP(n)    - the image has n snapshot deltas
  FULL(n%)   - used space inside the CT is >= USE_PCT % of the virtual disk

Usage: ./ploop-check.sh [-p] [-w PCT] [-u PCT] [-s FIELD] [-r] [-d|-dd]
  -p        show only containers with problems
  -w PCT    waste threshold in percent (default 30)
  -u PCT    show only containers whose USED is >= PCT % of DISK
            (also sets the FULL threshold, default 90)
            -u 100 = containers whose used space has reached/exceeded the disk
  -s FIELD  sort by: disk, used, image, waste, use (largest first)
  -r        reverse the sort order (smallest first)
  -d        detailed sizes (2 decimals) + FREE, BASE and DELTAS columns
  -dd       exact sizes in bytes + FREE, BASE and DELTAS columns
  -h        show this help
Exit code: 0 = no problems, 1 = at least one container flagged, 2 = bad usage
EOF
  exit "${1:-0}"
}
die()   { echo "Error: $*" >&2; exit 2; }

while getopts "pw:u:s:rdh" opt; do
  case $opt in
    p) ONLY_PROBLEMS=1 ;;
    w) WASTE_PCT=$OPTARG ;;
    u) USE_PCT=$OPTARG; USE_FILTER=1 ;;
    s) SORT_BY=${OPTARG,,} ;;
    r) REVERSE=1 ;;
    d) DETAIL=$((DETAIL + 1)) ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

[[ $WASTE_PCT =~ ^[0-9]+$ ]] || die "-w needs a whole number, got '$WASTE_PCT'"
[[ $USE_PCT   =~ ^[0-9]+$ ]] || die "-u needs a whole number, got '$USE_PCT'"
case $SORT_BY in
  ""|disk|used|image|waste|use) ;;
  *) die "-s must be one of: disk, used, image, waste, use (got '$SORT_BY')" ;;
esac

# Human-readable size. DETAIL=0: 12G, DETAIL=1: 11.73G, DETAIL>=2: raw bytes
hr() {
  [[ $1 =~ ^[0-9]+$ ]] || { echo "$1"; return; }
  case $DETAIL in
    0) numfmt --to=iec "$1" ;;
    1) awk -v b="$1" 'BEGIN {
         split("B K M G T P E", u, " "); i = 1
         while (b >= 1024 && i < 7) { b /= 1024; i++ }
         if (i == 1) printf "%dB\n", b; else printf "%.2f%s\n", b, u[i] }' ;;
    *) echo "$1" ;;
  esac
}

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

# Column width for size columns depends on detail level
case $DETAIL in 0) W=7 ;; 1) W=9 ;; *) W=15 ;; esac
S="%${W}s"
if (( DETAIL )); then
  FMT="%-36s %-20s %-10s $S $S $S %5s $S $S $S %6s  %s"
  printf "$FMT\n" CTID HOSTNAME STATUS DISK USED FREE USE% IMAGE BASE DELTAS WASTE FLAGS
else
  FMT="%-36s %-20s %-10s $S $S %5s $S %6s  %s"
  printf "$FMT\n" CTID HOSTNAME STATUS DISK USED USE% IMAGE WASTE FLAGS
fi

problems=0
rows=()

while read -r ctid status private root hostname; do
  desc="$private/root.hdd/DiskDescriptor.xml"
  [ -f "$desc" ] || continue   # not a ploop container

  sectors=$(sed -n 's:.*<Disk_size>\([0-9]*\)</Disk_size>.*:\1:p' "$desc" | head -1)
  [ -n "$sectors" ] || continue
  virt=$((sectors * 512))
  (( virt > 0 )) || continue

  # Real allocated size of base image + any snapshot deltas
  image=$(du -c --block-size=1 "$private"/root.hdd/root.hds* 2>/dev/null | tail -1 | cut -f1)
  base=$(du --block-size=1 "$private"/root.hdd/root.hds 2>/dev/null | cut -f1)
  [[ $image =~ ^[0-9]+$ ]] || image=0
  [[ $base  =~ ^[0-9]+$ ]] || base=0
  deltas=$(( image - base ))
  snaps=$(( $(grep -c '<Shot>' "$desc") - 1 ))

  used="-"; free="-"; usepct="-"; waste="-"; pct="-"
  if [ "$status" = "running" ]; then
    read -r used free < <(df -B1 --output=used,avail "$root" 2>/dev/null | tail -1)
    [[ $used =~ ^[0-9]+$ ]] || { used="-"; free="-"; }
  fi

  flags=""
  (( image > virt )) && flags+="OVER_DISK "
  (( snaps > 0 ))    && flags+="SNAP($snaps) "
  if [[ $used =~ ^[0-9]+$ ]]; then
    usepct=$(( used * 100 / virt ))
    (( usepct >= USE_PCT )) && flags+="FULL(${usepct}%) "

    pct=$(( (image - used) * 100 / virt ))
    (( pct < 0 )) && pct=0
    waste="${pct}%"
    (( pct >= WASTE_PCT )) && flags+="WASTE(${pct}%) "
  fi

  # -u: only containers whose usage is at/over the threshold (needs a running CT)
  if (( USE_FILTER )); then
    [[ $usepct =~ ^[0-9]+$ ]] && (( usepct >= USE_PCT )) || continue
  fi

  [ -n "$flags" ] && problems=$((problems + 1))
  [ "$ONLY_PROBLEMS" = 1 ] && [ -z "$flags" ] && continue

  usecol="-"; [[ $usepct =~ ^[0-9]+$ ]] && usecol="${usepct}%"

  if (( DETAIL )); then
    printf -v line "$FMT" "$ctid" "${hostname:0:20}" "$status" \
      "$(hr "$virt")" "$(hr "$used")" "$(hr "$free")" "$usecol" \
      "$(hr "$image")" "$(hr "$base")" "$(hr "$deltas")" "$waste" "${flags:-OK}"
  else
    printf -v line "$FMT" "$ctid" "${hostname:0:20}" "$status" \
      "$(hr "$virt")" "$(hr "$used")" "$usecol" \
      "$(hr "$image")" "$waste" "${flags:-OK}"
  fi

  # Numeric sort key; unknown values (stopped CTs) get -1 so they sort last
  case $SORT_BY in
    disk)  key=$virt ;;
    image) key=$image ;;
    used)  [[ $used   =~ ^[0-9]+$ ]] && key=$used   || key=-1 ;;
    waste) [[ $pct    =~ ^[0-9]+$ ]] && key=$pct    || key=-1 ;;
    use)   [[ $usepct =~ ^[0-9]+$ ]] && key=$usepct || key=-1 ;;
    *)     key=0 ;;
  esac
  rows+=("$key"$'\t'"$line")
done < <(list_cts)

if (( ${#rows[@]} )); then
  if [ -z "$SORT_BY" ]; then
    printf '%s\n' "${rows[@]}" | cut -f2-
  else
    order="-k1,1nr"; (( REVERSE )) && order="-k1,1n"
    printf '%s\n' "${rows[@]}" | sort -s -t $'\t' $order | cut -f2-
  fi
fi

echo
summary="Containers flagged: $problems (waste threshold ${WASTE_PCT}%, full threshold ${USE_PCT}%)"
[ -n "$SORT_BY" ] && summary+=", sorted by ${SORT_BY^^}$( (( REVERSE )) && echo ' ascending' || echo ' descending')"
(( USE_FILTER )) && summary+=", showing only USED >= ${USE_PCT}% of DISK"
echo "$summary"
[ "$problems" -eq 0 ]
