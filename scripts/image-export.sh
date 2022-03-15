#!/bin/sh
echo "Exporting Kernel and Initramfs"
cp /boot/initrd.img-* /boot/vmlinuz-* /image-export
echo "Building ramroot.tar.xz"
rm -rf /boot /usr/lib/modules/*
tar -Ipixz -cf /image-export/ramroot.tar.xz --one-file-system -C / .
chmod 644 image-export/*
echo "Image export complete"
