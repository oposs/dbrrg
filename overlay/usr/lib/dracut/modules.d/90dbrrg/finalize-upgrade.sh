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
# Read ramroot= from the kernel command line, not from /tmp/dbrrg-ramroot.
# dracut-pre-mount.service is ordered only after dracut-initqueue.service,
# which is not part of the boot transaction here, so this hook runs in
# parallel with the cmdline hook that writes that file - measured with
# rd.debug, half a second before it. The file was therefore missing, a
# netboot was taken for a USB boot, and the boot waited 60s for an ESP
# that does not exist.
ramroot=$(getarg ramroot=)
if is_remote_url "$ramroot"; then
    dbrrg_log "finalize-upgrade: Network boot - skipping"
    exit 0
fi

# Wait for the boot medium. This hook runs BEFORE mount-squashfs, so it is
# usually the first thing in the boot to look for the device - and it used to
# check once after `udevadm settle`, which returns immediately when the USB
# controller has not enumerated the stick yet. See dbrrg_wait_for_efi().
#
# Getting this wrong here is quieter and nastier than in mount-squashfs: a
# pending tl.new upgrade would simply not be finalized, mount-squashfs would
# then find the device a moment later and boot the OLD tl/, and the machine
# would come up looking perfectly healthy with the upgrade silently skipped -
# possibly applying on some later boot instead. Upgrades must not be a race.
EFI_DEV="$DBRRG_EFI_DEV"
if ! dbrrg_wait_for_efi; then
    # Still non-fatal: mount-squashfs runs next and will report authoritatively
    # if the device never appears. But say plainly that a pending upgrade is
    # being skipped, rather than implying there was simply nothing to do.
    dbrrg_log "finalize-upgrade: EFI-SYSTEM did not appear - skipping"
    dbrrg_log "finalize-upgrade: a pending tl.new upgrade (if any) was NOT applied"
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

# The rotation itself lives in dbrrg_finalize_upgrade() in dbrrg-lib.sh, so
# test/integration/test-initramfs-home.sh can run it with only the commands
# the initramfs actually has.
dbrrg_finalize_upgrade "$efi_mount"
rc=$?

umount "$efi_mount"
rmdir "$efi_mount" 2>/dev/null

exit $rc
