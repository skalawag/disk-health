#!/bin/bash
# Remove the deployed disk-health monitor (this repo stays). Asks for sudo for
# the root parts.
set -euo pipefail
plugin_dir="$HOME/.config/omarchy/plugins"
menu_file="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"

if [[ ${1:-} == --root-only ]]; then
  systemctl disable --now disk-health.timer 2>/dev/null || true
  rm -f /etc/systemd/system/disk-health.{service,timer} \
    /etc/polkit-1/rules.d/50-disk-health.rules /usr/local/bin/disk-health-collect
  rm -rf /var/lib/disk-health
  systemctl daemon-reload
  echo "Root parts removed (smartmontools left installed)."
  exit 0
fi

for id in skalawag.disk-health-monitor skalawag.disk-health; do
  omarchy plugin disable "$id" 2>/dev/null || true
  rm -rf "${plugin_dir:?}/$id"
done
if [[ -f $menu_file ]] && grep -q '"system.disk-health"' "$menu_file"; then
  cp "$menu_file" "$menu_file.bak.$(date +%s)"
  sed -i '/"system.disk-health"/d' "$menu_file"
fi
rm -rf "$HOME/.local/state/disk-health"
omarchy-shell -q shell rescanPlugins
echo "User parts removed."
sudo "$(readlink -f "$0")" --root-only
