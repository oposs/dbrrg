#!/bin/sh
set -e
cd /ipxe/src
cp bin-x86_64-pcbios/ipxe.pxe /image-export
cp bin-x86_64-pcbios/undionly.kpxe /image-export
cp bin-x86_64-efi/ipxe.efi /image-export

