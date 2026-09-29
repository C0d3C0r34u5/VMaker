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

# Report a conflict that means we must not touch a file. A real run aborts; a
# dry run only warns so the preview still completes.
conflict() {
  if [[ $DRY_RUN -eq 1 ]]; then
    warn "$*"
  else
    err "$*"
  fi
}

# Directory this script lives in (the VMaker repo root). The plugin files
# (manifest.json, *.qml, lib/) sit alongside this script, so the whole repo is
# also a valid plugin dir for `omarchy plugin add`.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Packages needed by vmaker and the plugin.
PACKAGES=(qemu-desktop libvirt virt-install virt-manager virt-viewer \
          edk2-ovmf dnsmasq swtpm iptables-nft libosinfo acl)

# ---------- guards ----------
if [[ $EUID -eq 0 ]]; then
  err "run this script as your normal user (not via sudo) — it asks for sudo itself when needed"
fi
command -v pacman >/dev/null 2>&1 || err "this script needs pacman (Arch/Omarchy)"
command -v sudo   >/dev/null 2>&1 || err "this script needs sudo"
command -v sha256sum >/dev/null 2>&1 || err "this script needs sha256sum (coreutils)"

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
  for qu in "${QEMU_USERS[@]}"; do
    run sudo setfacl -m "u:$qu:--x" "$TARGET_HOME"
  done
  run sudo setfacl -R -m "g:kvm:rwX" "$MYVMS"
  run sudo setfacl -R -d -m "g:kvm:rwX" "$MYVMS"
else
  sudo bash -s -- "$TARGET_USER" "$TARGET_HOME" "$UFW_ACTIVE" "$NEED_GROUPS" \
      "${QEMU_USERS[*]}" <<'VMAKER_PRIV'
set -euo pipefail
TARGET_USER="$1"
TARGET_HOME="$2"
UFW_ACTIVE="$3"
NEED_GROUPS="$4"
read -ra QEMU_USERS <<< "$5" || true
MYVMS="$TARGET_HOME/Myvms"

# 1. packages
pacman -S --needed --noconfirm qemu-desktop libvirt virt-install virt-manager \
  virt-viewer edk2-ovmf dnsmasq swtpm iptables-nft libosinfo acl

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
# setfacl (from the `acl` package, installed above as a dependency of libvirt)
# grants only the qemu account(s) execute-on-home, never "other".
command -v setfacl >/dev/null 2>&1 || {
  echo "error: setfacl not found (install the 'acl' package)" >&2
  exit 1
}
mkdir -p "$MYVMS"
for qu in "${QEMU_USERS[@]}"; do
  setfacl -m "u:$qu:--x" "$TARGET_HOME"
done
setfacl -R -m "g:kvm:rwX" "$MYVMS"
setfacl -R -d -m "g:kvm:rwX" "$MYVMS"
VMAKER_PRIV
fi

# ---------- 7. vmaker + plugin ----------
info "7/7  Installing vmaker and the vmaker.vms plugin..."
BIN_DIR="$TARGET_HOME/.local/bin"
BIN_DST="$BIN_DIR/vmaker"
PLUGIN_DST="$TARGET_HOME/.config/omarchy/plugins/vmaker.vms"
PLUGIN_FILES=(manifest.json BarWidget.qml Panel.qml Service.qml lib tests)

# SHA-256 of every vmaker script shipped by a released vmakerSetup.sh. An
# existing ~/.local/bin/vmaker is ours only when its content hash is in this
# list (a known VMaker build) or it is byte-identical to the bundled script.
# Anything else — even a file that carries VMaker-looking text — is refused,
# never overwritten. When vmaker changes, add the new sha256 here so the next
# release can upgrade over this one.
VMAKER_KNOWN_SHA256=(
  76400895a194718e7878a83daa13915678d09e86daf3efbb0e026b279185396a  # initial release
  f0863f0ed3185056061a70ea6ed96f7565f144eb32cfbde5355bbd8105705de5  # virt-viewer auto-open
)

# Relative paths (files and directories) that belong to the plugin, mapping to
# "file"/"dir". Anything present in the installed directory but absent here was
# put there by the user and must be preserved.
declare -A PLUGIN_MANAGED=()
for f in "${PLUGIN_FILES[@]}"; do
  if [[ -d "$SCRIPT_DIR/$f" ]]; then
    PLUGIN_MANAGED["$f"]="dir"
    while IFS= read -r -d '' p; do
      rel="${p#"$SCRIPT_DIR"/}"
      if [[ -d "$p" ]]; then PLUGIN_MANAGED["$rel"]="dir"; else PLUGIN_MANAGED["$rel"]="file"; fi
    done < <(find "$SCRIPT_DIR/$f" -mindepth 1 -print0)
  elif [[ -e "$SCRIPT_DIR/$f" ]]; then
    PLUGIN_MANAGED["$f"]="file"
  fi
done

# Copy the plugin's own files into $PLUGIN_DST, creating it if needed. Files
# with the same names are replaced; anything else already in the directory is
# left alone. Using "$f/." (not "$f") avoids nesting a duplicate directory on
# re-runs. Callers run the preflight first, so every destination path is known
# to be a regular file/dir owned by the target user — never a symlink to write
# through.
copy_plugin_files() {
  local f
  run mkdir -p "$PLUGIN_DST"
  for f in "${PLUGIN_FILES[@]}"; do
    if [[ -d "$SCRIPT_DIR/$f" ]]; then
      run mkdir -p "$PLUGIN_DST/$f"
      run cp -R "$SCRIPT_DIR/$f/." "$PLUGIN_DST/$f/"
    else
      run cp -f "$SCRIPT_DIR/$f" "$PLUGIN_DST/$f"
    fi
  done
}

# --- 7a. vmaker binary: only replace a file we can prove is a VMaker build ---
BIN_MODE="install"
if [[ -L "$BIN_DST" ]]; then
  BIN_MODE="refuse"
  conflict "$BIN_DST is a symbolic link; refusing to overwrite it — move it aside first"
elif [[ -e "$BIN_DST" ]]; then
  BIN_OWNER="$(stat -c %u "$BIN_DST" 2>/dev/null || true)"
  if [[ "$BIN_OWNER" != "$TARGET_UID" ]]; then
    BIN_MODE="refuse"
    conflict "$BIN_DST is owned by uid ${BIN_OWNER:-?}, not '$TARGET_USER'; refusing to overwrite it"
  elif [[ ! -f "$BIN_DST" ]]; then
    BIN_MODE="refuse"
    conflict "$BIN_DST is not a regular file; refusing to overwrite it"
  elif cmp -s "$SCRIPT_DIR/vmaker" "$BIN_DST"; then
    BIN_MODE="uptodate"
  else
    BIN_SHA="$(sha256sum "$BIN_DST" 2>/dev/null | awk '{print $1}')" || true
    BIN_KNOWN=0
    for h in "${VMAKER_KNOWN_SHA256[@]}"; do
      [[ -n "$BIN_SHA" && "$h" == "$BIN_SHA" ]] && { BIN_KNOWN=1; break; }
    done
    if [[ $BIN_KNOWN -eq 1 ]]; then
      BIN_MODE="upgrade"
    else
      BIN_MODE="refuse"
      conflict "$BIN_DST is not a known VMaker release (sha256 ${BIN_SHA:-unreadable}); refusing to overwrite it — move it aside first"
    fi
  fi
fi

case "$BIN_MODE" in
  install)  run install -Dm755 "$SCRIPT_DIR/vmaker" "$BIN_DST" ;;
  upgrade)  info "    upgrading vmaker at $BIN_DST"
            run install -Dm755 "$SCRIPT_DIR/vmaker" "$BIN_DST" ;;
  uptodate) info "    vmaker is already up to date at $BIN_DST" ;;
  refuse)   : ;;  # conflict() already reported it
esac

# --- 7b. plugin dir: update only our files, preserve everything else ---
# The directory is never removed. We replace only the paths VMaker installed;
# user-added files anywhere (including inside lib/ and tests/) are left
# untouched. Managed paths are overwritten only when they are target-owned
# regular files/dirs — a symlink or foreign-owned entry stops the install.
#
# If this script is being run from inside the already-installed plugin dir
# (e.g. `~/.config/omarchy/plugins/vmaker.vms/vmakerSetup.sh` after
# `omarchy plugin add`), the plugin files are already in place. Don't touch
# the very directory we're running from.
PLUGIN_MODE="install"
if [[ "$SCRIPT_DIR" == "$PLUGIN_DST" ]]; then
  PLUGIN_MODE="skip"
elif [[ -L "$PLUGIN_DST" ]]; then
  PLUGIN_MODE="refuse"
  conflict "$PLUGIN_DST is a symbolic link; refusing to write into it"
elif [[ -e "$PLUGIN_DST" ]]; then
  if [[ ! -d "$PLUGIN_DST" ]]; then
    PLUGIN_MODE="refuse"
    conflict "$PLUGIN_DST is not a directory; refusing to write into it"
  else
    PLUGIN_OWNER="$(stat -c %u "$PLUGIN_DST" 2>/dev/null || true)"
    if [[ "$PLUGIN_OWNER" != "$TARGET_UID" ]]; then
      PLUGIN_MODE="refuse"
      conflict "$PLUGIN_DST is owned by uid ${PLUGIN_OWNER:-?}, not '$TARGET_USER'; refusing to write into it"
    elif [[ ! -r "$PLUGIN_DST" || ! -x "$PLUGIN_DST" ]]; then
      PLUGIN_MODE="refuse"
      conflict "$PLUGIN_DST is not readable/traversable; refusing to write into it"
    elif [[ ! -w "$PLUGIN_DST" ]]; then
      PLUGIN_MODE="refuse"
      conflict "$PLUGIN_DST is not writable by '$TARGET_USER'; refusing to write into it"
    fi
  fi
fi

# Preflight the installed tree while it is still unmodified: refuse symlinked,
# non-regular, or foreign-owned managed paths, and record any user-added paths.
PLUGIN_EXTRA=()
PLUGIN_CONFLICT=0
if [[ "$PLUGIN_MODE" == "install" && -e "$PLUGIN_DST" ]]; then
  while IFS= read -r -d '' p; do
    rel="${p#"$PLUGIN_DST"/}"
    if [[ -z "${PLUGIN_MANAGED[$rel]+x}" ]]; then
      PLUGIN_EXTRA+=("$rel")
      continue
    fi
    if [[ "$(stat -c %u "$p" 2>/dev/null || true)" != "$TARGET_UID" ]]; then
      conflict "$PLUGIN_DST/$rel is not owned by '$TARGET_USER'; refusing to overwrite it"
      PLUGIN_CONFLICT=1
    elif [[ -L "$p" ]]; then
      conflict "$PLUGIN_DST/$rel is a symbolic link; refusing to overwrite it"
      PLUGIN_CONFLICT=1
    elif [[ "${PLUGIN_MANAGED[$rel]}" == "dir" && ! -d "$p" ]]; then
      conflict "$PLUGIN_DST/$rel should be a directory; refusing to overwrite it"
      PLUGIN_CONFLICT=1
    elif [[ "${PLUGIN_MANAGED[$rel]}" == "file" && ! -f "$p" ]]; then
      conflict "$PLUGIN_DST/$rel should be a regular file; refusing to overwrite it"
      PLUGIN_CONFLICT=1
    fi
  done < <(find "$PLUGIN_DST" -mindepth 1 -print0 2>/dev/null)
fi

if [[ "$PLUGIN_MODE" == "install" ]]; then
  if [[ $PLUGIN_CONFLICT -eq 1 ]]; then
    PLUGIN_MODE="refuse"
  elif [[ ${#PLUGIN_EXTRA[@]} -gt 0 ]]; then
    PLUGIN_MODE="merge"
  fi
fi

case "$PLUGIN_MODE" in
  skip)
    info "    plugin already installed at $PLUGIN_DST (skipping copy)"
    ;;
  merge)
    warn "    $PLUGIN_DST contains files not installed by VMaker; updating our files and leaving them untouched"
    copy_plugin_files
    ;;
  install)
    copy_plugin_files
    ;;
  refuse)
    : ;;  # conflict() already reported it
esac

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
if [[ $DRY_RUN -eq 1 ]]; then
  warn "This was a dry run — nothing was changed."
fi
