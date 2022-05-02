#!/bin/sh
set -e
echo "Exporting Kernel and Initramfs"
cp /boot/initrd.img-* /image-export/initrd.img
cp /boot/vmlinuz-* /image-export/vmlinuz
echo "Building ramroot.tar.xz"
rm -rf /boot /usr/lib/modules/*
# keep only the intel wifi firmware around
find /usr/lib/firmware -type f -not -name "iwlwifi*" -print0 | xargs --null rm -f
tar -Ipixz -cf /image-export/ramroot.tar.xz --one-file-system -C / .
chmod 644 image-export/*
echo "Image export complete"
