# disk-health

SMART disk-health monitoring for an [Omarchy](https://omarchy.org/) desktop: an
hourly root-side check, a notification when a drive develops a problem, and a
panel (styled like Omarchy's disk speed test) with per-drive dials and details.

```
collector/  root side: disk-health-collect, systemd service + timer, polkit rule
plugins/    Omarchy shell plugins: mark.disk-health (panel), mark.disk-health-monitor (alerts)
menu-entry.jsonc   Menu → System → Disk Health
tests/      fake smartctl + test runner
```

## Install / update

This repo is the source of truth. Edit here, then:

    ./install.sh

It copies the plugins into `~/.config/omarchy/plugins/` (Omarchy doesn't allow
symlinked plugins), adds or updates the menu entry, enables the plugins, and
restarts the shell only if the alert service changed. It asks for sudo only
when the root-side files differ from what was last installed (tracked in
`/var/lib/disk-health/installed.sha256`). `./install.sh --user-only` skips the root side.

Remove everything (the repo stays): `./uninstall.sh`

## How it works

1. **Collector (root)**: `disk-health.timer` runs `/usr/local/bin/disk-health-collect`
   2 min after boot and hourly. It reads SMART data with `smartctl --json` and writes
   `/var/lib/disk-health/status.json`. Sleeping drives aren't woken; their previous
   reading is kept.
2. **Alert service**: `mark.disk-health-monitor` watches the status file and sends a
   notification when a drive gets a *new* problem (numbers are ignored when comparing,
   so 57 → 58 °C doesn't re-alert, but growing reallocated sectors does), or when checks
   stop for over 26 hours. Clicking it opens the panel. Already-alerted problems are kept
   in `~/.local/state/disk-health/alerted.json`.
3. **Panel**: `mark.disk-health`. Open from Menu → System → Disk Health, a notification,
   or `omarchy-shell shell summon mark.disk-health`. Esc closes; Enter or "Check Now"
   re-runs the check (the polkit rule allows this without a password).

## Thresholds (in `collector/disk-health-collect`)

| Level    | Condition |
|----------|-----------|
| critical | SMART check failed; NVMe critical warning; NVMe media errors; pending or uncorrectable sectors; attribute failing now; ≥90% of lifespan used; temperature at/above the drive's critical limit |
| warning  | reallocated sectors; spare capacity within 10% of its threshold; attribute failed in the past; ≥80% of lifespan used; temperature at/above the warning limit |

Drives that can't report SMART (some USB enclosures) show as "No SMART data" and never alert.

## Testing

    tests/run.sh                                   # collector against fake drives + plugin validation
    omarchy-shell diskhealth simulate              # fake alert → click → panel
    omarchy-shell shell summon mark.disk-health '{"statusPath":"/path/to/status.json"}'
    omarchy-shell diskhealth status                # what the alert service last saw
    systemctl status disk-health.timer
