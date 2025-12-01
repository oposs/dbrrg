#!/bin/bash
# module-setup.sh - dbrrg dracut module

check() {
    return 255
}

depends() {
    # network-legacy is optional - we use it if available, but can work without it
    # We mainly need basic networking tools (curl, which we install ourselves)
    return 0
}

install() {
    inst_hook cmdline 30 "$moddir/parse-dbrrg.sh"
    inst_hook pre-mount 25 "$moddir/finalize-upgrade.sh"  # Finalize pending tl.new upgrade
    inst_hook mount 30 "$moddir/mount-squashfs.sh"   # Mount hooks run in mount phase
    inst_hook mount 40 "$moddir/setup-overlay.sh"    # After squashfs is mounted
    inst_hook pre-pivot 30 "$moddir/dbrrg-cleanup.sh"

    inst_simple "$moddir/dbrrg-lib.sh" "/lib/dbrrg-lib.sh"

    # Network tools
    inst_multiple curl ip dhclient

    # Filesystem tools
    inst_multiple zramctl blockdev losetup mountpoint
    inst_multiple mkfs.ext4 fsck.fat
    # Also install fsck.vfat symlink
    inst /sbin/fsck.vfat
    inst_multiple stat dd od tr mkdir mount umount
    inst_multiple udevadm awk grep sed lsblk

    # Kernel modules (only what we need)
    instmods squashfs overlay zram loop
    instmods ext4 vfat
    # Network - be selective
    instmods e1000 e1000e igb r8169 atlantic
    instmods iwlwifi iwlmvm cfg80211
    instmods af_packet

    # Firmware
    inst_multiple -o /usr/lib/firmware/iwlwifi-*

    return 0
}

installkernel() {
    instmods squashfs overlay zram loop ext4 vfat
}
