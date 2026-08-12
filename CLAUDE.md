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
   - **Home Restore**: Restores `/home/tluser` from the boot medium
     (`home.tar.gz` on the EFI partition, or `home.pkg` from the boot server)
     before the pivot, so the home directory is in place before
     `multi-user.target`

4. **Un-dockerization** (overlay/etc/systemd/system/un-dockerize.service) - First-boot service removes Docker artifacts, fixes /etc/hosts, reconfigures systemd-resolved

5. **Home Persistence** - the initramfs restores the home directory before
   the pivot (`restore_home()` in the dracut module); `dbrrg-session` saves
   it on logout, after the ThinLinc client exits (`dbrrg-save-home`)

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
- Taskbar: `overlay/etc/dbrrg/waybar/` (`config.jsonc`, `style.css`) - a
  single `wlr/taskbar` module, launched by `dbrrg-session`. It exists
  because labwc draws an iconify button and, with zero keybindings and no
  menu, a minimized window would otherwise be unreachable for the rest of
  the session. Kept outside `$HOME` for the same reason `rc.xml` is.
  Note a fullscreen ThinLinc client covers the bar - wlroots puts
  fullscreen surfaces above the layer-shell top layer and ignores exclusive
  zones - so it is visible exactly when no window is fullscreen, which is
  when a window can go missing.
- Session startup: `overlay/usr/bin/dbrrg-session`, `overlay/etc/profile.d/10-dbrrg-session.sh`
- **Per-machine user customisation:** `overlay/home/tluser/.dbrrg-sessionrc` — the Wayland replacement for `~/.xsessionrc`. Sourced by `dbrrg-session` after the home restore and before the ThinLinc client. Because it lives in `$HOME` it is captured by `save-home` and restored each boot, so a user can configure an individual machine without rebuilding the image. This is where display layout goes: **`wlr-randr` replaces `xrandr`** (`--output DP-1 --transform 90 --pos 1920,0`), and `kanshi` is available for layouts that must survive hotplug or DPMS wake. It must run before `tlclient`, because the client reads the monitor layout once at startup.

- **Per-machine user environment:** `overlay/home/tluser/.dbrrg-environment` — variables the compositor reads at **startup**: keyboard layout (`XKB_DEFAULT_*`) and cursor theme. Sourced by `overlay/etc/profile.d/10-dbrrg-session.sh` after `/etc/dbrrg/labwc/environment`, so the user's value wins. Also persisted via `save-home`.

  | variable | default | effect |
  | --- | --- | --- |
  | `LABWC_FULLSCREEN_SPAN_OUTPUTS` | `1` | fullscreen Xwayland windows (the ThinLinc client) span every monitor |

  A per-machine override in `~/.dbrrg-environment` **works**, including for
  keys also set in `/etc/dbrrg/labwc/environment` - `LABWC_FULLSCREEN_SPAN_OUTPUTS`
  above and the pre-existing `XKB_DEFAULT_*` / `XCURSOR_*` keyboard and cursor
  overrides. This is not as simple as it looks: labwc's
  `session_environment_init()` (`src/config/session.c:77`) calls
  `setenv(key, value, 1)` - overwrite - and, run with `-C`, treats
  `<config_dir>/environment` as the *only* environment file it reads
  (`src/common/dir.c:153-157`, called from `src/main.c:211`). Pointing `-C`
  straight at `/etc/dbrrg/labwc` therefore let labwc's own re-read reset any
  key also present in the user's file back to the system value, silently
  discarding what `10-dbrrg-session.sh` had just exported into the shell.
  The fix, `overlay/usr/bin/dbrrg-compose-labwc-config`, composes a
  merged config directory at session start - the system dir's files
  symlinked in unchanged, plus an `environment` file that is the system
  defaults followed by the user's file - and points `-C` at that instead, so
  the file labwc re-reads already has the user's values last (and therefore
  winning, since labwc's `setenv` on a later duplicate overwrites the
  earlier one - `test/runtime/test-labwc-runtime.sh` asserts this against
  the real parser). If `XDG_RUNTIME_DIR` is unset/unwritable or the merge
  fails, the session falls back to the plain `/etc/dbrrg/labwc` (today's
  behaviour) rather than failing to start. This is proven by
  `test/integration/test-labwc-config-merge.sh` (the merge logic, offline)
  and `test/runtime/test-labwc-runtime.sh` (the parser assumption, against
  real labwc).

  **Confirmed on hardware (2026-07-27):** an `XKB_DEFAULT_*` override in
  `~/.dbrrg-environment` takes effect, which is what the merge exists to
  make possible - before it, that documented feature had never worked. The
  session also starts normally, i.e. the merged config dir is used without
  needing its fallback. Not separately exercised: setting
  `LABWC_FULLSCREEN_SPAN_OUTPUTS=0` to get single-monitor fullscreen. It
  travels through the same merge, so it is expected to work, but it has not
  been observed.

  **The two user files are split by timing, and it is not arbitrary:**

  | file | sourced | for |
  | --- | --- | --- |
  | `~/.dbrrg-environment` | before the compositor starts | variables read at startup — keyboard, cursor |
  | `~/.dbrrg-sessionrc` | inside the running session | commands needing a compositor — `wlr-randr`, `kanshi`, netplan |

  This is why the home restore happens in the **initramfs** rather than
  inside the session: a user's saved `.dbrrg-environment` has to be on disk
  before the compositor reads `XKB_DEFAULT_*`. Restoring home inside the
  session would make a user keyboard change take effect only on the *next*
  boot. Do not move the restore into `dbrrg-session`, and do not move it
  back into `10-dbrrg-session.sh` either — `dbrrg-ssh-hostkeys` now needs
  the home directory before `multi-user.target`.

  Note the deliberate split from system config: user-editable settings live in `$HOME`, but `overlay/etc/dbrrg/labwc/rc.xml` does **not** — see [Standing Constraints](#standing-constraints).
- Autologin: `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf`
- User defaults: `overlay/home/tluser/`

After modifying overlay files, rebuild with `make image`.

## Persistent Home Directory

The system implements home directory persistence across reboots:

- On boot: the initramfs restores `/home/tluser` — from `home.tar.gz` on the
  EFI partition when booting from USB, or from `home.pkg` on the boot server
  when netbooting. This happens in `restore_home()`
  (`overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh`), called from
  `setup-overlay.sh`, **not** at login. It moved there so the SSH host keys
  stored inside the home directory are available before sshd starts.
  Netboot identifies the machine by the MAC recorded at
  `/run/dbrrg/state/boot-mac` — the interface the initramfs actually used —
  rather than by re-deriving it, so restore and save cannot disagree.
- On logout: ThinLinc client shutdown triggers `/usr/bin/dbrrg-save-home` which saves home directory back to USB or uploads to boot server via HTTP POST

This allows WiFi credentials, ThinLinc settings, and user customizations to persist.

## Network Boot vs USB Boot

The system detects boot method by checking for `/dev/disk/by-partlabel/EFI-SYSTEM`:

- **USB Boot**: Partition present → loads ramroot.sqsh from local `tl/ramroot.sqsh`, persists home to partition
- **Network Boot**: No partition → uses ramroot URL from kernel cmdline, persists home to boot server HTTP endpoint

Both modes execute identical code paths after SquashFS mount.

## Container Build Best Practices

The containers/ubuntu/Dockerfile follows several important patterns:

1. **SSH Host Keys**: Host keys are removed at build time. On first boot
   `dbrrg-ssh-hostkeys.service` generates them and stages them into
   `~tluser/.dbrrg-ssh-host-keys`, from where `dbrrg-save-home` captures them
   into the home archive at logout; the initramfs restores them on every
   subsequent boot. `ssh.socket` is **masked** — see Standing Constraints.
   Keys do not persist until the first clean logout: a machine hard-powered
   off before then generates fresh keys next boot.

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

Six rules in this repository look like ordinary configuration but are
load-bearing. All but the last (patched labwc) have each caused a real
shipped-image bug; that one is preventive - nothing has shipped broken from
it yet, but reverting it silently would ship regressions in both patched
behaviours.

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

### ssh.socket must stay masked

`containers/ubuntu/Dockerfile` runs `systemctl disable ssh.socket` then
`systemctl mask ssh.socket`, and enables `ssh.service` alone. Re-enabling the
socket reintroduces an ordering cycle.

`dbrrg-ssh-hostkeys.service` must run before sshd. With the socket active,
sshd has two entry points with different ordering — the socket from
`sockets.target`, the service from `multi-user.target` — so the key unit had
to be ordered `Before=ssh.socket`. But a `DefaultDependencies=yes` unit is
implicitly ordered `After=basic.target`, and `basic.target` comes after
`sockets.target`, which comes after `ssh.socket`. Before and after the same
unit is a cycle, and systemd resolves a cycle by deleting a job — which job
is not contractual: under QEMU it deleted `sockets.target` and sshd came up
fine, while on real hardware it deleted the key-generation service, leaving
no host keys and no sshd.

`disable` before `mask` is required, not stylistic. Ubuntu's `ssh.socket`
declares `RequiredBy=ssh.service` in its `[Install]` section, so once it is
enabled, `/etc/systemd/system/ssh.service.requires/ssh.socket` exists.
Masking the socket while that symlink is still there makes `ssh.service`
fail outright with "Unit ssh.socket is masked" — `disable` removes the
symlink (and the `sockets.target.wants` one) first; `mask` then stops
anything from re-enabling it. Doing `mask` first would leave the requires
symlink in place, since `disable` is a no-op on an already-masked unit.

`sshd-keygen.service` must ALSO be masked, for a reason that's easy to
miss: it ships enabled via `Wants=` from **both** `ssh.socket.wants/` and
`ssh.service.wants/`, so disabling `ssh.socket` only removes the first of
those two symlinks — the second survives on its own. Left alone, it races
`dbrrg-ssh-hostkeys.service` on a genuine first boot: its
`ConditionFirstBoot=yes`, and neither unit is ordered against the other,
both only declaring `Before=ssh.service`. If `sshd-keygen.service` wins, it
writes keys straight into `/etc/ssh`; `dbrrg-ssh-hostkeys.service` then
finds live keys already present and skips generation, so those keys are
never staged into the keystore and are lost on the next boot — reproducing
the regenerate-every-boot bug this whole mechanism exists to fix. It is only
a `Wants=` (soft) dependency of `ssh.service`, so masking it cannot break
sshd startup the way masking `ssh.socket` alone would have.

`test/integration/test-session-packages.sh` guards all three — the
`ssh.socket` mask, the absence of `ssh.service.requires/ssh.socket`, and the
`sshd-keygen.service` mask — run via `make test`.

### A multi-user.target unit must never declare Before= on a sysinit.target unit

A unit that is only `WantedBy=multi-user.target` (no explicit
`DefaultDependencies=` or `Before=`/`After=` of its own) is implicitly
ordered `After=basic.target`, which is itself ordered after
`sysinit.target`. Giving such a unit `Before=<something in sysinit.target>`
therefore orders it both before and after the same target, and systemd
resolves the resulting cycle by silently deleting one of the jobs — on every
single boot, not just the first.

Two real instances of this bug have shipped in this repo:

- The predecessor `regenerate_ssh_host_keys.service` (deleted on this
  branch, replaced by `dbrrg-ssh-hostkeys.service`) was ordered
  `Before=ssh.socket` (which pulls in `sockets.target`, itself before
  `basic.target`) — see "ssh.socket must stay masked" above for the full
  cycle and its fix.
- `un-dockerize.service` was ordered `Before=systemd-hwdb-update.service`
  (part of `sysinit.target`). systemd broke the cycle by deleting the hwdb
  update job on every boot; nothing `un-dockerize.service` does (resolv.conf,
  `/etc/hosts`, `systemd-resolved`) has anything to do with the hardware
  database — the `Before=` was vestigial, left over from commented-out
  `depmod`/`modprobe` lines. It has been removed. Because this image's
  `usr/lib/udev/hwdb.bin` ships prebuilt (confirmed via `unsquashfs -l
  ramroot.sqsh | grep hwdb.bin`), `systemd-hwdb-update.service` is now also
  masked in `containers/ubuntu/Dockerfile` alongside the other `systemctl
  mask` calls, so removing the ordering cycle doesn't newly spend a boot
  regenerating a database the image already has.

`scripts/check-boot-smoke.sh` guards this class of bug directly: it fails
the smoke test on any `Found ordering cycle` line in the boot log, not just
on the two known instances. `test/integration/test-session-packages.sh`
additionally asserts `un-dockerize.service` has no
`Before=systemd-hwdb-update` line — both run via `make test`.

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

Screenshots use `grim`, with `slurp` for region selection and `wl-copy` to
put the result on the clipboard. Same constraint as `foot`: with zero
keybindings there is no in-session trigger, so take them from a VT or over
SSH.

```bash
XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 grim /tmp/shot.png
XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
    sh -c 'grim -g "$(slurp)" - | wl-copy'
```

Do not add a keybinding for this - that would violate the
zero-keybindings constraint.

## Potential Enhancements

Future improvements to consider:

1. **Firmware manifest** - Add version/checksum metadata to ramroot packages
2. **A/B update structure** - Support rollback by keeping previous version
3. **Additional output formats** - Generate qcow2 for testing in QEMU/KVM
4. **Serial console support** - Add console=ttyS0 to kernel parameters for headless debugging
