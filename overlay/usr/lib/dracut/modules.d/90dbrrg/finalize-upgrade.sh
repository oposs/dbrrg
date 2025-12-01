#!/bin/bash
# finalize-upgrade.sh - Finalize pending upgrade by rotating tl.new -> tl -> tl.old
# Runs in initramfs after auto-resize, before mount-squashfs (priority 25)
#
# When upgrade-image writes to tl.new/, this script finalizes on next boot:
# 1. Remove old fallback (tl.old/)
# 2. Move current to fallback (tl/ -> tl.old/)
# 3. Activate new version (tl.new/ -> tl/)

type info >/dev/null 2>&1 || . /lib/dracut-lib.sh
. /lib/dbrrg-lib.sh

# Only run for USB boot (not network boot)
ramroot=$(cat /tmp/dbrrg-ramroot 2>/dev/null)
if is_remote_url "$ramroot"; then
    dbrrg_log "finalize-upgrade: Network boot - skipping"
    exit 0
fi

# Wait for device
udevadm settle --timeout=30

EFI_DEV="/dev/disk/by-partlabel/EFI-SYSTEM"
if [ ! -b "$EFI_DEV" ]; then
    dbrrg_log "finalize-upgrade: No EFI-SYSTEM partition found - skipping"
    exit 0
fi

# Mount EFI partition temporarily
efi_mount="/tmp/efi-finalize-$$"
mkdir -p "$efi_mount"

if ! mount -t vfat "$EFI_DEV" "$efi_mount" 2>/dev/null; then
    dbrrg_log "finalize-upgrade: Failed to mount EFI partition - skipping"
    rmdir "$efi_mount" 2>/dev/null
    exit 0
fi

# Check if upgrade is pending (tl.new exists with required files)
if [ ! -d "$efi_mount/tl.new" ]; then
    umount "$efi_mount"
    rmdir "$efi_mount" 2>/dev/null
    exit 0
fi

# Verify tl.new has required files
for file in vmlinuz initrd.img ramroot.sqsh; do
    if [ ! -f "$efi_mount/tl.new/$file" ]; then
        dbrrg_log "finalize-upgrade: tl.new/$file missing - aborting (keeping tl.new for next attempt)"
        umount "$efi_mount"
        rmdir "$efi_mount" 2>/dev/null
        exit 0
    fi
done

info "finalize-upgrade: Finalizing pending upgrade (tl.new -> tl -> tl.old)"
dbrrg_log "finalize-upgrade: Starting rotation"

# Rotate: rm tl.old, mv tl -> tl.old, mv tl.new -> tl
if [ -d "$efi_mount/tl.old" ]; then
    info "finalize-upgrade: Removing old fallback (tl.old)"
    rm -rf "$efi_mount/tl.old" || {
        dbrrg_log "finalize-upgrade: Failed to remove tl.old"
        umount "$efi_mount"
        rmdir "$efi_mount" 2>/dev/null
        exit 1
    }
fi

if [ -d "$efi_mount/tl" ]; then
    info "finalize-upgrade: Moving current to fallback (tl -> tl.old)"
    mv "$efi_mount/tl" "$efi_mount/tl.old" || {
        dbrrg_log "finalize-upgrade: Failed to move tl to tl.old"
        umount "$efi_mount"
        rmdir "$efi_mount" 2>/dev/null
        exit 1
    }
    # Sync after critical move to ensure FAT32 directory entries are written
    sync
fi

info "finalize-upgrade: Activating new version (tl.new -> tl)"
if ! mv "$efi_mount/tl.new" "$efi_mount/tl"; then
    dbrrg_log "finalize-upgrade: CRITICAL - Failed to move tl.new to tl!"
    # Try to restore - this is critical for bootability
    if [ -d "$efi_mount/tl.old" ]; then
        if mv "$efi_mount/tl.old" "$efi_mount/tl"; then
            dbrrg_log "finalize-upgrade: Recovered by restoring tl.old -> tl"
            sync
        else
            dbrrg_log "finalize-upgrade: FATAL - Recovery failed! System may be unbootable!"
            dbrrg_log "finalize-upgrade: tl.new exists but couldn't be moved, tl.old couldn't be restored"
        fi
    else
        dbrrg_log "finalize-upgrade: FATAL - No tl.old to restore! System may be unbootable!"
    fi
    umount "$efi_mount"
    rmdir "$efi_mount" 2>/dev/null
    # Don't exit with error - let boot continue and possibly fail at mount-squashfs
    # This gives the user a chance to see the error messages
    exit 0
fi

sync

umount "$efi_mount"
rmdir "$efi_mount" 2>/dev/null

info "finalize-upgrade: Upgrade finalized successfully"
dbrrg_log "finalize-upgrade: Complete - now booting from new tl/"

exit 0
