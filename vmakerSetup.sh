#!/usr/bin/env bash
set -euo pipefail

# vmakerSetup.sh — install and configure vmaker + the vmaker.vms Omarchy plugin
#
# Does everything needed to create and manage QEMU/KVM VMs on Arch/Omarchy:
#   1. Installs QEMU, libvirt, and their dependencies (pacman, via sudo)
#   2. Enables and starts libvirtd and the default NAT network
#   3. Adds the current user to the libvirt and kvm groups
#   4. Adds scoped UFW rules so VMs can reach the internet (NAT forwarding on
#      the libvirt bridge + DHCP/DNS to dnsmasq)
#   5. Grants the libvirt qemu process access to ~/Myvms (VM disks)
#   6. Installs the vmaker script to ~/.local/bin
#   7. Installs the vmaker.vms plugin and enables it in the Omarchy bar
#
# Usage:
#   ./vmakerSetup.sh              # install for real
#   ./vmakerSetup.sh --dry-run    # print what would happen, change nothing
#
# Security: the invoking user is resolved from the system database (never from
# the USER/SUDO_USER environment variables, which are caller-controlled), and
# every privileged step runs inside a single sudo invocation whose arguments
# and payload are fixed before sudo authenticates. There is no cached-sudo
# window during which a same-UID process could edit this script and escalate.

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

# Packages needed by vmaker and the plugin.
PACKAGES=(qemu-desktop libvirt virt-install virt-manager virt-viewer \
          edk2-ovmf dnsmasq swtpm iptables-nft libosinfo)

# ---------- guards ----------
if [[ $EUID -eq 0 ]]; then
  err "run this script as your normal user (not via sudo) — it asks for sudo itself when needed"
fi
command -v pacman >/dev/null 2>&1 || err "this script needs pacman (Arch/Omarchy)"
command -v sudo   >/dev/null 2>&1 || err "this script needs sudo"

# ---------- identity (from the OS, not the environment) ----------
TARGET_USER="$(id -un)"
TARGET_UID="$(id -u)"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
MYVMS="$TARGET_HOME/Myvms"

# Verify the identity against the system database, not whatever USER/SUDO_USER
# happen to say.
[[ -n "$TARGET_HOME" ]] || err "could not resolve a home directory for '$TARGET_USER'"
[[ "$(getent passwd "$TARGET_USER" | cut -d: -f3)" == "$TARGET_UID" ]] \
  || err "could not verify '$TARGET_USER' (uid $TARGET_UID) against the system database"

[[ -f "$SCRIPT_DIR/vmaker" ]] || err "vmaker script not found next to $0"
[[ -f "$SCRIPT_DIR/manifest.json" ]] || err "plugin manifest.json not found next to $0"

echo ""
info "vmakerSetup — installing vmaker + vmaker.vms for '$TARGET_USER'"
[[ $DRY_RUN -eq 1 ]] && warn "dry run: nothing will be changed"
echo ""

# ---------- non-privileged decisions ----------
# Decide everything we can WITHOUT root up front, so the privileged payload
# below is fully fixed before sudo is ever asked for.

UFW_ACTIVE=0
if command -v ufw >/dev/null 2>&1 && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
  UFW_ACTIVE=1
fi

NEED_GROUPS=0
if ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx libvirt \
   || ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx kvm; then
  NEED_GROUPS=1
fi

HAS_SETFACL=0
command -v setfacl >/dev/null 2>&1 && HAS_SETFACL=1

QEMU_USERS=()
for qu in libvirt-qemu qemu; do
  getent passwd "$qu" >/dev/null 2>&1 && QEMU_USERS+=("$qu")
done

# ---------- progress ----------
info "1/7  Installing packages..."
info "2/7  Enabling and starting libvirtd..."
info "3/7  Starting the default NAT network..."
if [[ $UFW_ACTIVE -eq 1 ]]; then
  info "4/7  Adding scoped UFW rules for libvirt NAT networking..."
else
  info "4/7  UFW not installed/active — skipping firewall setup"
fi
if [[ $NEED_GROUPS -eq 1 ]]; then
  info "5/7  Adding '$TARGET_USER' to the libvirt and kvm groups..."
else
  info "5/7  '$TARGET_USER' is already a member of libvirt and kvm"
fi
info "6/7  Setting up $MYVMS..."

# ---------- privileged steps (single sudo) ----------
if [[ $DRY_RUN -eq 1 ]]; then
  run sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"
  run sudo systemctl enable --now libvirtd
  run sudo virsh -c qemu:///system net-start default
  run sudo virsh -c qemu:///system net-autostart default
  if [[ $UFW_ACTIVE -eq 1 ]]; then
    run sudo ufw route allow in on virbr0
    run sudo ufw route allow out on virbr0
    run sudo ufw allow in on virbr0 to any port 67 proto udp
    run sudo ufw allow in on virbr0 to any port 53 proto udp
    run sudo ufw allow in on virbr0 to any port 53 proto tcp
    run sudo ufw reload
  fi
  if [[ $NEED_GROUPS -eq 1 ]]; then
    run sudo usermod -aG libvirt,kvm "$TARGET_USER"
  fi
  run mkdir -p "$MYVMS"
  if [[ $HAS_SETFACL -eq 1 ]]; then
    for qu in "${QEMU_USERS[@]}"; do
      run sudo setfacl -m "u:$qu:--x" "$TARGET_HOME"
    done
    run sudo setfacl -R -m "g:kvm:rwX" "$MYVMS"
    run sudo setfacl -R -d -m "g:kvm:rwX" "$MYVMS"
  else
    run sudo chmod 701 "$TARGET_HOME"
  fi
else
  sudo bash -s -- "$TARGET_USER" "$TARGET_HOME" "$UFW_ACTIVE" "$NEED_GROUPS" \
      "$HAS_SETFACL" "${QEMU_USERS[*]}" <<'VMAKER_PRIV'
set -euo pipefail
TARGET_USER="$1"
TARGET_HOME="$2"
UFW_ACTIVE="$3"
NEED_GROUPS="$4"
HAS_SETFACL="$5"
read -ra QEMU_USERS <<< "$6" || true
MYVMS="$TARGET_HOME/Myvms"

# 1. packages
pacman -S --needed --noconfirm qemu-desktop libvirt virt-install virt-manager \
  virt-viewer edk2-ovmf dnsmasq swtpm iptables-nft libosinfo

# 2. libvirtd
systemctl enable --now libvirtd

# 3. default NAT network
virsh -c qemu:///system net-start default || true
virsh -c qemu:///system net-autostart default

# 4. scoped UFW rules
if [[ "$UFW_ACTIVE" == "1" ]]; then
  ufw_has() { ufw status 2>/dev/null | grep -qE "$1"; }
  ufw_has 'ALLOW FWD.*on virbr0' || ufw route allow in on virbr0
  ufw_has 'on virbr0.*ALLOW FWD' || ufw route allow out on virbr0
  ufw_has '67/udp.*on virbr0' || ufw allow in on virbr0 to any port 67 proto udp
  ufw_has '53/udp.*on virbr0' || ufw allow in on virbr0 to any port 53 proto udp
  ufw_has '53/tcp.*on virbr0' || ufw allow in on virbr0 to any port 53 proto tcp
  ufw reload
fi

# 5. groups
if [[ "$NEED_GROUPS" == "1" ]]; then
  usermod -aG libvirt,kvm "$TARGET_USER"
fi

# 6. VM disk directory + qemu access
mkdir -p "$MYVMS"
if [[ "$HAS_SETFACL" == "1" ]]; then
  for qu in "${QEMU_USERS[@]}"; do
    setfacl -m "u:$qu:--x" "$TARGET_HOME"
  done
  setfacl -R -m "g:kvm:rwX" "$MYVMS"
  setfacl -R -d -m "g:kvm:rwX" "$MYVMS"
else
  chmod 701 "$TARGET_HOME"
fi
VMAKER_PRIV
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
