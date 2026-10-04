#!/bin/bash
# Root-side setup for the skalawag.disk-health Omarchy plugin.
#
#   setup.sh status    ok | outdated | missing   (no root needed)
#   setup.sh install   install or update the system components (root)
#   setup.sh remove    remove them again (root)
#
# The panel runs install/remove through pkexec. A copy of this script is
# installed as /usr/local/bin/disk-health-uninstall, so the system components
# can still be removed after the plugin itself is gone:
#   sudo disk-health-uninstall
set -euo pipefail

src=$(dirname "$(readlink -f "$0")")
state=/var/lib/disk-health
# Checksums of the files as last installed. The polkit rules folder isn't
# readable without root, so "status" compares against this instead.
stamp=$state/installed.sha256

# installed path : file in this folder : mode
files=(
  "/usr/local/bin/disk-health-collect:disk-health-collect:755"
  "/usr/local/bin/disk-health-uninstall:setup.sh:755"
  "/etc/systemd/system/disk-health.service:disk-health.service:644"
  "/etc/systemd/system/disk-health.timer:disk-health.timer:644"
  "/etc/polkit-1/rules.d/50-disk-health.rules:50-disk-health.rules:644"
)

checksums() {
  local entry dest file mode
  for entry in "${files[@]}"; do
    IFS=: read -r dest file mode <<<"$entry"
    echo "$(sha256sum <"$src/$file" | cut -d' ' -f1) $mode $dest"
  done
}

need_root() {
  [[ $EUID -eq 0 ]] || { echo "setup.sh $1 must run as root (sudo or pkexec)" >&2; exit 1; }
}

status() {
  if [[ ! -r $stamp ]] || ! command -v smartctl >/dev/null; then
    echo missing
  elif ! systemctl is-enabled --quiet disk-health.timer 2>/dev/null; then
    echo missing
  elif [[ $(checksums) != "$(cat "$stamp")" ]]; then
    echo outdated
  else
    echo ok
  fi
}

install_components() {
  need_root install
  pacman -S --needed --noconfirm smartmontools
  local entry dest file mode
  for entry in "${files[@]}"; do
    IFS=: read -r dest file mode <<<"$entry"
    install -Dm"$mode" "$src/$file" "$dest"
  done
  mkdir -p "$state"
  checksums >"$stamp"
  chmod 644 "$stamp"
  systemctl daemon-reload
  systemctl enable --now disk-health.timer
  systemctl start disk-health.service
  echo "Disk health system components installed; first check done."
}

remove_components() {
  need_root remove
  systemctl disable --now disk-health.timer 2>/dev/null || true
  local entry dest
  for entry in "${files[@]}"; do
    dest=${entry%%:*}
    rm -f "$dest"
  done
  rm -rf "$state"
  systemctl daemon-reload
  echo "Disk health system components removed (smartmontools left installed)."
}

case ${1:-} in
  status) status ;;
  install) install_components ;;
  remove) remove_components ;;
  *)
    # Installed as disk-health-uninstall: no argument means remove.
    if [[ $(basename "$0") == disk-health-uninstall ]]; then remove_components
    else echo "Usage: $0 status|install|remove" >&2; exit 1; fi
    ;;
esac
