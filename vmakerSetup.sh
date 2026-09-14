#!/usr/bin/env bash
set -euo pipefail

# vmakerSetup.sh — install and configure vmaker + the vmaker.vms Omarchy plugin
#
# Does everything needed to create and manage QEMU/KVM VMs on Arch/Omarchy:
#   1. Installs QEMU, libvirt, and their dependencies (pacman, via sudo)
#   2. Enables and starts libvirtd and the default NAT network
#   3. Adds the current user to the libvirt and kvm groups
#   4. Configures UFW so VMs can reach the internet (forward + DHCP/DNS)
#   5. Grants the libvirt qemu process access to ~/Myvms (VM disks)
#   6. Installs the vmaker script to ~/.local/bin
#   7. Installs the vmaker.vms plugin and enables it in the Omarchy bar
#
# Usage:
#   ./vmakerSetup.sh              # install for real
#   ./vmakerSetup.sh --dry-run    # print what would happen, change nothing
#
# You will be prompted for your sudo password.

# ---------- helpers ----------
err()  { echo -e "\033[1;31merror:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m»\033[0m $*"; }
warn() { echo -e "\033[1;33m!\033[0m $*" >&2; }

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Run a command for real, or just print it in a dry run.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] $*"
  else
    "$@"
  fi
}

# Directory this script lives in (the VMaker repo root). The plugin files
# (manifest.json, *.qml, lib/) sit alongside this script, so the whole repo is
# also a valid plugin dir for `omarchy plugin add`.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The user we are installing for (also correct when run via sudo).
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_USER="${TARGET_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
MYVMS="$TARGET_HOME/Myvms"

# Packages needed by vmaker and the plugin.
PACKAGES=(qemu-desktop libvirt virt-install virt-manager virt-viewer \
          edk2-ovmf dnsmasq swtpm iptables-nft libosinfo)

# ---------- guards ----------
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  err "run this script as your normal user (not via sudo) — it asks for sudo itself when needed"
fi
command -v pacman >/dev/null 2>&1 || err "this script needs pacman (Arch/Omarchy)"
command -v sudo   >/dev/null 2>&1 || err "this script needs sudo"
[[ -n "$TARGET_HOME" ]] || err "could not resolve a home directory for '$TARGET_USER'"
[[ -f "$SCRIPT_DIR/vmaker" ]] || err "vmaker script not found next to $0"
[[ -f "$SCRIPT_DIR/manifest.json" ]] || err "plugin manifest.json not found next to $0"

echo ""
info "vmakerSetup — installing vmaker + vmaker.vms for '$TARGET_USER'"
[[ $DRY_RUN -eq 1 ]] && warn "dry run: nothing will be changed"
echo ""

# ---------- 1. packages ----------
info "1/7  Installing packages (this needs your sudo password)..."
if [[ $DRY_RUN -eq 0 ]]; then
  sudo -v || err "sudo authentication failed"
  sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"
else
  run sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"
fi

# ---------- 2. libvirtd ----------
info "2/7  Enabling and starting libvirtd..."
run sudo systemctl enable --now libvirtd

# ---------- 3. default network ----------
info "3/7  Starting the default NAT network..."
run sudo virsh -c qemu:///system net-start default || warn "default network already active (or not available)"
run sudo virsh -c qemu:///system net-autostart default

# ---------- 4. firewall (UFW) ----------
# UFW (when active) denies incoming connections and drops forwarded traffic by
# default. Both break libvirt NAT networking: the guest's DHCP/DNS requests to
# dnsmasq (bound to virbr0) are dropped as "incoming", and its internet traffic
# is dropped as "forwarded". Fix both.
if command -v ufw >/dev/null 2>&1 && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
  info "4/7  Configuring UFW for libvirt NAT networking..."
  # 1) Allow forwarded traffic (libvirt's own nftables rules still filter it).
  if grep -qs '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw; then
    run sudo sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  fi
  # 2) Allow incoming DHCP + DNS (and other host services) from the guest bridge.
  if [[ $DRY_RUN -eq 0 ]]; then
    if sudo ufw status 2>/dev/null | grep -q ' on virbr0'; then
      info "    virbr0 incoming rule already present"
    else
      run sudo ufw allow in on virbr0
    fi
    run sudo ufw reload
  else
    run sudo ufw allow in on virbr0
    run sudo ufw reload
  fi
else
  info "4/7  UFW not installed/active — skipping firewall setup"
fi

# ---------- 5. groups ----------
info "5/7  Adding '$TARGET_USER' to the libvirt and kvm groups..."
if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx libvirt \
   && id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx kvm; then
  info "    already a member of libvirt and kvm"
else
  run sudo usermod -aG libvirt,kvm "$TARGET_USER"
fi

# ---------- 6. VM disk directory ----------
info "6/7  Setting up $MYVMS..."
run mkdir -p "$MYVMS"

# With system libvirt, QEMU runs as the libvirt-qemu (and/or qemu) user, which
# is a member of the kvm group. It must be able to traverse the home directory
# and read/write the disk images. Use POSIX ACLs where available; fall back to
# a plain (looser) chmod otherwise.
if command -v setfacl >/dev/null 2>&1; then
  for qu in libvirt-qemu qemu; do
    if getent passwd "$qu" >/dev/null 2>&1; then
      run sudo setfacl -m "u:$qu:--x" "$TARGET_HOME"
    fi
  done
  run sudo setfacl -R -m "g:kvm:rwX" "$MYVMS"
  run sudo setfacl -R -d -m "g:kvm:rwX" "$MYVMS"
else
  warn "setfacl not found; falling back to 'chmod 701' on the home directory"
  run sudo chmod 701 "$TARGET_HOME"
fi

# ---------- 7. vmaker + plugin ----------
info "7/7  Installing vmaker and the vmaker.vms plugin..."
BIN_DIR="$TARGET_HOME/.local/bin"
PLUGIN_DST="$TARGET_HOME/.config/omarchy/plugins/vmaker.vms"
PLUGIN_FILES=(manifest.json BarWidget.qml Panel.qml Service.qml lib tests)

run install -Dm755 "$SCRIPT_DIR/vmaker" "$BIN_DIR/vmaker"

# If this script is being run from inside the already-installed plugin dir
# (e.g. `~/.config/omarchy/plugins/vmaker.vms/vmakerSetup.sh` after
# `omarchy plugin add`), the plugin files are already in place. Don't `rm -rf`
# the very directory we're running from.
if [[ "$SCRIPT_DIR" == "$PLUGIN_DST" ]]; then
  info "    plugin already installed at $PLUGIN_DST (skipping copy)"
else
  run rm -rf "$PLUGIN_DST"
  run mkdir -p "$PLUGIN_DST"
  for f in "${PLUGIN_FILES[@]}"; do
    run cp -R "$SCRIPT_DIR/$f" "$PLUGIN_DST/$f"
  done
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH — you may need to add it" ;;
esac

# Enable the plugin in the running shell, if there is one.
if command -v omarchy-shell >/dev/null 2>&1 && command -v omarchy >/dev/null 2>&1; then
  if [[ $DRY_RUN -eq 0 ]]; then
    omarchy-shell shell rescanPlugins 2>/dev/null || warn "could not rescan plugins (is omarchy-shell running?)"
    omarchy plugin enable vmaker.vms 2>/dev/null || warn "could not enable vmaker.vms (enable it manually)"
  else
    run omarchy-shell shell rescanPlugins
    run omarchy plugin enable vmaker.vms
  fi
else
  warn "omarchy commands not found — enable the plugin manually with: omarchy plugin enable vmaker.vms"
fi

# ---------- done ----------
echo ""
info "Done."
echo ""
echo "Next steps:"
echo "  1. Log out and back in so the libvirt/kvm group membership takes effect."
echo "  2. Run 'vmaker' to create a VM."
echo "  3. The VMs widget (vmaker.vms) should now be in the bar's right section."
echo ""
[[ $DRY_RUN -eq 1 ]] && warn "This was a dry run — nothing was changed."
