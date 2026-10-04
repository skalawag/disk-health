# disk-health

SMART disk-health monitoring for [Omarchy](https://omarchy.org/). It runs an
hourly check of every drive, notifies you when one develops a problem, and has
a panel styled like Omarchy's disk speed test with temperature and lifespan
dials for each drive.

![Disk health panel showing two healthy drives](docs/screenshot.png)

## Install

Requires Omarchy (Arch Linux + the Omarchy shell). Your user must be in the
`wheel` group for the panel's "Check Now" button to work without a password.

    git clone <this repo> ~/projects/disk-health
    cd ~/projects/disk-health
    ./install.sh

The script asks for sudo for the root-side parts. Re-run it after pulling or
editing; it only changes what differs, and only asks for sudo when root-side
files changed. `./install.sh --user-only` skips the root side.

Then open **Menu → System → Disk Health**.

### What install.sh changes

| Where | What |
|-------|------|
| pacman | installs `smartmontools` (if missing) |
| `/usr/local/bin/disk-health-collect` | the collector |
| `/etc/systemd/system/disk-health.{service,timer}` | runs the collector at boot + hourly (timer enabled) |
| `/etc/polkit-1/rules.d/50-disk-health.rules` | lets `wheel` users start `disk-health.service` without a password |
| `/var/lib/disk-health/` | `status.json` (results) and `installed.sha256` (what was installed) |
| `~/.config/omarchy/plugins/skalawag.disk-health{,-monitor}/` | the two shell plugins (copied; Omarchy doesn't allow symlinked plugins), enabled in `shell.json` |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | one line for the menu entry (backup made first) |

### Uninstall

    ./uninstall.sh

Removes all of the above except `smartmontools` (`sudo pacman -R smartmontools`
if you don't need it), plus the alert state in `~/.local/state/disk-health/`.

## How it works

```
collector/   root side: disk-health-collect, systemd service + timer, polkit rule
plugins/     skalawag.disk-health (panel), skalawag.disk-health-monitor (alerts)
menu-entry.jsonc
tests/       fake smartctl + test runner
```

1. **Collector (root)**: `disk-health.timer` runs `disk-health-collect` 2 minutes
   after boot and hourly. It reads every drive with `smartctl --json` and writes
   `/var/lib/disk-health/status.json` (world-readable). Drives that are asleep are
   not woken; their previous reading is kept.
2. **Alert service**: `skalawag.disk-health-monitor` watches the status file and sends
   a notification when a drive gets a *new* problem, or when checks have stopped for
   over 26 hours. Numbers are ignored when comparing, so 57 → 58 °C doesn't re-alert,
   but growing reallocated sectors does. Clicking the notification opens the panel.
   Already-alerted problems are remembered in `~/.local/state/disk-health/alerted.json`.
3. **Panel**: `skalawag.disk-health`. Open it from the menu, a notification, or
   `omarchy-shell shell summon skalawag.disk-health`. Esc closes it; Enter or
   "Check Now" runs a fresh check.

Only the collector runs as root, and it only reads from drives. The desktop side
never needs privileges.

## Thresholds

Set in `collector/disk-health-collect`:

| Level    | Condition |
|----------|-----------|
| critical | SMART check failed; NVMe critical warning; NVMe media errors; pending or uncorrectable sectors; an attribute failing now; ≥90% of rated lifespan used; temperature at or above the drive's critical limit |
| warning  | reallocated sectors; spare capacity within 10% of its threshold; an attribute that failed in the past; ≥80% of rated lifespan used; temperature at or above the warning limit |

Temperature limits come from the drive when it reports them, otherwise 70/80 °C
(NVMe) and 55/60 °C (others). Drives that can't report SMART (some USB enclosures
hide it) show as "No SMART data" and never alert.

## Hardware coverage

Tested on real hardware with an NVMe SSD and a USB-attached SATA hard drive. SATA
SSD wear is read from `endurance_used` when smartctl provides it, otherwise from
common vendor attributes (231, 233, 177, 202); that path is exercised only by
reasoning, not by a real drive. RAID controllers, multiple NVMe namespaces, and
SAS drives are untested. Reports and fixtures from other hardware are welcome:
`sudo smartctl --json -a /dev/<drive>` output is what the tests need.

## Testing

    tests/run.sh                                  # collector against fake drives + plugin validation
    omarchy-shell diskhealth simulate             # fake alert → click → panel
    omarchy-shell shell summon skalawag.disk-health '{"statusPath":"/path/to/status.json"}'
    omarchy-shell diskhealth status               # what the alert service last saw
    systemctl status disk-health.timer

Note that edits to the alert service only take effect after `omarchy restart shell`
(install.sh does this for you); panel edits reload on save.

## License

MIT; see [LICENSE](LICENSE).
