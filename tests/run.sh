#!/bin/bash
# Run the collector against tests/fake-smartctl (a healthy NVMe, a USB drive
# hiding SMART, and a failing HDD) and check what it reports.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
export SMARTCTL="$here/fake-smartctl" DISK_HEALTH_OUT="$out/status.json"
collect="$here/../collector/disk-health-collect"
fails=0

check() { # description, jq expression that must be true
  if jq -e "$2" "$DISK_HEALTH_OUT" >/dev/null; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

REALLOC=12 "$collect" >/dev/null
check "overall status is critical"          '.status == "critical"'
check "NVMe is ok with its figures"         '.drives[0] | .status == "ok" and .temperature_c == 41 and .life_used_pct == 2'
check "USB drive without SMART is unavailable, with a note" '.drives[1] | .status == "unavailable" and (.note | test("USB bridge"))'
check "HDD pending sectors are critical"    '.drives[2].problems | any(.level == "critical" and (.text | test("3 sectors pending")))'
check "HDD reallocated sectors warn"        '.drives[2].problems | any(.level == "warning" and .text == "12 reallocated sectors")'
check "HDD temperature over warning limit"  '.drives[2].problems | any(.text == "Temperature high (57°C)")'

REALLOC=15 "$collect" >/dev/null
check "growth since last check is reported" '.drives[2].problems | any(.text == "15 reallocated sectors (+3 since last check)")'

if [[ $(stat -c %a "$DISK_HEALTH_OUT") == 644 ]]; then echo "ok   status file is world-readable"
else echo "FAIL status file is world-readable"; fails=$((fails + 1)); fi

for p in "$here"/../plugins/*/; do
  if omarchy-plugin-validate "$p" >/dev/null 2>&1; then echo "ok   plugin $(basename "$p") validates"
  else echo "FAIL plugin $(basename "$p") validates"; fails=$((fails + 1)); fi
done

((fails == 0)) && echo "All tests passed." || { echo "$fails failed."; exit 1; }
