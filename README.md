# dbrrg - Docker-Based RamRoot Generator v2.0

Modern diskless Linux system using SquashFS + OverlayFS + ZRAM + Dracut.

Features A/B firmware updates with automatic fallback support.

## Quick Start

```bash
# Build complete USB image
make

# Or just build rootfs
make rootfs

# Build iPXE network boot loaders
make ipxe

# Clean and rebuild
make clean && make
```

## Architecture

- **SquashFS**: Compressed read-only root filesystem
- **OverlayFS**: Writable layer on top of squashfs
- **ZRAM**: Compressed RAM storage for writes (2GB virtual, ~500MB actual)
- **Dracut**: Modern modular initramfs system

## Memory Usage

### USB Boot
- SquashFS: 0MB (on USB stick)
- Page cache: 200-800MB (adaptive)
- ZRAM overlay: ~500MB
- **Total: 0.7-1.3GB**

### Network Boot
- SquashFS: ~400MB (in RAM)
- Page cache: 200-800MB (adaptive)
- ZRAM overlay: ~500MB
- **Total: 1.1-1.7GB**

## Directory Structure

```
dbrrg/
├── Makefile                    # Build system
├── build/                      # Build scripts
│   ├── lib/common.sh
│   ├── export-rootfs.sh
│   └── make-bootable-image.sh
├── containers/                 # Container definitions
│   ├── ubuntu/Dockerfile
│   ├── image-builder/Dockerfile
│   └── ipxe/Dockerfile
├── configs/                    # Configuration files
│   └── syslinux.cfg
├── overlay/                    # Rootfs customizations
│   ├── usr/lib/dracut/modules.d/90dbrrg/  # Dracut module
│   └── etc/sysctl.d/99-dbrrg-memory.conf  # Memory tuning
└── artifacts/                  # Build outputs (gitignored)
    ├── rootfs/
    │   ├── vmlinuz
    │   ├── initrd.img
    │   ├── ramroot.sqsh
    │   ├── ipxe.pxe
    │   ├── undionly.kpxe
    │   └── ipxe.efi
    └── images/
        ├── dbrrg-usb.img
        ├── dbrrg-usb.img.zst
        └── dbrrg-usb.img.zst.sha256
```

## Boot Parameters

### USB Boot
```
ramroot=tl/ramroot.sqsh
```

### Network Boot
```
ramroot=http://server/boot/ramroot.sqsh rd.neednet=1 ip=dhcp
```

### Debug Mode
```
rd.debug rd.shell rd.dbrrg.debug rd.break=pre-mount
```

## Configuration

Edit `Makefile` variables:
- `SQUASHFS_COMP=zstd` - Compression algorithm (zstd, xz, lz4)
- `SQUASHFS_COMP_LEVEL=3` - Compression level (1-19, lower = faster)
- `EFI_PARTITION_SIZE=2000` - EFI partition size in MB

## Deployment

### USB Stick
```bash
# Write compressed image to USB (recommended)
zstd -d < artifacts/images/dbrrg-usb.img.zst | dd of=/dev/sdX bs=1M status=progress conv=fsync

# Or write uncompressed image
dd if=artifacts/images/dbrrg-usb.img of=/dev/sdX bs=1M status=progress conv=fsync
```

### Upgrading Firmware

Use the interactive `upgrade-image` script on a running system:

```bash
sudo upgrade-image
```

Features:
- **Drive selection**: Choose which USB to upgrade
- **Boot USB detection**: Safe additive upgrade when running from the target USB
- **A/B fallback**: Previous version kept as fallback (type `previous` at boot menu)

Upgrade modes:
- **Additive** (boot USB): Writes new firmware to `tl.new/`, keeps `tl/` as fallback
- **In-place** (other USB): Rotates `tl/` → `tl.old/`, installs new `tl/`
- **Full image**: Complete rewrite with data backup/restore

### Network Boot (PXE/iPXE)
```bash
# Build iPXE boot loaders
make ipxe

# Copy files to TFTP/HTTP server
cp artifacts/rootfs/ipxe.pxe /var/lib/tftpboot/
cp artifacts/rootfs/ipxe.efi /var/lib/tftpboot/
cp artifacts/rootfs/vmlinuz artifacts/rootfs/initrd.img /var/www/html/boot/
cp artifacts/rootfs/ramroot.sqsh /var/www/html/boot/

# Configure DHCP to serve iPXE, then chainload to kernel with:
ramroot=http://your-server/boot/ramroot.sqsh
```

## Migration from v1.x

See `MIGRATION.md` for detailed migration guide.

## Troubleshooting

### Build Issues
```bash
# Check podman is working
podman --version

# Clean and rebuild
make clean && make
```

### Boot Issues
```bash
# Use debug mode in syslinux.cfg
rd.debug rd.shell rd.dbrrg.debug

# Check logs after boot
cat /var/log/dracut-boot.log
cat /var/log/dbrrg/*
```

### Memory Issues
Edit `overlay/etc/sysctl.d/99-dbrrg-memory.conf`:
- Increase `vm.vfs_cache_pressure` to 200 (more aggressive cache eviction)
- Decrease ZRAM size in dracut module

## Development

### Test Dracut Module
```bash
# Rebuild initramfs quickly
dracut --force --add dbrrg

# Test in QEMU
qemu-system-x86_64 -m 4G -enable-kvm \
  -drive file=artifacts/images/dbrrg-usb.img,format=raw
```

### Modify Boot Process
Edit files in `overlay/usr/lib/dracut/modules.d/90dbrrg/`:
- `parse-dbrrg.sh` - Command line parsing
- `finalize-upgrade.sh` - Activate pending tl.new/ upgrades
- `mount-squashfs.sh` - SquashFS mounting
- `setup-overlay.sh` - Overlay setup

Rebuild with `make rootfs`

## A/B Update System

The system supports A/B firmware updates with automatic fallback:

### Directory Structure
```
EFI-SYSTEM partition:
├── tl/           # Current firmware (or tl.new/ after additive upgrade)
├── tl.old/       # Previous firmware (fallback)
├── config/       # Persistent configuration
└── home.tar.gz   # User home backup
```

### Boot Menu Options
- `current` - Boot the active firmware version
- `previous` - Boot the previous version (fallback)
- `console` - Text-only boot
- `debug` - Debug shell

### Recovery
If a new firmware version fails to boot:
1. Reboot and press any key at the boot prompt
2. Type `previous` and press Enter
3. System boots from the previous known-good version
