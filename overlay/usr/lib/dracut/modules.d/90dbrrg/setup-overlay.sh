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

# Name the machine after its machine-id. mksquashfs runs inside the build
# container, where podman bind-mounts /etc/hostname, so the image used to ship
# the container ID (fa0ad0f31bfa) and every machine had the same name. The file
# is now excluded from the squashfs. Writing it here means systemd PID 1 reads
# the right name from /etc/hostname at startup, before it loads any unit: the
# first journal line carries it, and %H in un-dockerize.service's /etc/hosts
# substitution expands to it. The machine-id is persisted on the ESP, so the
# name is stable per machine. Six hex characters are used.
dbrrg_write_hostname "$NEWROOT" "$machine_id"

# Restore the home directory here, in the initramfs, rather than at login.
#
# It has to be in place before multi-user.target so dbrrg-ssh-hostkeys can
# take the persistent SSH host keys out of it before sshd starts. Doing it
# at login - where it used to happen - is far too late for that.
#
# restore_home always returns 0; a client that cannot reach its home archive
# still boots with the shipped default home.
restore_home "$NEWROOT" "$DBRRG_STORAGE/efi" "$DBRRG_STATE" \
    "$(cat /tmp/dbrrg-ramroot 2>/dev/null)"

# Install ~/wifi.yaml and ~/wg0.conf into /etc now, before systemd starts in
# the new root, so the netplan generator sees them. Always returns 0.
install_local_network "$NEWROOT"

echo "$zram_dev" > "$DBRRG_STATE/zram-device"

return 0
