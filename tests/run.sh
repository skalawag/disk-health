#!/bin/bash
# Run the collector against tests/fake-smartctl (a healthy NVMe, a USB drive
# hiding SMART, and a failing HDD) and check what it reports.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
export SMARTCTL="$here/fake-smartctl" DISK_HEALTH_OUT="$out/status.json" DISK_HEALTH_DRIVEDB="$out/none"
collect="$here/../system/disk-health-collect"
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

# Replay every saved report in tests/fixtures/ and check its "expect" block.
# To add a drive from a bug report: save its `disk-health-collect --report`
# output there and add an "expect" block (device → status, life_used_pct,
# note_contains).
for fixture in "$here"/fixtures/*.json; do
  name=$(basename "$fixture" .json)
  if ! REPORT="$fixture" SMARTCTL="$here/replay-smartctl" "$collect" >/dev/null 2>"$out/err"; then
    echo "FAIL $name: collector crashed: $(tail -1 "$out/err")"; fails=$((fails + 1)); continue
  fi
  result=$(jq -r --slurpfile f "$fixture" '
    . as $root
    | [ $f[0].expect | to_entries[] | .key as $dev | .value as $want
      | (first($root.drives[]? | select(.device == $dev)) // null) as $got
      | if $got == null then "\($dev): missing"
        else
          ( [ (if $want | has("status") then (if $got.status != $want.status then "status \($got.status) != \($want.status)" else empty end) else empty end),
              (if $want | has("life_used_pct") then (if $got.life_used_pct != $want.life_used_pct then "life_used_pct \($got.life_used_pct) != \($want.life_used_pct)" else empty end) else empty end),
              (if $want | has("note_contains") then (if ($got.note // "" | contains($want.note_contains)) | not then "note lacks \"\($want.note_contains)\"" else empty end) else empty end)
            ] | map("\($dev): " + .) | .[] )
        end
    ] | join("; ")' "$DISK_HEALTH_OUT")
  if [[ -z $result ]]; then echo "ok   fixture $name"; else echo "FAIL fixture $name: $result"; fails=$((fails + 1)); fi
done

if omarchy-plugin-validate "$here/.." >/dev/null 2>&1; then echo "ok   plugin manifest validates"
else echo "FAIL plugin manifest validates"; fails=$((fails + 1)); fi

for f in setup.sh menu.sh; do
  if bash -n "$here/../system/$f"; then echo "ok   system/$f parses"; else echo "FAIL system/$f parses"; fails=$((fails + 1)); fi
done

((fails == 0)) && echo "All tests passed." || { echo "$fails failed."; exit 1; }
