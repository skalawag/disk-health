#!/bin/bash
# Remove the plugin, its system components, menu entry and state. The repo
# stays. (Users who installed from the marketplace: press "Remove System
# Components" in the panel, then `omarchy plugin remove io.github.skalawag.disk-health`.)
set -euo pipefail
repo=$(dirname "$(readlink -f "$0")")
id=$(jq -r .id "$repo/manifest.json")

if [[ $("$repo/system/setup.sh" status) != missing ]]; then
  sudo "$repo/system/setup.sh" remove
fi
"$repo/system/menu.sh" remove
omarchy plugin disable "$id" 2>/dev/null || true
rm -rf "${HOME:?}/.config/omarchy/plugins/$id" "$HOME/.local/state/disk-health"
omarchy-shell -q shell rescanPlugins
echo "Removed $id."
