# bot_smartctl.sh — Disk health reports to Telegram

Collects disk health with `smartctl` and posts it to a Telegram channel as a JSON file (one row per disk), with a short summary as the caption. The JSON is meant to be picked up by n8n and written to Google Sheets.

Supports SATA SSD/HDD, SAS HDD/SSD and NVMe, attached directly or behind a MegaRAID controller.

The caption looks like this:

```
🟡 VPS-ID-2 — 1 WARNING, 3 OK
🟡 S4XXNF0M123456 (SSD): temp 64C (limit 60)
```

When all disks are OK, the message is sent silently, so the channel only notifies you when something is wrong.

## Requirements

- Linux, run as **root** (smartctl needs raw disk access)
- `smartctl` 7.0 or newer (for JSON output)
- `jq` 1.6 or newer
- `curl`, `flock`
- A Telegram bot that is an **admin** of the target channel

Install the dependencies:

```bash
# RHEL / AlmaLinux / Rocky / CentOS
dnf install -y smartmontools jq curl util-linux

# Debian / Ubuntu
apt install -y smartmontools jq curl util-linux
```

Check the smartctl version with `smartctl --version`.

## Setup

**1. Clone the repo**

```bash
git clone https://github.com/<you>/<repo>.git /opt/disk-report
cd /opt/disk-report
```

**2. Create your config**

```bash
cp main.conf.example main.conf
chown root:root bot_smartctl.sh main.conf
chmod 700 bot_smartctl.sh
chmod 600 main.conf
```

Edit `main.conf`:

```bash
SERVER_NAME="VPS-ID-2"            # shown in the caption and the JSON
BOT_TOKEN="123456:ABC-your-token" # from @BotFather
CHAT_ID="-1001234567890"          # your channel ID
FILE_PREFIX="smartctl-report"     # file name prefix, n8n can filter on it
```

`main.conf` contains your bot token. It is listed in `.gitignore`. Never commit it.

**3. Optional settings**

Any default in the script can be overridden in `main.conf`:

```bash
# List devices manually instead of auto-detecting (format: "device|type")
DEVICES=("/dev/bus/0|megaraid,5" "/dev/bus/0|megaraid,6" "/dev/nvme0|nvme")

HEALTH_WARN=30     # SSD/NVMe health % at or below this -> WARNING
HEALTH_CRIT=10     # SSD/NVMe health % at or below this -> CRITICAL
TEMP_WARN_SSD=60   # °C
TEMP_WARN_HDD=50   # °C
```

To use a config file in another location:

```bash
CONFIG_FILE=/etc/disk-report.conf ./bot_smartctl.sh
```

## Usage

**Test first** (prints the caption and JSON, sends nothing):

```bash
./bot_smartctl.sh --dry-run
```

**Send a report:**

```bash
./bot_smartctl.sh
```

**Stop tracking a disk you removed on purpose** (otherwise it is reported as CRITICAL "disk not detected" on every run):

```bash
./bot_smartctl.sh --forget SERIALNUMBER
```

**Show help:**

```bash
./bot_smartctl.sh --help
```

## Run automatically with cron

**1. Create a log file**

```bash
touch /var/log/disk-report.log
chmod 600 /var/log/disk-report.log
```

**2. Add the cron job**

Create `/etc/cron.d/disk-report`:

```cron
# Disk health report to Telegram, every day at 07:00
SHELL=/bin/bash
0 7 * * * root /opt/disk-report/bot_smartctl.sh >> /var/log/disk-report.log 2>&1
```

Files in `/etc/cron.d/` need the user (`root`) before the command and must end with a newline.

Alternatively, use root's crontab with `crontab -e` (as root). There, you leave out the user:

```cron
0 7 * * * /opt/disk-report/bot_smartctl.sh >> /var/log/disk-report.log 2>&1
```

**Other schedules:**

| Schedule | Cron expression |
|---|---|
| Every 6 hours | `0 */6 * * *` |
| Twice a day (07:00 and 19:00) | `0 7,19 * * *` |
| Every Monday at 08:00 | `0 8 * * 1` |

The script uses a lock file, so if one run is still going when the next starts, the second one exits instead of running twice.

**3. Check that it works**

```bash
tail -f /var/log/disk-report.log
```

A successful run logs `[disk-report] sent N rows to Telegram`.

**Optional: rotate the log**

Create `/etc/logrotate.d/disk-report`:

```
/var/log/disk-report.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
```

## Output

Each JSON row has these columns:

| Column | Meaning |
|---|---|
| `timestamp` | Time of the run |
| `server` | `SERVER_NAME` from the config |
| `device` | Device path (with MegaRAID slot if applicable) |
| `model`, `serial`, `type` | Disk identity; type is SSD, HDD, NVMe or UNKNOWN |
| `capacity_gb` | Capacity in GB |
| `health_pct` | Remaining life % (SSD/NVMe only) |
| `written_tb` | Total data written in TB |
| `power_on_hours` | Hours powered on |
| `temp_c` | Current temperature |
| `errors` | Sum of error counters (reallocated, pending, media errors, etc.) |
| `unsafe_shutdowns` | Unsafe shutdown count (not available on SAS) |
| `status` | OK, WARNING or CRITICAL |
| `note` | Why the status is not OK |

An empty value means that disk type doesn't report it, for example `health_pct` on HDDs.

The script keeps the previous readings in `/var/lib/disk-report/state.json` to detect changes (new errors, new unsafe shutdowns, missing disks). If a Telegram send fails, the state is not updated, so the changes are reported again on the next run.

## Troubleshooting

**"BOT_TOKEN and CHAT_ID must be set"**: the config file wasn't found or is empty. The script looks for `main.conf` in its own folder. Check the warning line at the top of the output.

**"Telegram API: Bad Request: chat not found"**: wrong `CHAT_ID`, or the bot isn't a member of the channel. Add the bot as an admin of the channel.

**"Telegram API: Unauthorized"**: wrong or revoked `BOT_TOKEN`.

**"no devices found"**: auto-detection found nothing, often behind hardware RAID. Run `smartctl --scan-open` to see what's available and set `DEVICES` manually in `main.conf`.

**"skip ...: no SMART data (RAID virtual drive?)"**: this is a RAID logical volume, not a physical disk. Normal; physical disks behind MegaRAID are read through `megaraid,N` entries.

**Works manually, but not from cron**: check `/var/log/disk-report.log`. Make sure the cron job runs as root and uses the full path to the script.

**n8n doesn't receive the messages**: a bot can only have one webhook, so only one n8n workflow with a Telegram Trigger can be active per bot. Check with `https://api.telegram.org/bot<TOKEN>/getWebhookInfo`.

## Security

- Keep `main.conf` at `chmod 600`, owned by root. The script runs as root and loads this file as bash code.
- If your bot token was ever committed to Git, revoke it in @BotFather and create a new one. Removing the file in a later commit doesn't remove it from history.