#!/usr/bin/env bash
#
# disk-report.sh - collect disk health with smartctl and post it to a Telegram
# channel: a JSON file (one flat row per disk, for n8n -> Google Sheets) with a
# short human-readable summary as the caption.
#
# Supports: SATA SSD, SATA HDD, SAS HDD/SSD, NVMe - direct or behind MegaRAID.
# Requires: smartctl >= 7.0 (JSON output), jq >= 1.6, curl, flock
#
# Usage:
#   disk-report.sh                  collect, send to Telegram, then update state
#   disk-report.sh --dry-run        print caption + JSON only (nothing sent, state untouched)
#   disk-report.sh --forget SERIAL  stop tracking a disk that was removed on purpose
#
# Row columns (15):
#   timestamp, server, device, model, serial, type, capacity_gb, health_pct,
#   written_tb, power_on_hours, temp_c, errors, unsafe_shutdowns, status, note
#
# Empty (null) means "not reported by this disk type", e.g. health_pct on HDDs.

set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ============================ configuration ============================
# Defaults below. Override any of them in main-config.conf (same folder as
# this script), or point CONFIG_FILE=/path/to/file at a different config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/main.conf}"

SERVER_NAME="$(hostname -s)"
BOT_TOKEN=""
CHAT_ID=""          # channel id, e.g. -1001234567890 (bots can't read other bots in groups)
FILE_PREFIX="smartctl-report"   # n8n can filter on this file name prefix

STATE_FILE="/var/lib/disk-report/state.json"
LOCK_FILE="/run/disk-report.lock"

# Leave empty to auto-detect with `smartctl --scan-open`.
# Or list devices manually as "device|type", for example:
#   DEVICES=("/dev/bus/0|megaraid,5" "/dev/bus/0|megaraid,6" "/dev/nvme0|nvme")
DEVICES=()

HEALTH_WARN=30     # SSD/NVMe health % at or below this -> WARNING
HEALTH_CRIT=10     # SSD/NVMe health % at or below this -> CRITICAL
TEMP_WARN_SSD=60   # °C, used when the drive doesn't report its own trip temperature
TEMP_WARN_HDD=50   # °C, same, for HDDs
TRIP_MARGIN=15     # if the drive reports drive_trip (SAS), warn at trip - margin

# Load config last, so it overrides the defaults above
if [[ -r $CONFIG_FILE ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" || { echo "[disk-report] ERROR: failed to load $CONFIG_FILE" >&2; exit 1; }
else
    echo "[disk-report] WARNING: config file not found: $CONFIG_FILE (using defaults)" >&2
fi

# ======================================================================

# Per-disk parser. Input: `smartctl -x -j` output. Output: {row, state}.
read -r -d '' JQ_DISK <<'JQ' || true
def attr($id): (.ata_smart_attributes.table // []) | map(select(.id == $id)) | .[0];
def raw($id):  attr($id) | if . == null then null else .raw.value end;
def norm($id): attr($id) | if . == null then null else .value end;
def devstat($page; $off):
  [ .ata_device_statistics.pages[]? | select(.number == $page)
    | .table[]? | select(.offset == $off and .flags.valid != false) | .value ] | .[0];
def firstnn: map(select(. != null)) | .[0];
def sumnn:   map(select(. != null)) | if length == 0 then null else add end;
def r2:      if . == null then null else (. * 100 + 0.5 | floor) / 100 end;
def left:    if . == null then null else ([100 - ., 0] | max) end;
def bit($n): (. / $n | floor) % 2 == 1;
def up($new; $old): $new != null and $old != null and $new > $old;

. as $d
| ($d.device.protocol // "") as $proto
| ($d.nvme_smart_health_information_log // {}) as $nv
| ($d.smartctl.exit_status // 0) as $rc

# --- identity ---
| (($d.model_name // ([$d.vendor, $d.product] | map(select(. != null)) | join(" ")))
    | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")) as $model
| ($d.serial_number // "") as $serial
| ($d.device.name + (if (($d.device.type // "") | test("megaraid"))
                     then ":" + ($d.device.type | sub("^sat\\+"; "")) else "" end)) as $dev
| (if   $proto == "NVMe"               then "NVMe"
   elif $d.rotation_rate == 0          then "SSD"
   elif ($d.rotation_rate // 0) > 0    then "HDD"
   elif ($d | devstat(7; 8)) != null   then "SSD"
   else "UNKNOWN" end) as $type

# --- capacity: namespace size, else NVMe controller total ---
| (($d.user_capacity.bytes // $d.nvme_total_capacity)
    | if . == null then null else (. / 1e9 + 0.5 | floor) end) as $cap

# --- health %: standardized wear value first, vendor attribute only as fallback ---
#     (232 is deliberately not in the list: OEM firmware reports it with
#      unrelated meanings, which is what made HDSentinel show 0%)
| (if   $proto == "NVMe" then ($nv.percentage_used | left)
   elif $proto == "SCSI" then ($d.scsi_percentage_used_endurance_indicator | left)
   elif $proto == "ATA" then
     ($d | devstat(7; 8)) as $used
     | if $used != null then ($used | left)
       elif $type == "SSD" then ([233, 231, 202, 177, 169] | map(. as $i | $d | norm($i)) | firstnn)
       else null end
   else null end) as $health

# --- total written, TB (decimal) ---
| (if $proto == "NVMe" then
     ($nv.data_units_written | if . == null then null else . * 512000 / 1e12 end)
   elif $proto == "ATA" then
     ($d | devstat(1; 24)) as $ls
     | if $ls != null then $ls * ($d.logical_block_size // 512) / 1e12
       else ($d | raw(241)) as $r
         | if   $r == null then null
           elif ($model | test("^INTEL"; "i")) then $r * 33554432 / 1e12   # Intel: 32 MiB units
           else $r * ($d.logical_block_size // 512) / 1e12 end
       end
   elif $proto == "SCSI" then
     ($d.scsi_error_counter_log.write.gigabytes_processed
       | if . == null then null else (tostring | tonumber) / 1000 end)
   else null end | r2) as $written

| ($d.power_on_time.hours // $nv.power_on_hours) as $hours
| ($d.temperature.current) as $temp

# --- error counters ---
| ($d | raw(197)) as $pend
| ($d | raw(198)) as $offunc
| ([$d.scsi_error_counter_log | (.read, .write, .verify) | .total_uncorrected_errors?] | sumnn) as $unc
| (if   $proto == "NVMe" then $nv.media_errors
   elif $proto == "ATA"  then ([5, 187, 197, 198] | map(. as $i | $d | raw($i)) | sumnn)
   elif $proto == "SCSI" then ([$d.scsi_grown_defect_list, $unc] | sumnn)
   else null end) as $errors

# --- which counters make up `errors`, for the note ---
| (if   $proto == "ATA" then
     [[5, "reallocated"], [187, "uncorrectable reads"], [197, "pending"], [198, "offline uncorrectable"]]
       | map(. as [$i, $n] | ($d | raw($i)) as $v | select(($v // 0) > 0) | "\($n) \($v)")
   elif $proto == "SCSI" then
     [ (if ($d.scsi_grown_defect_list // 0) > 0 then "grown defects \($d.scsi_grown_defect_list)" else empty end),
       (if ($unc // 0) > 0 then "uncorrected \($unc)" else empty end) ]
   elif $proto == "NVMe" and ($nv.media_errors // 0) > 0 then ["media errors \($nv.media_errors)"]
   else [] end | join(", ")) as $errdetail

# --- unsafe shutdowns (SAS disks have no such counter) ---
#     An unsafe shutdown is always followed by a power-on, so a candidate that is
#     higher than the power cycle count is counting something else. That happens
#     with 192 on many HDDs (HGST counts every head unload there, Seagate other
#     retract events), so such values are rejected instead of reported.
| ($d.power_cycle_count // ($d | raw(12))) as $cycles
| (if   $proto == "NVMe" then $nv.unsafe_shutdowns
   elif $proto == "ATA"  then
     ([174, (if $type == "SSD" and ($model | test("^SAMSUNG"; "i")) then 235 else empty end), 192]
       | map(. as $i | $d | raw($i))
       | map(select(. != null and ($cycles == null or . <= $cycles))) | .[0])
   else null end) as $unsafe

# --- previous run, for trend rules ---
| ($state[$serial] // {}) as $p
| (if   $d.temperature.drive_trip != null then $d.temperature.drive_trip - $trip_margin
   elif $type == "HDD" then $temp_hdd else $temp_ssd end) as $tlimit
| (up($unc; $p.unc)) as $unc_up

| [ (if $d.smart_status.passed == false or ($rc | bit(8)) then "SMART health check FAILED" else empty end),
    (if $rc | bit(16) then "prefail attribute at threshold" else empty end),
    (if $health != null and $health <= $hcrit then "health \($health)%" else empty end),
    (if ($pend // 0) > 0 then "pending sectors \($pend)" else empty end),
    (if ($offunc // 0) > 0 then "uncorrectable sectors \($offunc)" else empty end),
    (if ($nv.critical_warning // 0) != 0 then "NVMe critical_warning \($nv.critical_warning)" else empty end),
    (if $nv.available_spare != null and $nv.available_spare < ($nv.available_spare_threshold // 0)
       then "spare \($nv.available_spare)% below threshold" else empty end),
    (if $unc_up then "uncorrected errors +\($unc - $p.unc)" else empty end)
  ] as $crit

| [ (if $health != null and $health > $hcrit and $health <= $hwarn then "health \($health)%" else empty end),
    (if $type != "HDD" and ($errors // 0) > 0 then "errors \($errors) (\($errdetail))" else empty end),
    (if $type == "HDD" and up($errors; $p.errors) and ($unc_up | not)
       then "errors +\($errors - $p.errors) (now: \($errdetail))" else empty end),
    (if $temp != null and $temp > $tlimit then "temp \($temp)C (limit \($tlimit))" else empty end),
    (if up($unsafe; $p.unsafe) then "unsafe shutdowns +\($unsafe - $p.unsafe)" else empty end),
    (if up($nv.warning_temp_time; $p.wtt)
       then "over-temp minutes +\($nv.warning_temp_time - $p.wtt)" else empty end)
  ] as $warn

# errors that are known but not alarming (e.g. a stable old HDD defect) still
# get named in the note, so a non-zero `errors` is never unexplained
| (if ($errors // 0) > 0 and ([$crit[], $warn[]] | map(select(test("error|defect|sector"))) | length) == 0
   then ["errors \($errors) (\($errdetail)), \(if $p.errors == null then "first reading" else "unchanged" end)"]
   else [] end) as $info

| {
    row: {
      timestamp: $ts, server: $server, device: $dev, model: $model, serial: $serial,
      type: $type, capacity_gb: $cap, health_pct: $health, written_tb: $written,
      power_on_hours: $hours, temp_c: $temp, errors: $errors, unsafe_shutdowns: $unsafe,
      status: (if ($crit | length) > 0 then "CRITICAL"
               elif ($warn | length) > 0 then "WARNING" else "OK" end),
      note: ($crit + $warn + $info | join("; "))
    },
    state: { model: $model, type: $type, device: $dev,
             errors: $errors, unc: $unc, unsafe: $unsafe, wtt: $nv.warning_temp_time }
  }
JQ

# Combines per-disk results, adds rows for disks that disappeared, builds new state.
read -r -d '' JQ_FINAL <<'JQ' || true
. as $r
| ($old | to_entries | map(select(.key | IN($seen[]) | not))) as $missing
| {
    payload: (
      ($r | map(.row))
      + ($missing | map({
          timestamp: $ts, server: $server, device: .value.device, model: .value.model,
          serial: .key, type: .value.type, capacity_gb: null, health_pct: null,
          written_tb: null, power_on_hours: null, temp_c: null, errors: null,
          unsafe_shutdowns: null, status: "CRITICAL",
          note: "disk not detected (failed or removed); if removed on purpose run: --forget \(.key)"
        }))
    ),
    state: ($old + ($r | map({ key: .row.serial, value: .state }) | from_entries))
  }
JQ

# Human-readable caption (Telegram caption limit is 1024 characters).
read -r -d '' JQ_CAPTION <<'JQ' || true
def icon: if . == "CRITICAL" then "🔴" elif . == "WARNING" then "🟡" else "🟢" end;
([.[] | select(.status == "CRITICAL")] | length) as $c
| ([.[] | select(.status == "WARNING")] | length) as $w
| (length - $c - $w) as $o
| (if $c > 0 then "🔴" elif $w > 0 then "🟡" else "✅" end) + " " + $server + " — "
  + (if $c + $w == 0 then "\(length) disks OK"
     else [ (if $c > 0 then "\($c) CRITICAL" else empty end),
            (if $w > 0 then "\($w) WARNING" else empty end),
            (if $o > 0 then "\($o) OK" else empty end) ] | join(", ") end)
  + (map(select(.status != "OK")
         | "\n\(.status | icon) \(.serial) (\(.type // "?")): \(.note)") | join(""))
| if length > 1000 then .[0:990] + "\n…" else . end
JQ

log() { echo "[disk-report] $*" >&2; }

# true if $1 is a JSON object (jq 1.6 -e wrongly succeeds on empty input)
is_object() { [[ $(jq -r 'type' <<<"$1" 2>/dev/null) == object ]]; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

check_deps() {
    local dep ver
    for dep in smartctl jq curl flock mktemp; do
        command -v "$dep" >/dev/null 2>&1 || die "$dep is not installed"
    done
    ver=$(smartctl --version 2>/dev/null | awk 'NR==1 {print $2}')
    [[ ${ver%%.*} =~ ^[0-9]+$ ]] && (( ${ver%%.*} >= 7 )) \
        || die "smartctl >= 7.0 is required for JSON output (found: ${ver:-unknown})"
}

load_state() {
    mkdir -p "$(dirname "$STATE_FILE")" || die "cannot create $(dirname "$STATE_FILE")"
    if [[ -s $STATE_FILE ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
        STATE=$(cat "$STATE_FILE")
    else
        STATE='{}'
    fi
}

save_state() {
    local tmp="$STATE_FILE.tmp"
    printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$STATE_FILE" || die "cannot write $STATE_FILE"
}

forget() {
    local serial=${1:-}
    [[ -n $serial ]] || die "usage: $0 --forget SERIAL"
    load_state
    jq -e --arg s "$serial" 'has($s)' <<<"$STATE" >/dev/null || die "serial $serial is not tracked"
    save_state "$(jq --arg s "$serial" 'del(.[$s])' <<<"$STATE")"
    log "stopped tracking $serial"
}

send_telegram() {
    local payload=$1 caption=$2 silent=$3 tmp fname resp
    tmp=$(mktemp) || return 1
    printf '%s\n' "$payload" > "$tmp"
    fname="${FILE_PREFIX}_${SERVER_NAME}_$(date +%Y%m%d-%H%M%S).json"

    resp=$(curl -sS --retry 3 --retry-delay 5 --max-time 60 \
        -F "chat_id=$CHAT_ID" \
        -F "caption=$caption" \
        -F "disable_notification=$silent" \
        -F "document=@$tmp;filename=$fname;type=application/json" \
        "https://api.telegram.org/bot$BOT_TOKEN/sendDocument")
    rm -f "$tmp"

    if [[ $(jq -r '.ok // false' <<<"$resp" 2>/dev/null) == "true" ]]; then
        return 0
    fi
    log "Telegram API: $(jq -r '.description // empty' <<<"$resp" 2>/dev/null || echo "$resp")"
    return 1
}

discover() {
    if (( ${#DEVICES[@]} == 0 )); then
        mapfile -t DEVICES < <(smartctl --scan-open -j 2>/dev/null \
            | jq -r '.devices[]? | "\(.name)|\(.type // "")"')
    fi
    (( ${#DEVICES[@]} > 0 )) || die "no devices found (set DEVICES manually in the config)"
}

# Runs smartctl with mode $1 (-x or -a) for the current device (uses the
# caller's args/name) and sets json, src (exit code) and stray. smartctl 7.2
# can print plain text before its JSON, even on the same line as the opening
# brace (e.g. "  Pending defect count:{" on some SAS SSDs). smartctl prints its
# JSON as one block at the end, so everything before the first "{" is dropped.
read_smart() {
    local raw
    raw=$(smartctl "$1" "${args[@]}" "$name" 2>/dev/null)
    src=$?
    if [[ $raw == *"{"* ]]; then
        json="{${raw#*\{}"
        stray=$(tr -s '[:space:]' ' ' <<<"${raw%%\{*}" | sed 's/^ //; s/ $//')
    else
        json=""
        stray=""
    fi
}

collect() {
    local entry name dtype json rc src stray serial out
    local -a args
    declare -gA SEEN=()
    RESULTS=""

    for entry in "${DEVICES[@]}"; do
        name=${entry%%|*}
        dtype=""
        [[ $entry == *"|"* ]] && dtype=${entry#*|}

        args=(-j)
        [[ -n $dtype ]] && args+=(-d "$dtype")
        read_smart -x
        # Some disks make smartctl -x return empty or broken JSON (often a newer
        # model than the smartctl version knows); -a reads fewer logs and may work.
        if ! is_object "$json"; then
            read_smart -a
            if ! is_object "$json"; then
                log "skip $entry: smartctl returned no valid JSON (exit $src);" \
                    "check with: smartctl -x -j ${dtype:+-d $dtype }$name"
                continue
            fi
            log "note $entry: smartctl -x output unusable, used -a instead"
        fi
        [[ -n $stray ]] && log "note $entry: ignored text smartctl printed before its JSON: \"${stray:0:80}\""

        rc=$(jq -r '.smartctl.exit_status // empty' <<<"$json")
        [[ $rc =~ ^[0-9]+$ ]] || rc=$src
        if (( rc & 3 )); then
            log "skip $entry: smartctl could not read it (exit $rc):" \
                "$(jq -r '[.smartctl.messages[]?.string] | join("; ")' <<<"$json")"
            continue
        fi
        if ! jq -e '(.smart_status != null) or (.nvme_smart_health_information_log != null)' \
                <<<"$json" >/dev/null 2>&1; then
            log "skip $entry: no SMART data (RAID virtual drive?)"
            continue
        fi

        serial=$(jq -r '.serial_number // empty' <<<"$json")
        if [[ -z $serial ]]; then
            log "skip $entry: no serial number"
            continue
        fi
        [[ -n ${SEEN[$serial]:-} ]] && continue   # same disk reached via two paths
        SEEN[$serial]=1

        if ! out=$(jq -c \
                --arg ts "$TS" --arg server "$SERVER_NAME" --argjson state "$STATE" \
                --argjson hwarn "$HEALTH_WARN" --argjson hcrit "$HEALTH_CRIT" \
                --argjson temp_ssd "$TEMP_WARN_SSD" --argjson temp_hdd "$TEMP_WARN_HDD" \
                --argjson trip_margin "$TRIP_MARGIN" \
                "$JQ_DISK" <<<"$json"); then
            log "skip $entry: failed to parse smartctl output"
            unset "SEEN[$serial]"
            continue
        fi
        RESULTS+="$out"$'\n'
    done
}

main() {
    local dry_run=0 combined payload new_state seen_json rows caption silent

    case "${1:-}" in
        "")          ;;
        --dry-run)   dry_run=1 ;;
        --forget)    command -v jq >/dev/null || die "jq is not installed"; forget "${2:-}"; exit 0 ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage; exit 1 ;;
    esac

    check_deps
    exec 9>"$LOCK_FILE" || die "cannot open $LOCK_FILE"
    flock -n 9 || die "another run is still in progress"

    if (( ! dry_run )) && [[ -z $BOT_TOKEN || -z $CHAT_ID ]]; then
        die "BOT_TOKEN and CHAT_ID must be set (use --dry-run to test)"
    fi

    TS=$(date -Iseconds)
    load_state
    discover
    collect

    seen_json=$(printf '%s\n' "${!SEEN[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
    combined=$(printf '%s' "$RESULTS" | jq -sc \
        --argjson old "$STATE" --argjson seen "$seen_json" \
        --arg ts "$TS" --arg server "$SERVER_NAME" "$JQ_FINAL") \
        || die "failed to build payload"

    payload=$(jq -c '.payload' <<<"$combined")
    new_state=$(jq '.state' <<<"$combined")
    rows=$(jq 'length' <<<"$payload")
    (( rows > 0 )) || die "no disks could be read"

    caption=$(jq -r --arg server "$SERVER_NAME" "$JQ_CAPTION" <<<"$payload")
    # all OK -> silent message, so the channel only pings when something is wrong
    silent=$(jq -r 'if all(.[]; .status == "OK") then "true" else "false" end' <<<"$payload")

    if (( dry_run )); then
        printf '%s\n\n' "$caption"
        jq . <<<"$payload"
        log "dry run: $rows rows, nothing sent, state not updated"
        exit 0
    fi

    if send_telegram "$payload" "$caption" "$silent"; then
        save_state "$new_state"
        log "sent $rows rows to Telegram"
    else
        die "sending to Telegram failed; state not updated, changes will be reported next run"
    fi
}

main "$@"