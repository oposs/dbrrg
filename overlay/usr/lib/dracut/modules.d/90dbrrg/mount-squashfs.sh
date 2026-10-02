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

    # The network is brought up by dracut's systemd-networkd module (DHCP on
    # every wired interface). parse-dbrrg.sh sets rd.neednet=1 for an http
    # ramroot, which makes systemd-networkd-wait-online run before this hook.
    # This hook used to run dhclient itself, but the initramfs never had
    # dhclient-script, so the lease was never applied and every netboot
    # failed with "Download failed".
    #
    # The boot MAC is taken from the interface holding the default route,
    # i.e. the one whose lease was applied. The wait is a fallback for a
    # wait-online that gave up early; it is bounded so a machine without a
    # network still reaches the download error below instead of hanging.
    boot_iface=""
    _waited=0
    while :; do
        boot_iface=$(ip -o route show default 2>/dev/null | dbrrg_route_iface)
        [ -n "$boot_iface" ] && break
        [ "$_waited" -ge 60 ] && break
        [ $((_waited % 10)) -eq 0 ] && \
            dbrrg_log "dbrrg: waiting for a default route (${_waited}/60s)"
        sleep 1
        _waited=$((_waited + 1))
    done

    if [ -n "$boot_iface" ]; then
        dbrrg_log "dbrrg: network is up on $boot_iface"
        # Record which interface this actually was, so dbrrg-save-home posts
        # the home archive back under the same MAC restore_home fetched it
        # with. See dbrrg_record_boot_mac() for why both halves must not
        # derive it independently.
        dbrrg_record_boot_mac "/sys/class/net/$boot_iface/address" \
            "$DBRRG_STATE" || true
    else
        warn "dbrrg: no default route after 60s - the download will fail"
    fi

    info "Downloading squashfs..."
    curl -f -L --progress-bar --connect-timeout 30 --max-time 600 \
         -o "$sqsh_path" "$ramroot" || die "Download failed"

    info "Download complete"
else
    # USB boot
    dbrrg_log "USB boot: Loading from $ramroot"

    efi_dev="$DBRRG_EFI_DEV"
    efi_mount="$DBRRG_STORAGE/efi"

    # See dbrrg_wait_for_efi() in dbrrg-lib.sh for why a single check raced on
    # real hardware but never in QEMU.
    if ! dbrrg_wait_for_efi; then
        # Give the operator evidence rather than just "not found" - with no
        # rd.shell, dracut answers a die() with a blank screen.
        dbrrg_dump_block_devices
        die "EFI-SYSTEM partition not found after ${DBRRG_DEVICE_TIMEOUT:-60}s"
    fi

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
