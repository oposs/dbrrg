#!/bin/sh
echo Createing Boot Image
set -e
#set -x
EFISIZE=640
MB=$((1024*1024))
cd /image-export
IMG=thinlinc-efi-boot.img
MD="mmd -i ${IMG}@@1M"
CP="mcopy -i ${IMG}@@1M"
RN="mren -i ${IMG}@@1M"
FM="mformat -i ${IMG}@@1M"
FSCK="fsck.fat -i ${IMG}@@1M"
echo Creating empty $IMG file
rm -f $IMG
dd if=/dev/zero bs=1M seek=$((2+EFISIZE)) count=1 of=$IMG
sgdisk \
   --new=1::+$((EFISIZE))M --change-name=1:EFI-SYSTEM --typecode=1:ef00 --attributes=1:set:2 \
   --hybrid=1 ${IMG}
sgdisk ${IMG}
mkfs.fat -v -I -S 512 -s 1 --offset 2048 -n EFI-SYSTEM ${IMG} $((EFISIZE*1024))
#$FM -F ::
$DIR
$MD ::efi
$MD ::efi/boot
$CP /usr/lib/SYSLINUX.EFI/efi64/syslinux.efi ::efi/boot/bootx64.efi
$CP /usr/lib/syslinux/modules/efi64/ldlinux.e64 ::efi/boot/ldlinux.e64
dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/gptmbr.bin of=${IMG}
syslinux --offset $MB --install ${IMG}
$CP /syslinux.cfg ::syslinux.cfg
$MD ::tl
$CP initrd.img vmlinuz ramroot.tar.xz ::tl


echo ###################################################################
echo $ dd if=${IMG} of=/dev/sdX bs=1M status=progress conv=fsync
echo $ scp -C image-export/${IMG}  oetiker@web-volki-01-adm:public_html/test
echo ################################################################