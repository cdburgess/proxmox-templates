# PVE Cloud-Init Template Builder

One-liner script to build a Proxmox VE VM template from an Ubuntu cloud image, with cloud-init, QEMU guest agent, and proper hygiene (machine-id, SSH host keys, etc.) baked in.

## What It Does

1. Downloads the latest Ubuntu cloud image
2. Customizes it via `virt-customize` (installs packages, clears machine-id/SSH keys/cloud-init state)
3. Creates a VM, imports the disk, configures hardware (virtio-scsi, serial console, QEMU agent)
4. Sets cloud-init defaults (user, SSH key, DHCP)
5. Converts to a template

## Prerequisites

- Proxmox VE 8+
- `root` access
- `libguestfs-tools` (auto-installed if missing)
- A storage pool with sufficient free space (`lvm-thin` recommended for linked clones)

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cdburgess/proxmox-templates/main/build-template.sh)"
```

## Usage

### All Defaults

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cdburgess/proxmox-templates/main/build-template.sh)"
```

### Override Parameters

```bash
VMID=9001 \
NAME=ubuntu-26.04-web \
STORAGE=local-zfs \
DISK_SIZE=32G \
MEMORY=4096 \
CORES=4 \
BRIDGE=vmbr1 \
VLAN_TAG=42 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cdburgess/proxmox-templates/main/build-template.sh)"
```

### Pin to a Release

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cdburgess/proxmox-templates/v1.0.0/build-template.sh)"
```

## Configuration

All parameters are set via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VMID` | `9000` | VM ID for the template |
| `NAME` | `ubuntu-26-04-template` | VM name |
| `STORAGE` | `local-lvm` | Storage pool ID |
| `BRIDGE` | `vmbr0` | Bridge for net0 |
| `VLAN_TAG` | `19` | VLAN tag for net0 |
| `DISK_SIZE` | `20G` | Final disk size |
| `MEMORY` | `2048` | RAM in MB |
| `CORES` | `2` | CPU cores |
| `CI_USER` | `ubuntu` | Cloud-init default user |
| `SSH_KEY` | `/root/.ssh/id_ed25519.pub` | Public key to inject |
| `IMAGE_URL` | `https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img` | Cloud image URL |
| `IMAGE_FILE` | `resolute-server-cloudimg-amd64.img` | Local filename for the image |
| `INSTALL_PKGS` | `qemu-guest-agent` | Space-separated packages to install |
| `WORKDIR` | `/var/lib/vz/template/iso` | Working directory for downloads |

## Storage Selection

The template is created on the Proxmox node where the script runs; storage detection and `qm` operations use that node's local Proxmox configuration.

The script auto-detects available storage pools and will:

- **Use the specified `STORAGE`** if it is active on the local Proxmox node and supports VM disk images (required for both the imported disk and cloud-init drive)
- **Prompt interactively** (numbered list) to select a compatible pool if the configured `STORAGE` is unavailable or unsuitable
- **Fail with available pool IDs** in non-interactive mode if `STORAGE` is unavailable or unsuitable; set `STORAGE` explicitly rather than relying on an arbitrary pool
- **Fail** if available space is insufficient for the requested disk size

Free space reported by `pvesm status` in KiB is displayed in GiB and converted to bytes for comparison with the requested disk size.

Linked-clone support depends on the selected storage's configuration and disk format. Use `--full` when you want a full clone regardless of linked-clone support.

## Cloning from the Template

```bash
# Linked clone (requires snapshot/clone support on the selected storage)
qm clone 9000 101 --name my-vm

# Full clone
qm clone 9000 101 --name my-vm --full

# Override per-VM settings
qm set 101 --sshkeys /root/.ssh/other-key.pub
qm set 101 --ipconfig0 ip=10.0.19.50/24,gw=10.0.19.1
qm start 101
```

## What's Baked Into the Template

| Item | Detail |
|------|--------|
| QEMU Guest Agent | Installed and enabled |
| Cloud-init | Clean state, will run on first boot |
| `/etc/machine-id` | Truncated — regenerated per clone |
| SSH host keys | Removed — regenerated per clone |
| Boot order | Disk only (`scsi0`) |
| Console | Serial (socket) |
| Disk | virtio-scsi, `ssd=1`, `discard=on`, `iothread=1`, `cache=none` |
| Cloud-init drive | `ide2` |
| Default user | `ubuntu` (configurable via `CI_USER`) |
| Default network | DHCP on `net0` |

## Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `Storage 'local-lvm' not found` | Run `pvesm status` to see available pools, pass correct `STORAGE` |
| `Not enough free space` | Free up space or reduce `DISK_SIZE` |
| Clone fails with "not supported" | The selected storage or disk format lacks linked-clone support — use `--full` |
| VM doesn't get IP | Check bridge/VLAN config; verify `ipconfig0` is correct |
| `qm importdisk` fails | Ensure the image file is a valid raw disk (not qcow2) |

## Idempotency

The script is safe to re-run. If the target `VMID` already exists, it will be stopped and destroyed before rebuilding.
