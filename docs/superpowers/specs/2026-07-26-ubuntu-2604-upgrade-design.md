# dbrrg: Ubuntu 26.04 upgrade, Wayland session, PipeWire audio

Date: 2026-07-26
Status: approved design, not yet implemented

> **Superseded in part:** the keybinding rationale recorded here
> (`zwp_keyboard_shortcuts_inhibit_manager_v1`) turned out to be wrong. See
> `docs/superpowers/specs/2026-07-27-labwc-multimonitor-fullscreen-design.md`
> for the correction and for the multi-monitor-fullscreen fix this design
> didn't have. This file is left as-written below as a historical record.

## Goal

Move the dbrrg thin-client image from Ubuntu 24.04 to 26.04 LTS, upgrade the
ThinLinc client, ship the firmware the hardware actually needs, replace the
X11 session stack with Wayland, and add the `oxulnk-desktop` package.

## Why

Three separate drivers:

1. **Missing GPU firmware.** Deployed clients log
   `i915 0000:00:02.0: [drm] Failed to load DMC firmware i915/adlp_dmc.bin`
   and `GuC firmware i915/adlp_guc_70.bin: fetch failed -ENOENT`, ending in
   `Failed to initialize GPU, declaring it wedged!`. Runtime power management
   is disabled and the GPU falls back to a wedged state.
2. **Broken fullscreen.** `wm2` does not implement the EWMH window-manager
   hints. Confirmed from the client side: `vncviewer` sets
   `_NET_WM_STATE_FULLSCREEN` and `_NET_WM_FULLSCREEN_MONITORS`, which a
   pre-EWMH window manager has no handling for. (The wm2 side of this is the
   reported field symptom; it was not re-verified against the wm2 binary.)
3. **Age.** 24.04 base, ThinLinc 4.19.0, and a legacy audio stack.

## Root cause of the firmware failure

Not a missing package — a build bug. `scripts/export-rootfs.sh:44` runs:

```sh
find /usr/lib/firmware -type f -not -name "iwlwifi*" -delete 2>/dev/null || true
```

immediately before `mksquashfs`. This deletes **everything except `iwlwifi*`**,
including all of `i915/`, `intel/` and `intel-ucode/`. It silently undoes the
whitelist in `containers/ubuntu/Dockerfile:110-116`, which does correctly
preserve `i915/` (verified by reproducing the Dockerfile cleanup in a
container — `i915/adlp_dmc.bin.zst` survives it).

Consequence beyond graphics: **`intel-ucode` is also deleted**, so deployed
clients have never received CPU microcode updates.

## Verified facts

Everything below was checked against live 26.04 containers and the actual
binaries, not assumed.

| Fact | Evidence |
| --- | --- |
| `ubuntu:26.04` is released LTS | `PRETTY_NAME="Ubuntu 26.04 LTS"`, kernel 7.0.0-28, systemd 259, Python 3.14 |
| Latest ThinLinc client | 4.20.0-4284; no `Depends` field (self-contained) |
| `wireless-tools` is obsolete on 26.04 | `E: Package 'wireless-tools' has no installation candidate` |
| All other current packages exist on 26.04 | full dry-run install resolves clean |
| `linux-firmware` is now split per vendor | `linux-firmware-minimal` has `Provides`/`Replaces`/`Conflicts: linux-firmware` |
| ThinLinc client is X11-only | `vncviewer`/`tlclient.bin` `NEEDED: libX11.so.6` only — no Wayland, no XCB |
| ThinLinc bundles PulseAudio 6.0 | `/opt/thinlinc/lib/tlclient/pulseaudio` → `NEEDED: libpulsecore-6.0.so` |
| ThinLinc grabs the keyboard | `XGrabKeyboard`/`XUngrabKeyboard`, `FullscreenSystemKeys` option |
| ThinLinc relies on EWMH fullscreen | `_NET_WM_STATE_FULLSCREEN`, `_NET_WM_FULLSCREEN_MONITORS` in `vncviewer` |
| `oxulnk-desktop` has a Wayland backend | dlopens `libwayland-client.so.0`, `libwayland-egl.so.1`, `libxkbcommon.so.0` |
| labwc does **not** implement shortcuts-inhibit | see "Keyboard grabbing" below |

### Stack sizes (standalone resolution on 26.04)

| stack | packages | installed size |
| --- | --- | --- |
| `xorg` + `nodm` + `wm2` (current) | 179 | 353 MB |
| `labwc` + `xwayland` (chosen) | 132 | 265 MB |
| `cage` + `xwayland` | 99 | 212 MB |
| `lxterminal` (current) | 110 | 170 MB |
| `foot` + `foot-terminfo` (chosen) | 23 | 23 MB |

These overlap with packages the image already pulls (mesa, libdrm, fonts), so
the realised delta will be smaller than the raw difference. The saving is real
but should be measured after the build, not promised in advance.

## Design

### 1. Base image and packages

`containers/ubuntu/Dockerfile`: `FROM ubuntu:24.04` → `FROM ubuntu:26.04`.

**Removed:** `wireless-tools` (obsolete), `xorg`, `nodm`, `wm2`, `numlockx`
(X11-only), `lxterminal`, `pulseaudio`, `alsa-base` (version 1.0.25, ancient),
`xserver-xorg-video-intel` (unmaintained since 2021; Intel recommend the
built-in modesetting driver for Gen9+).

**Added:**

```
iw                              # replaces wireless-tools
labwc xwayland                  # Wayland session
foot foot-terminfo              # native Wayland terminal
pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth
pulseaudio-utils                # provides pactl, needed by the audio wrapper
alsa-utils                      # replaces alsa-base
vainfo intel-media-va-driver i965-va-driver
xfonts-base fonts-dejavu-core   # were pulled in by the xorg metapackage; tlclient needs them
linux-firmware-minimal
linux-firmware-intel-graphics linux-firmware-intel-wireless
firmware-sof-signed linux-firmware-realtek
```

ThinLinc client URL bumps to
`https://www.cendio.com/downloads/clients/thinlinc-client_4.20.0-4284_amd64.deb`.

`oxulnk-desktop_0.1.0+dev20260726183924_amd64.deb` is copied into the build
context and installed with `apt install ./oxulnk-desktop_*.deb`. It is a plain
extra package with no special session handling. Its `Depends` all resolve on
26.04, including `libasound2t64`, which survived the t64 transition.

### 2. Firmware — declarative, no more `rm -rf`

`linux-image-generic` hard-depends on `linux-firmware`. `linux-firmware-minimal`
satisfies that dependency via `Provides`, and only *recommends* the per-vendor
subpackages — so with `--no-install-recommends` the set is exactly what is
listed explicitly. Verified: the simulated install pulls only
`linux-firmware-minimal`, `-intel-graphics` and `-intel-wireless`.

| package | installed size | covers |
| --- | --- | --- |
| `linux-firmware-intel-graphics` | 21 MB | i915 (incl. `adlp_dmc.bin`, `adlp_guc_70.bin`), xe, ipu, vsc |
| `linux-firmware-intel-wireless` | 100 MB | iwlwifi + Intel Bluetooth |
| `firmware-sof-signed` | 44 MB | Intel SOF audio DSP |
| `linux-firmware-realtek` | 7 MB | Realtek NIC / WiFi / BT / audio |
| `intel-microcode` | ~7 MB | CPU microcode |

Total ~179 MB, against ~1.5 GB for the full `linux-firmware`.

**Both cleanup hacks are deleted:**

- the `RUN cd /usr/lib/firmware && ... mv/rm -rf/mv` block in the Dockerfile
- the `find /usr/lib/firmware ... -delete` line in `scripts/export-rootfs.sh`

The package set is now the single source of truth for what firmware ships.

### 3. Session stack

`nodm` is X11-only and goes away entirely; no display manager replaces it.

- `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf` —
  autologin `tluser` on tty1. This yields a real logind session on seat0, which
  is what labwc needs for DRM/input access (no `seatd` required) and what
  provides `XDG_RUNTIME_DIR` for the PipeWire user units.
- `overlay/etc/profile.d/10-dbrrg-session.sh` — on tty1 only, `exec` the
  session launcher.

labwc configuration lives in `overlay/home/tluser/.config/labwc/`:

- **`rc.xml`** — a `<keyboard>` section containing **no `<default />` and no
  `<keybind>` entries**, so zero keybindings are registered. Same for
  `<mouse>`. Plus `<numlock>on</numlock>`, `<repeatDelay>500</repeatDelay>`,
  `<repeatRate>30</repeatRate>`.
- **`environment`** — XKB settings.
- **`autostart`** — restore home, start the client, save home on exit.

The two `Xsession.d` hooks keep their order and logic, moving into the
autostart path.

#### Keyboard config migration

`overlay/etc/X11/xorg.conf.d/00-keyboard.conf` maps 1:1:

| Xorg InputClass | labwc |
| --- | --- |
| `XkbModel "pc105"` | `XKB_DEFAULT_MODEL=pc105` |
| `XkbLayout "us"` | `XKB_DEFAULT_LAYOUT=us` |
| `XkbOptions "compose:menu, ctrl:nocaps"` | `XKB_DEFAULT_OPTIONS=compose:menu,ctrl:nocaps` |
| `AutoRepeat "500 30"` | `<repeatDelay>500</repeatDelay><repeatRate>30</repeatRate>` |
| `numlockx` package | `<numlock>on</numlock>` |

#### Keyboard grabbing — why the empty `<keyboard>` section is mandatory

The Wayland protocol for a client reclaiming shortcuts is
`zwp_keyboard_shortcuts_inhibit_manager_v1`. The chain works up to the last
link:

- `Xwayland` advertises both `zwp_keyboard_shortcuts_inhibit_manager_v1` and
  `zwp_keyboard_shortcuts_inhibitor_v1`, so an X11 grab becomes an inhibit
  request.
- `wlroots 0.19` implements the server side
  (`wlr_keyboard_shortcuts_inhibit_v1_create` and friends).
- **labwc 0.9.3 never calls it.** Its only inhibit-related undefined symbols
  are `wlr_idle_inhibit_v1_create` and `wlr_idle_notifier_v1_set_inhibited` —
  *idle*/screen-blank inhibition, unrelated.

So under labwc, ThinLinc's `XGrabKeyboard` cannot suppress compositor
bindings. Removing them is the only available mechanism, not a shortcut.
This is a supported configuration — labwc's own annotated reference states:

> Use `<keyboard><default />` to load all the default keybinds (those listed
> below).

Defaults are opt-in. Omitting `<default />` yields none.

**This is a standing constraint, not a one-off:** if a future labwc gains
keybindings by default or someone adds one "just for convenience", keys stop
reaching the remote session. Note it in `CLAUDE.md`.

### 4. Audio — PipeWire with a translating wrapper

ThinLinc spawns `/opt/thinlinc/lib/tlclient/pulseaudio` and expects a daemon
that loads PulseAudio modules. The existing overlay replaces Cendio's bundled
PulseAudio 6.0 with a wrapper around the system PulseAudio, because the 2015
build cannot drive modern SOF/HDA hardware.

The client builds its module spec from:

```
module-native-protocol-tcp listen=127.0.0.1 port=%d cookie='%s'
```

**`cookie=` is not a valid modarg for either implementation.** Verified:

```
PulseAudio 17: auth-anonymous auth-cookie auth-cookie-enabled auth-ip-acl port listen
PipeWire:      port listen auth-anonymous
```

It is presumably an argument Cendio's patched PulseAudio 6.0 fork understands.
So the wrapper must **translate** the spec, not pass it through.

New wrapper behaviour:

1. Scan argv for the token starting with `module-`.
2. Rewrite it: keep `listen=` and `port=`, drop `cookie=`, add
   `auth-anonymous=true`.
3. Ensure the session's PipeWire pulse server is up (socket-activated user
   units), polling `pactl info` until it answers, with a bounded timeout.
4. `pactl load-module` the rewritten spec, capturing the module index.
5. Stay in the foreground so ThinLinc's process tracking and teardown keep
   working; on `TERM`/`INT`/`HUP`/`EXIT`, unload the module.

`module-udev-detect` is dropped entirely — PipeWire discovers devices
natively.

Quoting note: the spec arrives as a single argv element containing
`cookie='...'`. Naive `pactl load-module $SPEC` would pass the literal single
quotes through. Since the wrapper rebuilds the argument list itself rather
than re-splitting ThinLinc's string, this is avoided by construction; the
implementation must not fall back to `eval`.

**Security trade-off, stated explicitly:** `auth-anonymous=true` means any
local process can connect to the audio server. The listener is bound to
`127.0.0.1` and the device is a single-user kiosk, so this is acceptable here.
It would not be on a multi-user machine.

### 5. Kernel / initramfs

The dracut invocation is unchanged in structure but must be re-verified
against kernel 7.0. The `--omit-drivers` list already excludes `i915`; that
only affects the initramfs, not the squashfs root, so it does not interact
with the firmware fix.

## Overlay file map

**Remove**

```
etc/default/nodm
etc/X11/xorg.conf.d/00-keyboard.conf
etc/X11/Xsession.d/39dbrrg-restore-home
etc/X11/Xsession.d/90dbrrg-start-thinlinc
home/tluser/.xsessionrc
```

**Add**

```
etc/systemd/system/getty@tty1.service.d/autologin.conf
etc/profile.d/10-dbrrg-session.sh
home/tluser/.config/labwc/rc.xml
home/tluser/.config/labwc/environment
home/tluser/.config/labwc/autostart
```

**Rewrite**

```
opt/thinlinc/lib/tlclient/pulseaudio
```

**Unchanged**

```
etc/netplan/            etc/ssh/                etc/plymouth/
etc/locale.conf         etc/locale.gen          etc/hosts.in
etc/sysctl.d/           etc/modprobe.d/         etc/systemd/system/ (services)
opt/thinlinc/bin/save-home                      usr/bin/upgrade-image
home/tluser/wifi.yaml   home/tluser/.thinlinc/tlclient.conf
usr/lib/dracut/modules.d/90dbrrg/               usr/lib/dracut/modules.d/50plymouth/
```

## Build changes

- `containers/ubuntu/Dockerfile` — base image, package list, ThinLinc URL,
  `oxulnk-desktop` install, firmware block deleted.
- `scripts/export-rootfs.sh` — delete the `find /usr/lib/firmware ... -delete`
  line.
- `Makefile` — `VERSION` 2.0.0 → 3.0.0 (base OS and session stack both change).
- `.xsessionrc` guidance in `README.md` needs updating since the file is gone.

## Test plan

Build-time (automatable):

1. `make rootfs` completes.
2. `i915/adlp_dmc.bin.zst` and `i915/adlp_guc_70.bin.zst` are present in the
   squashfs. **This is the regression test for the original bug** — assert it
   explicitly rather than eyeballing sizes.
3. `intel-ucode/` is present in the squashfs.
4. `make image` completes; note the squashfs size delta.

QEMU (`make qemu-test`):

5. Boots to a labwc session with the ThinLinc client visible.
6. `foot` launches.
7. No labwc keybinding responds (`A-Tab`, `W-Return` do nothing).

On real NUC hardware — these cannot be settled in a VM:

8. **No i915 firmware errors in dmesg, GPU not wedged.** The original symptom.
9. **ThinLinc audio works end to end.** The `auth-anonymous` translation is
   the least certain part of this design; if it fails, audio dies silently.
10. **ThinLinc fullscreen**, including across multiple monitors. Cendio does
    not support Wayland, and fullscreen-multi-monitor under Xwayland is the
    least-tested path.
11. **Keyboard passthrough** — confirm keys reach the remote session.
12. WiFi associates (iwlwifi firmware) and Bluetooth enumerates.
13. `vainfo` reports the iHD driver and working profiles.
14. Home persistence still restores and saves across a reboot.
15. `oxulnk-desktop` launches.

## Risks

| Risk | Severity | Mitigation |
| --- | --- | --- |
| PipeWire `auth-anonymous` translation fails, audio silently dead | High | Test 9. Fallback: revert to `pulseaudio` (still in 26.04) and keep the existing wrapper — a small, contained change |
| ThinLinc fullscreen-multi-monitor misbehaves under Xwayland | Medium | Test 10. Fallback: `cage`, or back to Xorg + `openbox` |
| A future labwc default keybinding steals keys | Medium | Empty `<keyboard>`; document the constraint in `CLAUDE.md` |
| Kernel 7.0 dracut regressions | Medium | Test 5; `rd.debug` boot entry already exists in `syslinux.cfg` |
| Squashfs grows despite firmware trimming | Low | Measure in test 4; the `xorg`→Wayland and `lxterminal`→`foot` swaps offset the firmware addition |
| `oxulnk-desktop` built against 24.04 glibc | Low | Forward-compatible; all `Depends` resolve on 26.04 |

## Explicitly out of scope

- Rewriting the dracut module, netplan, sshd or plymouth configuration.
- Changing the A/B upgrade mechanism or home-persistence protocol.
- Native Wayland support for the ThinLinc client (impossible — it is X11-only;
  `oxulnk-desktop` can, but that is not a goal of this change).
