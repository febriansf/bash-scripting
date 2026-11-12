# Drive Audit CLI

This folder contains shell scripts for checking the health and status of
physical drives on a Linux system.

## Contents

### `check-smartctl.sh`

Collects SMART information for detected, non-removable physical disks and
writes the results to `smartctl-results.txt` in the current working directory.

The script:

- Checks that `smartctl` is installed.
- Finds physical disks with `lsblk`.
- Skips removable devices, partitions, loop devices, and optical drives.
- Tries the default `smartctl` device mode, then `sat` and `scsi` fallbacks.
- Detects common MegaRAID, PERC, and LSI controllers and scans physical disks
  behind them with `megaraid,N`.

Install the required tools on Debian or Ubuntu with:

```bash
sudo apt install smartmontools util-linux pciutils
```

Run it from the directory where the report should be saved:

```bash
cd drive-audit-cli
sudo bash check-smartctl.sh
```

Some devices require root access for SMART data. A disk behind an unsupported
RAID controller may still be inaccessible and will be reported in the output.

### `check-sentinel.sh`

Downloads and runs the Linux command-line version of HD Sentinel, then prints a
table containing detected drive details such as:

- Device and model
- Serial number and size
- Power-on time
- Estimated lifetime
- Total written data
- Health and performance percentages

The HD Sentinel binary and downloaded archive are stored in `/tmp/hddsentinel`.
Raw output is saved to `/tmp/hds_raw.txt` for inspection.

Required commands are `wget`, `unzip`, and `awk`. Run it as root when possible
so HD Sentinel can access drive information:

```bash
cd drive-audit-cli
sudo bash check-sentinel.sh
```

The script downloads HD Sentinel from the vendor website on its first run.
Review the downloaded tool and network policy before running it in production.

## Notes

- Both scripts inspect the host's local storage; run them on the machine whose
  drives need to be audited.
- Reports can contain serial numbers and other hardware identifiers. Handle
  generated output accordingly.
- The scripts are diagnostic tools and do not modify drive contents.
