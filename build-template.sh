#!/usr/bin/env bash
set -euo pipefail

# ─── Defaults (override via env vars) ───────────────────────────────────────────
VMID="${VMID:-9000}"
NAME="${NAME:-ubuntu-26-04-template}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vSwitch}"
VLAN_TAG="${VLAN_TAG:-19}"
DISK_SIZE="${DISK_SIZE:-20G}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"
CI_USER="${CI_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-/root/.ssh/id_ed25519.pub}"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img}"
IMAGE_FILE="${IMAGE_FILE:-resolute-server-cloudimg-amd64.img}"
INSTALL_PKGS="${INSTALL_PKGS:-qemu-guest-agent}"
WORKDIR="/var/lib/vz/template/iso"

# ─── Helpers ────────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "→ $*"; }

# ─── Preconditions ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root"
command -v qm &>/dev/null || die "qm not found (are you on a PVE node?)"
command -v pvesm &>/dev/null || die "pvesm not found (are you on a PVE node?)"
command -v virt-customize &>/dev/null || {
  info "Installing libguestfs-tools..."
  apt-get install -y libguestfs-tools
}

# ─── Storage Selection ─────────────────────────────────────────────────────────
if ! STORAGE_STATUS=$(pvesm status --content images); then
  die "Unable to query local Proxmox storage that supports VM images"
fi

mapfile -t STORAGE_IDS < <(awk 'NR > 1 && $3 == "active" {print $1}' <<< "$STORAGE_STATUS")
(( ${#STORAGE_IDS[@]} > 0 )) || die "No active storage configured for VM images on this Proxmox node"

info "Active storage pools supporting VM disks and cloud-init:"
printf "  %-20s %-12s %-12s\n" "ID" "TYPE" "FREE (GiB)"
awk 'NR > 1 && $3 == "active" {
  printf "  %-20s %-12s %-12.1f\n", $1, $2, $6 / 1024 / 1024
}' <<< "$STORAGE_STATUS"

STORAGE_FOUND=false
for STORAGE_ID in "${STORAGE_IDS[@]}"; do
  if [[ "$STORAGE_ID" == "$STORAGE" ]]; then
    STORAGE_FOUND=true
    break
  fi
done

if [[ "$STORAGE_FOUND" == false ]]; then
  if [[ ! -t 0 ]]; then
    die "Storage '$STORAGE' is not active or does not support VM images on this node. Set STORAGE to a compatible storage ID (available pools are listed above)."
  fi

  echo ""
  echo "Storage '$STORAGE' is not active or does not support VM images. Select a compatible pool:"
  for i in "${!STORAGE_IDS[@]}"; do
    echo "  $((i+1)). ${STORAGE_IDS[$i]}"
  done

  while true; do
    read -rp "Select storage [1-${#STORAGE_IDS[@]}] (default: 1): " choice || die "No storage selection received"
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#STORAGE_IDS[@]} )); then
      STORAGE="${STORAGE_IDS[$((choice-1))]}"
      break
    fi
    echo "Enter a number from 1 to ${#STORAGE_IDS[@]}."
  done
fi

# Clone capabilities depend on the storage configuration and disk format.
STORAGE_TYPE=$(awk -v storage="$STORAGE" '$1 == storage {print $2; exit}' <<< "$STORAGE_STATUS")
info "Storage type: $STORAGE_TYPE; linked-clone support depends on storage configuration and disk format"

# Verify free space
if [[ ! "$DISK_SIZE" =~ ^([1-9][0-9]*)G$ ]]; then
  die "DISK_SIZE must be a positive whole number of GiB (for example, 20G)"
fi
DISK_BYTES=$((${BASH_REMATCH[1]} * 1024 * 1024 * 1024))
FREE_KIB=$(awk -v storage="$STORAGE" '$1 == storage {print $6; exit}' <<< "$STORAGE_STATUS")
[[ "$FREE_KIB" =~ ^[0-9]+$ ]] || die "Unable to determine free space for storage $STORAGE"
FREE_BYTES=$((FREE_KIB * 1024))
FREE_GIB=$(awk -v bytes="$FREE_BYTES" 'BEGIN {printf "%.1f", bytes / 1024 / 1024 / 1024}')
if (( FREE_BYTES < DISK_BYTES )); then
  die "Storage $STORAGE has ${FREE_GIB} GiB free, but $DISK_SIZE requested. Free up space or choose another pool."
fi
info "Storage $STORAGE ($STORAGE_TYPE): ${FREE_GIB} GiB free, $DISK_SIZE needed"

# ─── Step 1: Download image ────────────────────────────────────────────────────
mkdir -p "$WORKDIR"
if [[ -f "$WORKDIR/$IMAGE_FILE" ]]; then
  info "Image already exists, skipping download"
else
  info "Downloading $IMAGE_URL"
  curl -fSL --progress-bar -o "$WORKDIR/$IMAGE_FILE" "$IMAGE_URL"
fi

# ─── Step 2: Customize image ───────────────────────────────────────────────────
info "Customizing image (machine-id, SSH keys, cloud-init, packages)..."
virt-customize -a "$WORKDIR/$IMAGE_FILE" \
  --install "$INSTALL_PKGS" \
  --run-command 'systemctl enable qemu-guest-agent' \
  --run-command 'rm -f /etc/ssh/ssh_host_*' \
  --run-command 'cloud-init clean --logs --seed' \
  --run-command 'rm -f /root/.bash_history' \
  --run-command 'apt-get clean && rm -rf /var/lib/apt/lists/*' \
  --truncate /etc/machine-id

# ─── Step 3: Create VM shell ───────────────────────────────────────────────────
if qm status "$VMID" &>/dev/null; then
  info "VMID $VMID exists, destroying..."
  qm stop "$VMID" 2>/dev/null || true
  qm destroy "$VMID"
fi

info "Creating VM $VMID ($NAME)..."
qm create "$VMID" \
  --name "$NAME" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --cpu host \
  --net0 "virtio,bridge=$BRIDGE,tag=$VLAN_TAG" \
  --ostype l26 \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

# ─── Step 4: Import disk & configure ──────────────────────────────────────────
info "Importing disk to $STORAGE..."
qm importdisk "$VMID" "$WORKDIR/$IMAGE_FILE" "$STORAGE"

qm set "$VMID" --scsihw virtio-scsi-pci
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,ssd=1,discard=on,iothread=1,cache=none"
qm resize "$VMID" scsi0 "$DISK_SIZE"

# Cloud-init drive
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot c --bootdisk scsi0

# Cloud-init defaults (inherited by clones, overridable per-VM)
qm set "$VMID" --ciuser "$CI_USER"
qm set "$VMID" --ipconfig0 ip=dhcp
if [[ -f "$SSH_KEY" ]]; then
  qm set "$VMID" --sshkeys "$SSH_KEY"
  info "SSH key injected: $SSH_KEY"
else
  info "WARNING: $SSH_KEY not found, no default SSH key set"
fi

# ─── Step 5: Convert to template ──────────────────────────────────────────────
info "Converting to template..."
qm template "$VMID"

# Cleanup
rm -f "$WORKDIR/$IMAGE_FILE"

info "Done! Template $VMID ($NAME) is ready to clone:"
info "  qm clone $VMID <new-id> --name <hostname> --full"
