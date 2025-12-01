# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dbrrg (Docker-Based RamRoot Generator) creates bootable diskless client images that run entirely from RAM. The system builds Ubuntu-based images using Podman/Docker containers, packages them into bootable formats (USB/PXE), and includes a custom initramfs boot system. The final images are designed for thin client deployments using ThinLinc.

## Build System Architecture

The build process uses containers in `containers/` directory:

1. **containers/ubuntu/Dockerfile** - Base system container that creates the Ubuntu rootfs with all packages, ThinLinc client, and custom overlay files
2. **containers/ipxe/Dockerfile** - Builds iPXE network boot loaders (PXE, KPXE, EFI formats)
3. **containers/image-builder/Dockerfile** - Final packaging container with tools to create bootable EFI images

The `overlay/` directory contains all customizations that get layered onto the base Ubuntu system during the build.

## Common Commands

### Build the complete bootable image:
```bash
make image
```
This runs the build stages and creates bootable files in `artifacts/`.

### Build only the Ubuntu base system:
```bash
make rootfs
```
Builds the container and exports kernel, initramfs, and ramroot.sqsh to `artifacts/rootfs/`.

### Build only iPXE boot loaders:
```bash
make ipxe
```
Compiles iPXE from source and exports PXE/EFI boot files to `artifacts/rootfs/`.

### Write image to USB stick:
```bash
dd if=artifacts/images/dbrrg-usb.img of=/dev/sdX bs=1M status=progress conv=fsync
```

## Boot Flow Architecture

The boot process involves several interconnected components:

1. **SYSLINUX/EFI Boot** - Initial bootloader (syslinux.cfg) loads kernel with `rd.dbrrg.ramroot=` parameter

2. **Dracut Module** (overlay/usr/lib/dracut/modules.d/90dbrrg/) - Modern initramfs using Dracut:
   - **module-setup.sh** - Installs hooks and tools into initramfs
   - **parse-dbrrg.sh** - Parses kernel command line parameters
   - **mount-squashfs.sh** - Mounts SquashFS rootfs from local or network source
   - **setup-overlay.sh** - Sets up ZRAM-backed OverlayFS for writes
   - **dbrrg-lib.sh** - Shared library functions
   - **dbrrg-cleanup.sh** - Pre-pivot cleanup

3. **Boot Process**:
   - **SquashFS Mount**: Mounts compressed read-only rootfs from USB partition or HTTP URL
   - **ZRAM Setup**: Creates compressed RAM device for writable overlay
   - **OverlayFS**: Combines read-only SquashFS with writable ZRAM layer
   - **machine-id Persistence**: Reads/generates machine-id and stores it in /config/machine-id on EFI partition

4. **Un-dockerization** (overlay/etc/systemd/system/un-dockerize.service) - First-boot service removes Docker artifacts, fixes /etc/hosts, reconfigures systemd-resolved

5. **Home Persistence** - X session scripts restore home directory at login (39dbrrg-restore-home) and save on logout (90dbrrg-start-thinlinc calls save-home)

## Key Configuration Files

- **configs/syslinux.cfg** - Boot menu and kernel parameters. The `rd.dbrrg.ramroot=` parameter determines boot source (local: `tl/ramroot.sqsh`, network: `http://server/path/ramroot.sqsh`)
- **overlay/home/tluser/.thinlinc/tlclient.conf** - ThinLinc client configuration
- **overlay/home/tluser/wifi.yaml** - WiFi configuration template for netplan
- **overlay/usr/lib/dracut/modules.d/90dbrrg/** - Dracut module for boot process

## Customizing the System

To modify the deployed system, edit files in `overlay/` following the standard Linux filesystem hierarchy. The overlay is applied during Docker build using:
```dockerfile
ADD overlay/ /__overlay
RUN tar cf - --exclude="*~" -C /__overlay . | tar xf - && rm -rf /__overlay
```

This pattern excludes editor backup files (*~) and properly applies overlay permissions. Common customization points:

- System services: `overlay/etc/systemd/system/`
- Network configuration: `overlay/etc/netplan/`
- SSH configuration: `overlay/etc/ssh/sshd_config.d/`
- X11/display settings: `overlay/etc/X11/`, `overlay/etc/default/nodm`
- User defaults: `overlay/home/tluser/`

After modifying overlay files, rebuild with `make image`.

## Persistent Home Directory

The system implements home directory persistence across reboots:

- On boot: If booting from USB (EFI-SYSTEM partition detected) or network server, restores `/home/tluser` from `home.tar.gz`
- On logout: ThinLinc client shutdown triggers `/opt/thinlinc/bin/save-home` which saves home directory back to USB or uploads to boot server via HTTP POST

This allows WiFi credentials, ThinLinc settings, and user customizations to persist.

## Network Boot vs USB Boot

The system detects boot method by checking for `/dev/disk/by-partlabel/EFI-SYSTEM`:

- **USB Boot**: Partition present → loads ramroot.sqsh from local `tl/ramroot.sqsh`, persists home to partition
- **Network Boot**: No partition → uses ramroot URL from kernel cmdline, persists home to boot server HTTP endpoint

Both modes execute identical code paths after SquashFS mount.

## Container Build Best Practices

The containers/ubuntu/Dockerfile follows several important patterns:

1. **SSH Host Keys**: Host keys are removed before building initramfs and regenerated on first boot via `regenerate_ssh_host_keys.service`. This ensures each deployed instance has unique SSH keys.

2. **Initramfs Generation**: The build uses Dracut (`dracut --force --add "dbrrg plymouth"`) to create initramfs. The custom module in `overlay/usr/lib/dracut/modules.d/90dbrrg/` is automatically included. This must run AFTER overlay files are applied and SSH keys are removed.

3. **Systemd Service Management**: Services are explicitly enabled/disabled during build to control first-boot behavior. The `un-dockerize.service` runs once and disables itself.

4. **Locale Generation**: `locale-gen` must run after overlay files are applied to process locale.gen configuration.

5. **User Configuration**: The default user (tluser) is created with no password but added to sudo group with NOPASSWD privileges for management tasks.

## Performance Optimizations

### SquashFS + OverlayFS + ZRAM Architecture

The system uses a layered approach for optimal memory usage:

- **SquashFS**: Compressed read-only root filesystem (zstd compression)
- **ZRAM**: Compressed RAM device for writable overlay layer
- **OverlayFS**: Combines SquashFS (lower) with ZRAM (upper) for a writable system

This architecture significantly reduces memory pressure compared to extracting the entire rootfs to RAM.

### machine-id Persistence

The system persists systemd's machine-id across reboots by storing it in `/config/machine-id` on the EFI partition. This is important because:

- Systemd requires a stable machine-id for proper service operation
- Without persistence, services like journald, networkd, and DHCP may behave unexpectedly
- The machine-id is generated once on first boot and reused thereafter

The EFI partition `/config/` directory can also store other persistent configuration.

## Potential Enhancements

Future improvements to consider:

1. **Firmware manifest** - Add version/checksum metadata to ramroot packages
2. **A/B update structure** - Support rollback by keeping previous version
3. **Additional output formats** - Generate qcow2 for testing in QEMU/KVM
4. **Serial console support** - Add console=ttyS0 to kernel parameters for headless debugging
