#!/bin/bash
# setup-overlay.sh - Setup overlayfs with ZRAM

type info >/dev/null 2>&1 || . /lib/dracut-lib.sh
. /lib/dbrrg-lib.sh

# Only run if we're handling the root
[ "$root" = "dbrrg" ] || return 0

lower_mount="$DBRRG_LAYERS/lower"
upper_base="$DBRRG_LAYERS/upper"

mountpoint -q "$lower_mount" || die "Lower layer not mounted"

info "Setting up overlay filesystem"

# Create ZRAM
zram_dev=$(create_zram_overlay "2G")
[ -n "$zram_dev" ] || die "Failed to create ZRAM"

mkdir -p "$upper_base"
mount "$zram_dev" "$upper_base" || die "Failed to mount ZRAM"

mkdir -p "$upper_base/root" "$upper_base/work"

info "ZRAM overlay mounted"

# Load overlay module
modprobe overlay 2>/dev/null || die "Failed to load overlay module"

# Mount overlay
NEWROOT="${NEWROOT:-/sysroot}"

info "Mounting overlay to $NEWROOT"

# Create required mount point directories in upper layer
# (Docker can't create /proc, /sys, /dev in the image since they're mount points)
mkdir -p "$upper_base/root/proc" "$upper_base/root/sys" "$upper_base/root/dev"
mkdir -p "$upper_base/root/run" "$upper_base/root/tmp"

mount -t overlay overlay \
    -o lowerdir="$lower_mount",upperdir="$upper_base/root",workdir="$upper_base/work" \
    "$NEWROOT" || die "Failed to mount overlay"

info "Overlay filesystem mounted"

# Persist machine-id
machine_id=$(get_machine_id)
[ -n "$machine_id" ] || die "Failed to get machine-id"

echo "$machine_id" > "$NEWROOT/etc/machine-id" || \
    warn "Could not write machine-id"

info "Machine-id set: $machine_id"

echo "$zram_dev" > "$DBRRG_STATE/zram-device"

return 0
