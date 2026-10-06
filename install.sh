#!/bin/bash
# Developer install: deploy this working copy (including uncommitted edits) as
# the io.github.skalawag.disk-health plugin, then bring the system components and menu
# entry up to date. Safe to re-run.
#
# Regular users don't need this: `omarchy plugin add <repo-url> --enable`, then
# open the panel and press "Set Up".
set -euo pipefail
repo=$(dirname "$(readlink -f "$0")")
id=$(jq -r .id "$repo/manifest.json")
target="$HOME/.config/omarchy/plugins/$id"

if [[ -d $target/.git ]]; then
  echo "$target is a git clone (installed with omarchy plugin add)." >&2
  echo "Update it with: omarchy plugin update $id   — or remove it to use this dev install." >&2
  exit 1
fi

omarchy-plugin-validate "$repo" >/dev/null
new=0; [[ -d $target ]] || new=1
# Content-compared; only report files actually copied or deleted.
changes=$(rsync -ai --checksum --delete --exclude .git "$repo/" "$target/" | grep -E '^(>f|\*deleting)' || true)
[[ -n $changes ]] && echo "Updated plugin $id"

if omarchy-shell shell ping >/dev/null 2>&1; then
  ((new)) && omarchy-shell shell rescanPlugins >/dev/null && sleep 1
  omarchy plugin list --json | jq -e --arg id "$id" 'any(.[]; .id == $id and .enabled)' >/dev/null \
    || omarchy plugin enable "$id"
fi

case $("$repo/system/setup.sh" status) in
  ok) echo "System components up to date." ;;
  *) echo "Installing system components with sudo…"; sudo "$repo/system/setup.sh" install ;;
esac
"$repo/system/menu.sh" add
omarchy-shell -q diskhealth recheck
echo "Done."
