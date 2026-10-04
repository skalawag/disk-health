#!/bin/bash
# Deploy the disk-health monitor from this repo. Safe to re-run after any edit:
# it only touches what changed.
#
#   ./install.sh              user parts, then root parts (sudo) if they differ
#   ./install.sh --user-only  plugins + menu entry only
#   (internal) --root-only    root parts; install.sh runs this through sudo
set -euo pipefail
repo=$(dirname "$(readlink -f "$0")")
mode=${1:-all}

plugin_dir="$HOME/.config/omarchy/plugins"
menu_file="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
plugins=(mark.disk-health mark.disk-health-monitor)

# Checksums of the repo files as last installed. The polkit rules folder isn't
# readable without root, so "is root up to date?" compares against this.
stamp=/var/lib/disk-health/installed.sha256

# installed path ← repo path, for the root-owned files
root_files=(
  "/usr/local/bin/disk-health-collect:collector/disk-health-collect:755"
  "/etc/systemd/system/disk-health.service:collector/disk-health.service:644"
  "/etc/systemd/system/disk-health.timer:collector/disk-health.timer:644"
  "/etc/polkit-1/rules.d/50-disk-health.rules:collector/50-disk-health.rules:644"
)

install_root() {
  [[ $EUID -eq 0 ]] || { echo "--root-only must run as root" >&2; exit 1; }
  mkdir -p "$(dirname "$stamp")"
  pacman -S --needed --noconfirm smartmontools
  for entry in "${root_files[@]}"; do
    IFS=: read -r dest src perm <<<"$entry"
    install -Dm"$perm" "$repo/$src" "$dest"
  done
  repo_checksums > "$stamp"
  chmod 644 "$stamp"
  systemctl daemon-reload
  systemctl enable --now disk-health.timer
  systemctl start disk-health.service
  echo "Root parts installed; disk check ran."
}

repo_checksums() {
  local entry dest src perm
  for entry in "${root_files[@]}"; do
    IFS=: read -r dest src perm <<<"$entry"
    echo "$(sha256sum < "$repo/$src" | cut -d' ' -f1) $perm $dest"
  done
}

root_up_to_date() {
  command -v smartctl >/dev/null || return 1
  systemctl is-enabled --quiet disk-health.timer 2>/dev/null || return 1
  [[ -r $stamp ]] && [[ $(repo_checksums) == "$(cat "$stamp")" ]]
}

install_user() {
  local restart=0 rescan=0 id
  for id in "${plugins[@]}"; do
    [[ -d $plugin_dir/$id ]] || rescan=1
    # Compare by content; keep only itemized lines for files actually sent
    # (">f…") or deleted, not timestamp-only touches.
    changes=$(rsync -ai --checksum --delete "$repo/plugins/$id/" "$plugin_dir/$id/" | grep -E '^(>f|\*deleting)' || true)
    if [[ -n $changes ]]; then
      echo "Updated plugin $id"
      # Kept-loaded services don't fully hot-reload; panels do.
      [[ $id == mark.disk-health-monitor ]] && restart=1
    fi
  done

  if ! grep -q '"system.disk-health"' "$menu_file" 2>/dev/null; then
    mkdir -p "$(dirname "$menu_file")"
    if [[ -f $menu_file ]]; then cp "$menu_file" "$menu_file.bak.$(date +%s)"; else printf '{\n}\n' > "$menu_file"; fi
    python3 - "$menu_file" "$repo/menu-entry.jsonc" <<'PY'
import sys
path, entry = sys.argv[1], open(sys.argv[2]).read().rstrip("\n") + "\n"
text = open(path).read()
end = text.rstrip().rfind("}")
open(path, "w").write(text[:end] + entry + text[end:])
PY
    echo "Added Menu → System → Disk Health"
  else
    # Keep the existing line in sync with the repo's.
    python3 - "$menu_file" "$repo/menu-entry.jsonc" <<'PY'
import sys
path, entry = sys.argv[1], open(sys.argv[2]).read().strip()
lines = open(path).read().split("\n")
new = [("  " + entry) if '"system.disk-health"' in l else l for l in lines]
if new != lines:
    open(path, "w").write("\n".join(new))
    print("Updated menu entry")
PY
  fi

  if omarchy-shell shell ping >/dev/null 2>&1; then
    ((rescan)) && omarchy-shell shell rescanPlugins >/dev/null && sleep 1
    for id in "${plugins[@]}"; do
      omarchy plugin list --json | jq -e --arg id "$id" 'any(.[]; .id == $id and .enabled)' >/dev/null \
        || omarchy plugin enable "$id"
    done
    if ((restart)); then
      echo "Restarting the Omarchy shell to load the new alert service"
      omarchy restart shell >/dev/null 2>&1
    fi
  fi
}

case $mode in
  --root-only) install_root ;;
  --user-only) install_user ;;
  all)
    install_user
    if root_up_to_date; then
      echo "Root parts already up to date."
    else
      echo "Root parts changed; installing with sudo…"
      sudo "$repo/install.sh" --root-only
    fi
    echo "Done."
    ;;
  *) echo "Usage: $0 [--user-only]" >&2; exit 1 ;;
esac
