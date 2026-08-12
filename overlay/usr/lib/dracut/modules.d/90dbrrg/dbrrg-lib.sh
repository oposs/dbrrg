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

readonly DBRRG_EFI_DEV="/dev/disk/by-partlabel/EFI-SYSTEM"
# Set once a wait has already exhausted its budget in this boot, so a later
# hook fails fast instead of repeating the whole timeout.
readonly DBRRG_EFI_ABSENT_MARKER="/run/dbrrg-efi-absent"

# dbrrg_wait_for_efi [timeout_seconds]
#
# Wait for the boot medium's EFI-SYSTEM partition to appear. Returns 0 as soon
# as it exists, 1 if the budget expires.
#
# This polls rather than checking once. `udevadm settle` only drains events
# that are ALREADY queued: if the USB host controller has not yet enumerated
# the stick, that queue is empty and settle returns immediately. The previous
# "settle; sleep 2; test once; give up" sequence therefore granted the device
# barely two seconds. A USB 3 stick on real hardware routinely needs longer,
# while QEMU's virtio-blk appears at once - which is why this failed only on
# hardware and never in the VM.
#
# The bootloader having loaded the kernel from this same partition proves
# nothing about the kernel's view: UEFI firmware used its own USB stack, and
# the kernel re-enumerates the bus from scratch.
dbrrg_wait_for_efi() {
    _dwfe_timeout="${1:-${DBRRG_DEVICE_TIMEOUT:-60}}"
    _dwfe_waited=0

    [ -b "$DBRRG_EFI_DEV" ] && return 0
    [ -e "$DBRRG_EFI_ABSENT_MARKER" ] && return 1

    while [ ! -b "$DBRRG_EFI_DEV" ]; do
        if [ "$_dwfe_waited" -ge "$_dwfe_timeout" ]; then
            : > "$DBRRG_EFI_ABSENT_MARKER" 2>/dev/null || true
            return 1
        fi
        if [ $((_dwfe_waited % 5)) -eq 0 ]; then
            dbrrg_log "Waiting for EFI-SYSTEM to appear (${_dwfe_waited}/${_dwfe_timeout}s)"
        fi
        udevadm settle --timeout=5 >/dev/null 2>&1 || true
        sleep 1
        _dwfe_waited=$((_dwfe_waited + 1))
    done

    [ "$_dwfe_waited" -gt 0 ] && dbrrg_log "EFI-SYSTEM appeared after ${_dwfe_waited}s"
    return 0
}

# Log what block devices the kernel can actually see. Called before giving up,
# so the operator sees evidence instead of only "not found".
dbrrg_dump_block_devices() {
    dbrrg_log "Block devices visible to the kernel:"
    blkid 2>&1 | while read -r _ddbd_line; do dbrrg_log "  $_ddbd_line"; done
    dbrrg_log "Partition labels present:"
    ls -l /dev/disk/by-partlabel/ 2>&1 | while read -r _ddbd_line; do dbrrg_log "  $_ddbd_line"; done
}

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

# dbrrg_home_url <ramroot-url> <mac>
#
# Build the URL the home archive lives at on the boot server, from the same
# ramroot URL the squashfs came from: .../tl/ramroot.sqsh -> .../tl/home.pkg
#
# dbrrg-save-home derives the identical base with a greedy sed over
# /proc/cmdline. Both reduce to "the directory the ramroot URL sits in", and
# they must not be allowed to diverge - a mismatch means the client posts its
# home somewhere it will never look for it again.
dbrrg_home_url() {
    _dhu_ramroot="$1"
    _dhu_mac="$2"

    [ -n "$_dhu_ramroot" ] || return 1
    [ -n "$_dhu_mac" ] || return 1

    echo "${_dhu_ramroot%/*}/home.pkg?mac=${_dhu_mac}"
}

# dbrrg_record_boot_mac <address-file> <state-dir>
#
# Persist the MAC of the interface the initramfs actually brought up, so
# dbrrg-save-home posts the home archive back under the same key the restore
# fetched it with.
#
# Before this, both halves derived the MAC independently from kernel ifindex
# 2 - which agreed only because both ran in the booted system. ifindex
# follows driver registration order, the initramfs loads a deliberately small
# driver set, and mount-squashfs.sh picks its interface by /sys/class/net
# glob order instead; on a machine with two NICs those can name different
# devices. Recording what was actually used makes the two halves agree by
# construction. It is also the better identity: on netboot it is the
# interface that demonstrably worked, having taken a DHCP lease and served
# ramroot.sqsh.
dbrrg_record_boot_mac() {
    _drbm_addr_file="$1"
    _drbm_state_dir="$2"

    if [ ! -r "$_drbm_addr_file" ]; then
        warn "dbrrg: cannot read MAC from $_drbm_addr_file"
        return 1
    fi

    _drbm_mac=$(cat "$_drbm_addr_file" 2>/dev/null | tr -d '\012')
    if [ -z "$_drbm_mac" ]; then
        warn "dbrrg: empty MAC in $_drbm_addr_file"
        return 1
    fi

    mkdir -p "$_drbm_state_dir" 2>/dev/null || true
    if ! echo "$_drbm_mac" > "$_drbm_state_dir/boot-mac" 2>/dev/null; then
        warn "dbrrg: could not write $_drbm_state_dir/boot-mac"
        return 1
    fi

    return 0
}

# dbrrg_restore_home_from_file <archive> <target-home>
#
# Extract a home archive over the target home directory. Returns non-zero on
# a missing or unreadable archive; both are normal (first boot, or a machine
# whose home was never saved) and must leave the shipped default home in
# place rather than aborting the boot.
dbrrg_restore_home_from_file() {
    _drhf_archive="$1"
    _drhf_home="$2"

    if [ ! -f "$_drhf_archive" ]; then
        warn "dbrrg: no home archive at $_drhf_archive"
        return 1
    fi

    if ! mkdir -p "$_drhf_home" 2>/dev/null; then
        warn "dbrrg: cannot create $_drhf_home"
        return 1
    fi

    # A payload that is valid gzip but not a tar decompresses cleanly, lists
    # zero members, and makes GNU tar exit 0 - measured, not assumed. Trusting
    # that exit code would report a successful restore having restored
    # nothing, and the damage compounds: dbrrg-ssh-hostkeys would then treat
    # the machine as keyless and generate fresh host keys, and
    # dbrrg-save-home would overwrite the user's good archive with the empty
    # one at logout. A boot server answering 200 with a gzip-encoded error
    # page is enough, and curl -f does not catch a 200. So require the
    # archive to contain at least one member before trusting it.
    if [ -z "$(tar -tzf "$_drhf_archive" 2>/dev/null | sed -n '1p;q')" ]; then
        warn "dbrrg: $_drhf_archive is not a usable tar archive"
        return 1
    fi

    # tar's default as root is --same-owner, and that is REQUIRED here, not
    # incidental. dbrrg-save-home writes the archive as tluser, so members
    # carry uid/gid 1000 numerically; preserving them is what makes the
    # restored home belong to tluser. Do NOT add --no-same-owner.
    #
    # Note this is the exact OPPOSITE of what dbrrg-ssh-hostkeys must do a
    # few files away: host keys come out of this same archive tluser-owned
    # and have to be forced to root:root before sshd will touch them. Two
    # different problems; do not "make them consistent".
    if ! tar -xzf "$_drhf_archive" -C "$_drhf_home" 2>/dev/null; then
        warn "dbrrg: home archive $_drhf_archive did not extract cleanly"
        return 1
    fi

    return 0
}

# dbrrg_restore_home_from_url <url> <target-home> [timeout] [tmp-file]
#
# Fetch a home archive from the boot server and extract it. Downloads to a
# temporary file first: piping curl straight into tar would extract a
# half-written archive over the home directory if the transfer died midway.
dbrrg_restore_home_from_url() {
    _drhu_url="$1"
    _drhu_home="$2"
    _drhu_timeout="${3:-120}"
    _drhu_tmp="${4:-/tmp/dbrrg-home.pkg}"

    rm -f "$_drhu_tmp" 2>/dev/null || true

    # -f makes an HTTP 404 a failure rather than a saved error page. A 404
    # is the ordinary first-netboot case for a machine the server has not
    # seen before, so it is warned about and not treated as a fault.
    #
    # --connect-timeout and --max-time are mandatory. The login-time script
    # this replaces waited on `while true; do ping ...; done`; unbounded at
    # login is a session recoverable from a VT, but unbounded here is a
    # machine that never finishes booting.
    if ! curl -f -s -S \
            --connect-timeout 10 --max-time "$_drhu_timeout" \
            -o "$_drhu_tmp" "$_drhu_url" 2>/dev/null; then
        warn "dbrrg: could not fetch home archive from $_drhu_url"
        rm -f "$_drhu_tmp" 2>/dev/null || true
        return 1
    fi

    dbrrg_restore_home_from_file "$_drhu_tmp" "$_drhu_home"
    _drhu_rc=$?
    rm -f "$_drhu_tmp" 2>/dev/null || true
    return $_drhu_rc
}

# restore_home <newroot> <efi-mount> <state-dir> <ramroot>
#
# Populate /home/tluser in the new root before the pivot.
#
# This used to run at login, from /etc/profile.d/10-dbrrg-session.sh. It runs
# here now so the home directory exists before multi-user.target, which is
# what lets the SSH host keys persist inside it - see
# overlay/usr/bin/dbrrg-ssh-hostkeys.
#
# Moving it EARLIER does not violate the standing rule recorded in
# 10-dbrrg-session.sh. That rule forbids moving the restore back INTO
# dbrrg-session, because ~/.dbrrg-environment must be on disk before labwc
# reads XKB_DEFAULT_* at startup. The initramfs is earlier still, so the
# ordering constraint holds a fortiori.
#
# ALWAYS returns 0. It is called from setup-overlay.sh, where a non-zero
# return aborts the boot. A client that cannot restore its home must still
# come up with the shipped default one.
restore_home() {
    _rh_newroot="$1"
    _rh_efi="$2"
    _rh_state="$3"
    _rh_ramroot="$4"

    _rh_home="$_rh_newroot/home/tluser"

    if is_remote_url "$_rh_ramroot"; then
        _rh_mac=$(cat "$_rh_state/boot-mac" 2>/dev/null | tr -d '\012')
        if [ -z "$_rh_mac" ]; then
            # Deliberately do not fall back to guessing an interface. A
            # wrong MAC means fetching one machine's home onto another, or
            # saving to a key nothing will ever read back.
            warn "dbrrg: no boot MAC recorded, skipping home restore"
            return 0
        fi

        _rh_url=$(dbrrg_home_url "$_rh_ramroot" "$_rh_mac") || return 0

        # Record the base the URL was built from, for the same reason the MAC
        # is recorded: so dbrrg-save-home posts to the identical location
        # rather than re-deriving it.
        #
        # save-home derives the base with a greedy sed over the whole
        # /proc/cmdline (s/.*ramroot=\(.*\)\/.*$/\1/). That backtracks to the
        # LAST slash anywhere in the command line, so any kernel parameter
        # appearing after ramroot= that contains a "/" - root=/dev/sda1,
        # init=/sbin/init - silently yields a wrong base. Today's
        # configs/syslinux.cfg happens to have no such parameter, so the bug
        # is latent rather than live; recording the resolved value here
        # removes the whole class instead of relying on that staying true.
        echo "${_rh_ramroot%/*}" > "$_rh_state/boot-home-base" 2>/dev/null || \
            warn "dbrrg: could not record boot-home-base"

        dbrrg_log "dbrrg: restoring home from $_rh_url"
        dbrrg_restore_home_from_url "$_rh_url" "$_rh_home" 120 || true
    else
        dbrrg_log "dbrrg: restoring home from $_rh_efi/home.tar.gz"
        dbrrg_restore_home_from_file "$_rh_efi/home.tar.gz" "$_rh_home" || true
    fi

    return 0
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
