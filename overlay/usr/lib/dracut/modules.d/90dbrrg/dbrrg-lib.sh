#!/bin/bash
# dbrrg-lib.sh - Shared library functions

# Guard against multiple sourcing - only define functions and readonly vars once
if [ -z "$_DBRRG_LIB_LOADED" ]; then
_DBRRG_LIB_LOADED=1

type info >/dev/null 2>&1 || . /lib/dracut-lib.sh

# Use info instead of dinfo for compatibility
type dinfo >/dev/null 2>&1 || dinfo() { info "$@"; }

# Also echo to /dev/console for serial output
# Use >&2 to avoid polluting stdout (which is used for return values)
dbrrg_log() {
    info "$@"
    echo "$@" > /dev/console 2>/dev/null || true
    echo "$@" >&2
}

readonly DBRRG_BASE="/run/dbrrg"
readonly DBRRG_STORAGE="$DBRRG_BASE/storage"
readonly DBRRG_LAYERS="$DBRRG_BASE/layers"
readonly DBRRG_STATE="$DBRRG_BASE/state"

dbrrg_init_dirs() {
    dinfo "dbrrg: Creating $DBRRG_BASE"
    mkdir -p "$DBRRG_BASE" || die "Failed to create $DBRRG_BASE"

    dinfo "dbrrg: Creating storage directories"
    mkdir -p "$DBRRG_STORAGE"/efi || die "Failed to create $DBRRG_STORAGE/efi"
    mkdir -p "$DBRRG_STORAGE"/download || die "Failed to create $DBRRG_STORAGE/download"

    dinfo "dbrrg: Creating layer directories"
    mkdir -p "$DBRRG_LAYERS"/lower || die "Failed to create $DBRRG_LAYERS/lower"
    mkdir -p "$DBRRG_LAYERS"/upper || die "Failed to create $DBRRG_LAYERS/upper"

    dinfo "dbrrg: Creating state directory"
    mkdir -p "$DBRRG_STATE" || die "Failed to create state dir"

    info "dbrrg: Directory structure created"
    dinfo "dbrrg:   Base: $DBRRG_BASE"
    dinfo "dbrrg:   EFI mount: $DBRRG_STORAGE/efi"
}

is_remote_url() {
    case "$1" in
        http://*|https://*|ftp://*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

verify_squashfs() {
    local sqsh_path="$1"

    [ -f "$sqsh_path" ] || die "SquashFS not found: $sqsh_path"

    local size=$(stat -c%s "$sqsh_path" 2>/dev/null)
    [ "$size" -gt 52428800 ] || die "SquashFS too small: $size bytes"

    local magic=$(dd if="$sqsh_path" bs=4 count=1 status=none 2>/dev/null | od -An -tx1 | tr -d ' \012')
    [ "$magic" = "68737173" ] || die "Invalid squashfs magic: $magic"

    info "SquashFS verified: $size bytes"
}

create_zram_overlay() {
    local size="${1:-2G}"

    # Log to kmsg/console only (NOT info() which pollutes stdout with systemd)
    echo "<30>dracut: Creating ZRAM device (size: $size)" > /dev/kmsg
    echo "Creating ZRAM device (size: $size)" > /dev/console 2>/dev/null

    modprobe zram 2>/dev/null || die "Failed to load zram module"
    [ -d /sys/class/zram-control ] || die "ZRAM not available"

    local zram_id=$(cat /sys/class/zram-control/hot_add 2>/dev/null)
    [ -n "$zram_id" ] || die "Failed to create zram device"

    local zram_dev="zram${zram_id}"
    local zram_path="/dev/$zram_dev"

    echo zstd > /sys/block/$zram_dev/comp_algorithm 2>/dev/null || true
    echo 4 > /sys/block/$zram_dev/max_comp_streams 2>/dev/null || true
    echo "$size" > /sys/block/$zram_dev/disksize || die "Failed to set ZRAM size"

    mkfs.ext4 -q -O ^has_journal,^metadata_csum,^ext_attr -m 0 -b 4096 "$zram_path" || \
        die "Failed to format ZRAM"

    echo "<30>dracut: ZRAM device ready: $zram_path" > /dev/kmsg
    echo "ZRAM device ready: $zram_path" > /dev/console 2>/dev/null

    # Return ONLY the device path on stdout
    echo "$zram_path"
}

get_machine_id() {
    local efi_mount="$DBRRG_STORAGE/efi"
    local machine_id=""

    if mountpoint -q "$efi_mount" 2>/dev/null; then
        local id_file="$efi_mount/config/machine-id"
        if [ -f "$id_file" ]; then
            machine_id=$(cat "$id_file" 2>/dev/null | tr -d '\012')
            if [ -n "$machine_id" ]; then
                echo "<30>dracut: Loaded machine-id from EFI" > /dev/kmsg
                echo "$machine_id"
                return 0
            fi
        fi
    fi

    machine_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | tr -d '\012')
    [ -n "$machine_id" ] || die "Failed to generate machine-id"

    echo "<30>dracut: Generated new machine-id" > /dev/kmsg

    if mountpoint -q "$efi_mount" 2>/dev/null; then
        mkdir -p "$efi_mount/config" 2>/dev/null
        echo "$machine_id" > "$efi_mount/config/machine-id" 2>/dev/null || true
    fi

    echo "$machine_id"
}

setup_loop_device() {
    local sqsh_path="$1"
    local readahead="${2:-128}"

    modprobe loop 2>/dev/null || true

    # Log to kmsg and console (NOT using info() which pollutes stdout with systemd)
    echo "<30>dracut: Setting up loop device for $sqsh_path" > /dev/kmsg
    echo "Setting up loop device for $sqsh_path" > /dev/console 2>/dev/null

    local loop_dev=$(losetup --find --show --read-only "$sqsh_path" 2>/dev/null)
    if [ -z "$loop_dev" ]; then
        die "losetup failed to create loop device"
    fi

    echo "<30>dracut: losetup returned: $loop_dev" > /dev/kmsg
    echo "losetup returned: $loop_dev" > /dev/console 2>/dev/null

    # Wait for udev to create the device node
    udevadm settle --timeout=5 2>/dev/null || true

    # Additional wait with retries
    local retries=30
    while [ $retries -gt 0 ]; do
        [ -b "$loop_dev" ] && break
        sleep 0.2
        retries=$((retries - 1))
    done

    [ -b "$loop_dev" ] || die "Loop device not ready: $loop_dev"

    # Set read-ahead (optional, non-fatal)
    command -v blockdev >/dev/null 2>&1 && blockdev --setra "$readahead" "$loop_dev" 2>/dev/null

    echo "<30>dracut: Loop device ready: $loop_dev" > /dev/kmsg
    echo "Loop device ready: $loop_dev" > /dev/console 2>/dev/null

    # Return ONLY the device path on stdout
    echo "$loop_dev"
}

fi  # end of _DBRRG_LIB_LOADED guard
