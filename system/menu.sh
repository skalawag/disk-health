#!/bin/bash
# Add or remove the Menu → System → Disk Health entry (runs as the user).
#
#   menu.sh add      add the entry, or bring an existing one up to date
#   menu.sh remove   take it out again
#
# The entry hides itself if the plugin folder is gone, so a leftover line is
# harmless.
set -euo pipefail

menu_file="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
entry='  "system.disk-health": {"icon":"󰋊","label":"Disk Health","aliases":["disk-health","smart"],"description":"SMART status of every drive","when":"[[ -d ~/.config/omarchy/plugins/io.github.skalawag.disk-health ]]","action":"omarchy-shell shell summon io.github.skalawag.disk-health"},'

case ${1:-} in
  add)
    mkdir -p "$(dirname "$menu_file")"
    [[ -f $menu_file ]] || printf '{\n}\n' >"$menu_file"
    if grep -qF "$entry" "$menu_file"; then exit 0; fi
    cp "$menu_file" "$menu_file.bak.$(date +%s)"
    python3 - "$menu_file" "$entry" <<'PY'
import sys
path, entry = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
kept = [l for l in lines if '"system.disk-health"' not in l]
text = "\n".join(kept)
end = text.rstrip().rfind("}")
open(path, "w").write(text[:end] + entry + "\n" + text[end:])
PY
    echo "Added Menu → System → Disk Health"
    ;;
  remove)
    [[ -f $menu_file ]] && grep -q '"system.disk-health"' "$menu_file" || exit 0
    cp "$menu_file" "$menu_file.bak.$(date +%s)"
    sed -i '/"system.disk-health"/d' "$menu_file"
    echo "Removed the Disk Health menu entry"
    ;;
  *) echo "Usage: $0 add|remove" >&2; exit 1 ;;
esac
