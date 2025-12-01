#!/bin/bash
# mount-squashfs.sh - Acquire and mount squashfs

type info >/dev/null 2>&1 || . /lib/dracut-lib.sh
. /lib/dbrrg-lib.sh

# Only run if we're handling the root
[ "$root" = "dbrrg" ] || return 0

dbrrg_log "dbrrg: Initializing directories..."
dbrrg_init_dirs

ramroot=$(cat /tmp/dbrrg-ramroot 2>/dev/null)
[ -z "$ramroot" ] && die "No ramroot parameter"

dbrrg_log "dbrrg: Acquiring squashfs: $ramroot"

sqsh_path=""

if is_remote_url "$ramroot"; then
    # Network boot
    dbrrg_log "Network boot: Downloading from $ramroot"

    download_dir="$DBRRG_STORAGE/download"
    sqsh_path="$download_dir/ramroot.sqsh"

    mount -t ramfs ramfs "$download_dir" || die "Failed to create ramfs"

    info "Waiting for network..."

    # Bring up first available network interface
    for iface in /sys/class/net/*; do
        iface_name=$(basename "$iface")
        [ "$iface_name" = "lo" ] && continue
        info "Bringing up interface $iface_name"
        ip link set "$iface_name" up
        dhclient -v "$iface_name" || true
        break
    done

    sleep 2  # Give DHCP time to complete

    info "Downloading squashfs..."
    curl -f -L --progress-bar --connect-timeout 30 --max-time 600 \
         -o "$sqsh_path" "$ramroot" || die "Download failed"

    info "Download complete"
else
    # USB boot
    dbrrg_log "USB boot: Loading from $ramroot"

    udevadm settle --timeout=30
    sleep 2

    efi_dev="/dev/disk/by-partlabel/EFI-SYSTEM"
    efi_mount="$DBRRG_STORAGE/efi"

    [ -b "$efi_dev" ] || die "EFI-SYSTEM partition not found"

    fsck.vfat -a "$efi_dev" > /dev/kmsg 2>&1 || true
    mount -t vfat "$efi_dev" "$efi_mount" || die "Failed to mount EFI"

    sqsh_path="$efi_mount/$ramroot"
    [ -f "$sqsh_path" ] || die "SquashFS not found: $sqsh_path"
fi

verify_squashfs "$sqsh_path"

# Mount squashfs
lower_mount="$DBRRG_LAYERS/lower"

dbrrg_log "Mounting squashfs to $lower_mount"

modprobe loop 2>/dev/null || true
modprobe squashfs 2>/dev/null || die "Failed to load squashfs module"

loop_dev=$(setup_loop_device "$sqsh_path" 128)

dbrrg_log "Creating mount point: $lower_mount"
mkdir -p "$lower_mount"

dbrrg_log "Mounting $loop_dev to $lower_mount"
if ! mount -t squashfs -o ro "$loop_dev" "$lower_mount"; then
    die "Failed to mount squashfs: $loop_dev -> $lower_mount"
fi

dbrrg_log "Verifying squashfs contents"
[ -d "$lower_mount/bin" ] || die "Invalid squashfs: missing /bin"
[ -d "$lower_mount/etc" ] || die "Invalid squashfs: missing /etc"

dbrrg_log "SquashFS mounted successfully at $lower_mount"

echo "$sqsh_path" > "$DBRRG_STATE/squashfs-path"
echo "$loop_dev" > "$DBRRG_STATE/loop-device"

return 0
