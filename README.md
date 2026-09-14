# VMaker

Interactive QEMU/KVM + libvirt VM creation for Arch/Omarchy, plus a bar
widget to list and start/stop your VMs.

| Path | What it is |
|------|-----------|
| `vmaker` | Interactive CLI that creates VMs (asks OS, name, ISO, CPU, RAM, disk) |
| `brett.vms/` | An Omarchy shell plugin: bar widget + panel to list/start/stop VMs |
| `vmakerSetup.sh` | One-shot installer for QEMU/libvirt, vmaker, and the plugin |

## Requirements

- Arch Linux or Omarchy (uses `pacman`)
- `sudo` access — the setup script asks for your password

## Install

### Quick start (recommended)

```bash
git clone https://github.com/C0d3C0r34u5/VMaker.git
cd VMaker
./vmakerSetup.sh
```

This installs QEMU, libvirt, and their dependencies, enables `libvirtd`,
starts the default NAT network, adds your user to the `libvirt` and `kvm`
groups, installs `vmaker` to `~/.local/bin`, and installs + enables the
`brett.vms` bar widget.

When it finishes, **log out and back in** so the new group membership takes
effect, then run `vmaker` to create your first VM.

### Running vmakerSetup.sh after the plugin is already installed

If `brett.vms` is already in `~/.config/omarchy/plugins/` (you copied it,
or installed it through a plugin manager), you still need the system pieces
— QEMU, libvirt, and the `vmaker` helper. Clone the repo and run the same
setup script:

```bash
git clone https://github.com/C0d3C0r34u5/VMaker.git
cd VMaker
./vmakerSetup.sh
```

The script is idempotent, so running it again is safe:

- already-installed packages are skipped (`pacman --needed`)
- `libvirtd` and the default network are just re-enabled
- re-copying `brett.vms` over itself is harmless
- your user is only added to the groups if missing

After it finishes, log out and back in.

### Install only the plugin (no system changes)

```bash
mkdir -p ~/.config/omarchy/plugins
cp -r brett.vms ~/.config/omarchy/plugins/
omarchy-shell shell rescanPlugins
omarchy plugin enable brett.vms
```

You'll still need QEMU/libvirt and `vmaker` for VMs to actually work — see
the setup script above.

## Running vmakerSetup.sh

```bash
./vmakerSetup.sh            # install for real
./vmakerSetup.sh --dry-run  # print what would happen, change nothing
```

You'll be asked for your sudo password once, up front. The script then does
six things:

1. Installs packages: `qemu-desktop libvirt virt-install virt-manager
   virt-viewer edk2-ovmf dnsmasq swtpm iptables-nft libosinfo`
2. `systemctl enable --now libvirtd`
3. Starts and autostarts the default NAT network (`virbr0`)
4. Adds your user to the `libvirt` and `kvm` groups
5. Creates `~/Myvms` and grants the qemu process access to it (POSIX ACLs)
6. Installs `vmaker` to `~/.local/bin` and `brett.vms` into the shell

## Creating a VM

```bash
vmaker
```

`vmaker` interactively asks for: OS type (Linux/Windows), version, name,
install ISO, CPU cores, RAM, and disk size. VMs live in
`~/Myvms/<name>/<name>.qcow2`. Windows 11 / Server 2025 get Secure Boot +
TPM 2.0 automatically.

Useful commands afterwards:

```bash
virsh list --all       # see all VMs
virsh start <name>     # start
virsh shutdown <name>  # graceful stop
virsh destroy <name>   # force stop
virt-manager           # GUI
virt-viewer <name>     # view a running VM
```

## The bar widget

Once installed, `brett.vms` shows a computer glyph plus the running count in
the right section of the bar.

- **Left-click** — open the panel (list VMs, start / shutdown / force-stop)
- **Middle-click** — refresh immediately
- **`r`** (in the panel) — refresh

Manage it with:

```bash
omarchy plugin disable brett.vms
omarchy plugin enable  brett.vms
omarchy-shell brett.vms status
```

## Notes

- VMs use the system libvirt connection (`qemu:///system`), matching `vmaker`.
- After the first setup, **log out and back in** or `virsh`/`vmaker` won't
  have the `libvirt` group yet.
- The setup script grants the qemu user access to `~/Myvms` via ACLs. Don't
  re-lock your home directory back to `700` afterwards, or VMs won't start.
