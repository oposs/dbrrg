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

1. **SYSLINUX/EFI Boot** - Initial bootloader (syslinux.cfg) loads kernel with `ramroot=` parameter

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

5. **Home Persistence** - `overlay/usr/local/bin/dbrrg-session` (run by labwc via `labwc -S`) restores the home directory at login (`dbrrg-restore-home`) and saves it on logout, after the ThinLinc client exits (`save-home`)

## Key Configuration Files

- **configs/syslinux.cfg** - Boot menu and kernel parameters. The `ramroot=` parameter determines boot source (local: `tl/ramroot.sqsh`, network: `http://server/path/ramroot.sqsh`)
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
- Session/compositor: `overlay/etc/dbrrg/labwc/` (`rc.xml`, `environment`) - kept outside `$HOME` because home is captured/restored wholesale by the persistence machinery, see [Persistent Home Directory](#persistent-home-directory)
- Session startup: `overlay/usr/local/bin/dbrrg-session`, `overlay/etc/profile.d/10-dbrrg-session.sh`
- **Per-machine user customisation:** `overlay/home/tluser/.dbrrg-sessionrc` — the Wayland replacement for `~/.xsessionrc`. Sourced by `dbrrg-session` after the home restore and before the ThinLinc client. Because it lives in `$HOME` it is captured by `save-home` and restored each boot, so a user can configure an individual machine without rebuilding the image. This is where display layout goes: **`wlr-randr` replaces `xrandr`** (`--output DP-1 --transform 90 --pos 1920,0`), and `kanshi` is available for layouts that must survive hotplug or DPMS wake. It must run before `tlclient`, because the client reads the monitor layout once at startup.

- **Per-machine user environment:** `overlay/home/tluser/.dbrrg-environment` — variables the compositor reads at **startup**: keyboard layout (`XKB_DEFAULT_*`) and cursor theme. Sourced by `overlay/etc/profile.d/10-dbrrg-session.sh` after `/etc/dbrrg/labwc/environment`, so the user's value wins. Also persisted via `save-home`.

  | variable | default | effect |
  | --- | --- | --- |
  | `LABWC_FULLSCREEN_SPAN_OUTPUTS` | `1` | fullscreen Xwayland windows (the ThinLinc client) span every monitor; set `0` here for single-monitor fullscreen on this machine only |

  **The two user files are split by timing, and it is not arbitrary:**

  | file | sourced | for |
  | --- | --- | --- |
  | `~/.dbrrg-environment` | before the compositor starts | variables read at startup — keyboard, cursor |
  | `~/.dbrrg-sessionrc` | inside the running session | commands needing a compositor — `wlr-randr`, `kanshi`, netplan |

  This is why `dbrrg-restore-home` runs in `10-dbrrg-session.sh` **before** launching labwc, rather than from `dbrrg-session` as the X11 setup did: a user's saved `.dbrrg-environment` has to be on disk before the compositor reads `XKB_DEFAULT_*`. Restoring home inside the session would make a user keyboard change take effect only on the *next* boot. Do not move the restore back into `dbrrg-session`.

  Note the deliberate split from system config: user-editable settings live in `$HOME`, but `overlay/etc/dbrrg/labwc/rc.xml` does **not** — see [Standing Constraints](#standing-constraints).
- Autologin: `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf`
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

2. **Initramfs Generation**: The build uses Dracut (`dracut --force --no-hostonly --add "dbrrg plymouth"`) to create initramfs. The `--no-hostonly` flag is mandatory - see [Standing Constraints](#standing-constraints). The custom module in `overlay/usr/lib/dracut/modules.d/90dbrrg/` is automatically included. This must run AFTER overlay files are applied and SSH keys are removed.

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

## Standing Constraints

Three rules in this repository look like ordinary configuration but are
load-bearing. All three have caused shipped-image bugs.

### Firmware is selected by package, never by cleanup

`scripts/export-rootfs.sh` once ran
`find /usr/lib/firmware -type f -not -name "iwlwifi*" -delete` before
`mksquashfs`. It silently deleted i915 GPU firmware (wedged GPUs in the
field) and `intel-ucode` (no CPU microcode updates, ever) from every image.
The `-type f` predicate also does not match symlinks, and a large fraction
of `/usr/lib/firmware` is symlinks - roughly 93 of them pointed at files the
same `find` had just deleted, so the sweep also left the tree full of
dangling firmware symlinks with no missing-file error to flag it, a symptom
that could otherwise be misdiagnosed as something else entirely.

Ubuntu 26.04 splits `linux-firmware` per vendor, and `linux-firmware-minimal`
satisfies `linux-image-generic`'s hard dependency via `Provides` while only
*recommending* the rest. The installed set is therefore exactly what
`containers/ubuntu/Dockerfile` lists, given `--no-install-recommends`.

Never add a `find`/`rm -rf` sweep over `/usr/lib/firmware`. To change the
firmware set, change the package list. `test/integration/test-firmware.sh`
guards this - run via `make test`.

### dracut must be invoked with --no-hostonly

`containers/ubuntu/Dockerfile` passes `--no-hostonly` to dracut. Removing it
silently breaks the initramfs.

dracut 110 defaults `hostonly` to `-h` unless told otherwise
(`/usr/bin/dracut:1361`). Because `podman build` shares the host kernel, that
makes every `instmods` call filter against **the build machine's** loaded
modules rather than the target hardware's. Measured on this repo: the shipped
initramfs went from 683 modules to 955 once the flag was added - zram, e1000,
e1000e, igb, r8169, atlantic and iwlwifi had all been silently dropped. ZRAM's
absence aborts the boot outright; the missing NIC drivers would have broken
network/PXE boot. (An isolated probe build without `--omit-drivers` showed 968;
955 is the real figure for the shipped flag set.)

It also made builds non-reproducible: the initramfs varied with whatever the
build machine happened to have loaded. `overlay` survived only because podman's
storage driver keeps overlayfs loaded.

The older dracut on 24.04 defaulted to generic, which is why the existing
comment ("Keep it generic (no --hostonly)") was true when written and became
false on dracut 110. `--add-drivers` is not a substitute: it bypasses the
filter for its own arguments only (`dracut:2768`), leaving every module
requested by `90dbrrg/module-setup.sh` still filtered.

### labwc must have zero keybindings

`overlay/etc/dbrrg/labwc/rc.xml` has a `<keyboard>` section with no
`<default />` and no `<keybind>` entries. This is mandatory. The config
directory lives at `/etc/dbrrg/labwc`, not under `$HOME` - see
[Persistent Home Directory](#persistent-home-directory) for why - and is
selected via `labwc -C /etc/dbrrg/labwc` in
`overlay/etc/profile.d/10-dbrrg-session.sh`.

The reason is *not* the missing `zwp_keyboard_shortcuts_inhibit_manager_v1` -
that was this repo's earlier explanation and it is wrong. Xwayland's only use
of that protocol is `maybe_fake_grab_devices()`, which returns immediately
when the server is rootless, and Xwayland is always rootless under labwc.

Rootless Xwayland instead forwards X11 grabs via
`zwp_xwayland_keyboard_grab_manager_v1`, which upstream labwc and every
wlroots compositor lack. Our labwc carries a patch implementing it
(`containers/ubuntu/patches/0002-xwayland-keyboard-grab.patch`), so a
keybinding *would* now be suspended while the ThinLinc client holds the
keyboard.

Keybindings nonetheless stay at zero until that path has been confirmed on
hardware with a real ThinLinc session. `vncviewer` calls `XGrabKeyboard`, but
the headless test only proves Xwayland *binds* the manager global - the rig
supplies no input devices, so `xwl_seat->keyboard` is never created and
Xwayland never installs the hook that would send a `grab_keyboard` request in
the first place (see the comment in `test/runtime/test-labwc-runtime.sh`).
Whether a real grab actually suspends keybindings for the session's duration
is therefore unverified and can only be confirmed on hardware with a keyboard
attached. Adding a keybinding is now a config decision rather than an
impossibility - make it deliberately, and re-run `make test-runtime` after.

`test/integration/test-session-packages.sh` guards the zero-keybindings
assertion on `rc.xml` itself - run via `make test`.

### labwc is a local rebuild, not the archive package

`containers/ubuntu/Dockerfile` builds `labwc_0.9.3-1+dbrrg1` from Ubuntu's
source package with the patches in `containers/ubuntu/patches/`, applied as a
quilt series. Two behaviours depend on it:

- fullscreen Xwayland windows span every output
  (`LABWC_FULLSCREEN_SPAN_OUTPUTS`), which is what makes the ThinLinc client
  fill both monitors;
- `zwp_xwayland_keyboard_grab_manager_v1` exists, so X11 keyboard grabs
  suspend compositor keybindings.

Reverting to the archive `labwc` silently loses both. On a labwc or wlroots
version bump, expect to rebase the patches; `dpkg-buildpackage` fails loudly
when a hunk no longer applies, and `make test` plus `make test-runtime` cover
the rest. `_NET_WM_FULLSCREEN_MONITORS` was investigated and rejected - see
the design spec for why it is unnecessary.

`containers/ubuntu/patches/*.patch` are listed as prerequisites of the
`.ubuntu-container` target (`PATCH_FILES` in the `Makefile`). Editing a patch
without that dependency would not trigger a rebuild, leaving `make test` and
`make test-runtime` validating a stale image while still reporting green.

## Known Limitations

Open items found during the Ubuntu 26.04/Wayland/PipeWire upgrade. These are
not fixed; they are recorded so they aren't rediscovered from scratch.

### x11-xserver-utils: investigated and disproved

`xrandr`, `xset` and `xrdb` were a hard dependency of the `xorg` metapackage,
which was removed when the session moved to labwc/Wayland. This was flagged
as a risk (ThinLinc shelling out to `xrandr` for fullscreen resolution
negotiation) and then checked: `vncviewer`/`tlclient.bin` dlopen
`libXrandr.so.2`, which **is** still present in the image, and grepping for
the executables `xrandr`/`xset`/`xrdb` across `/opt/thinlinc/` returns zero
hits. ThinLinc uses the RandR *library*, never the CLI tools that
`x11-xserver-utils` shipped, so removing that package is safe.

## Debugging

With zero labwc keybindings ([Standing Constraints](#standing-constraints))
and no menu, `foot` has no launch path from within the session itself. Reach
it from a VT (Ctrl+Alt+F2, say) or over SSH instead:

```bash
XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 foot
```

Do not add a keybinding to launch it - that would violate the
zero-keybindings constraint.

## Potential Enhancements

Future improvements to consider:

1. **Firmware manifest** - Add version/checksum metadata to ramroot packages
2. **A/B update structure** - Support rollback by keeping previous version
3. **Additional output formats** - Generate qcow2 for testing in QEMU/KVM
4. **Serial console support** - Add console=ttyS0 to kernel parameters for headless debugging
