#!/bin/sh
set -e
SIZE=600
cd /image-export
IMG=thinlinc-efi-boot.img
MD="mmd -i ${IMG}@@1M"
CP="mcopy -i ${IMG}@@1M"
RN="mren -i ${IMG}@@1M"
FM="mformat -i ${IMG}@@1M"
echo Creating empty $IMG file
dd if=/dev/zero bs=1M count=$SIZE of=$IMG
parted -s ${IMG} 'mktable gpt' 'mkpart "EFI-SYSTEM" fat32 1MiB '$(($SIZE-1))'MiB' 'set 1 esp on'

$FM -F ::
$MD ::efi
$CP -s /refind ::efi/boot
$RN ::efi/boot/refind_x64.efi ::efi/boot/bootx64.efi
$CP /refind.conf ::efi/boot

$MD ::tl
$CP initrd.img vmlinuz ramroot.tar.xz ::tl

$MD ::efi/tools
$MD ::efi/tools/memtest86
$CP /memtest86/unifont.bin /memtest86/blacklist.cfg /memtest86/mt86.png ::efi/tools/memtest86
$CP /memtest86/BOOTX64.efi ::efi/tools/memtest86/memtest86.efi
$CP /ShellBinPkg/UefiShell/X64/Shell.efi ::efi/tools/shell.efi


echo #########################################################
echo to copy the image to an usb stick you could use
echo $ dd if=${IMG} of=/dev/sdX bs=1M status=progress conv=fsync
echo #########################################################
