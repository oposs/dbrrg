# dbrrg 26.04 (labwc) image: first boot on a NUC7i3BNK

**Reported:** 2026-10-01 (field report, reproduced verbatim below)
**Verified against the source tree:** 2026-10-02 — all five items confirmed.
**Machine:** Intel NUC7i3BNK (Kaby Lake, i915 device 5916), booting UEFI from a
Kingston DT microDuo 3C
**Image:** flashed 2026-10-01 06:35, `LABEL current`, Ubuntu 26.04.1,
kernel 7.0.0-34-generic
**Cmdline:** `ramroot=tl/ramroot.sqsh console=tty1 quiet splash plymouth.use-simpledrm`

## Verification notes

Added 2026-10-02. Each item was checked against the repository before planning
a fix.

| item | claim | verified |
| --- | --- | --- |
| 1 | `i915` is in `--omit-drivers` | yes, `containers/ubuntu/Dockerfile:294` |
| 1 | autologin orders only `After=plymouth-quit-wait.service` | yes, `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf` |
| 1 | `udevadm wait` is available for the proposed fix | yes, present in the built image |
| 2 | nothing outside the session installs netplan/WireGuard config | yes |
| 3 | `ethernet.yaml` ships `0644` | yes, `overlay/etc/netplan/ethernet.yaml` |
| 4.1 | `dbrrg-save-home` has no exclude list | yes |
| 4.2 | the archive write is not atomic | yes, `tar zcf - . \| sudo dd of=...` |
| 4.3 | the boot ESP is already mounted, and the save mounts it again | yes — see below |
| 5 | `un-dockerize.service` never touches `/etc/hostname` | yes, it rewrites `/etc/hosts` and `resolv.conf` only |
| 5 | the overlay ships no `/etc/hostname` | yes |

**Item 4.3 corrects this repository's own design spec.**
`docs/superpowers/specs/2026-10-01-tile-menu-design.md` claimed "nothing mounts
the EFI partition during a normal session, so there is no mounted partition to
prefer". That is false. `dbrrg-cleanup.sh` states "Do NOT unmount squashfs, EFI
partition, ZRAM, or overlay! They are needed for the running system", and
`mount-squashfs.sh:71` mounts it read-write at `/run/dbrrg/storage/efi`. The
mount survives the pivot — proof: `dbrrg-save-home` already reads
`/run/dbrrg/state/boot-mac` successfully in the booted system. The spec has
been corrected and the planned `boot-efi-dev` breadcrumb dropped in favour of
writing to the existing mount.

**Item 2 was overstated and is corrected here.** `~/.dbrrg-sessionrc` does
exist, ships in `overlay/home/tluser/`, and is sourced by
`overlay/usr/bin/dbrrg-session:39-40` on every session. It is a working
replacement for `~/.xsessionrc`. What is wrong is that its NETWORK section
presents the netplan commands as a one-off recipe rather than as lines to keep
in the file, so a reader does not learn that putting them there makes them run
on every boot. The real defect that survives is the coupling: network
configuration applied from the session is unavailable on a machine whose
session failed to start — which is what made item 1 undiagnosable remotely on
this machine. Decided 2026-10-02: move it to a system unit and keep
`~/.dbrrg-sessionrc` for display configuration.

---

The stick booted, but:

1. the graphical session did not start: tty1 was left at the failure shell;
2. neither WiFi nor WireGuard came up, although `wifi.yaml` and `wg0.conf` were in `~tluser`.

Both are image issues. Section 1 is a boot race. Section 2 is a feature that was lost in the move from X11 to Wayland. Sections 3-5 are smaller problems found along the way. Everything below was observed on this machine; the workarounds applied in `$HOME` are described at the end so they can be removed once the image is fixed.

---

## 1. labwc loses the race against i915 (graphical session fails)

### Symptom

`$XDG_RUNTIME_DIR/dbrrg-session.log`:

```
[ERROR] [libseat] [libseat/backend/logind.c:124] Could not take device: No such device
[ERROR] [backend/session/session.c:331] Failed to open device: '/dev/dri/card0': Resource temporarily unavailable
[ERROR] [backend/backend.c:245] Found 0 GPUs, cannot create backend
[ERROR] [backend/backend.c:420] Failed to open any DRM device
[ERROR] [../src/server.c:477] unable to create backend
```

A manual start a few seconds later works, because by then `card0` is the i915 device.

### Cause

The initrd is built with `i915` in `--omit-drivers`:

```
--omit-drivers '... nouveau radeon amdgpu i915 vmwgfx qxl virtio-gpu bochs'
```

So i915 is loaded only by udev coldplug after switch-root. Until then `card0` is simpledrm (`plymouth.use-simpledrm`). When i915 binds, it removes simpledrm's `card0` and registers its own `card0` (minor 0), and there is a gap with no usable `card0` in between.

The getty drop-in orders autologin only `After=plymouth-quit-wait.service`, which does nothing to cover that gap. Journal from this boot (`-o short-monotonic`):

```
[ 9.978] Finished plymouth-quit-wait.service
[ 9.987] Started getty@tty1.service - Getty on tty1.
[10.729] i915 0000:00:02.0: [drm] Found kabylake/ult (device ID 5916) ...
[10.731] i915 0000:00:02.0: vgaarb: deactivate vga console      <- simpledrm being kicked out
[11.099] systemd-logind: New session '1' of user 'tluser' ... type 'tty'
         labwc starts ~here, logind TakeDevice(card0) -> ENODEV
[11.372] [drm] Initialized i915 1.6.0 for 0000:00:02.0 on minor 0
```

The session started about 270 ms before i915's `card0` existed. Since `10-dbrrg-session.sh` deliberately holds the failure shell instead of exiting, the session is never retried. The race is therefore fatal for the whole boot, not just a few seconds of delay.

How often it happens depends on timing. Machines where i915 binds a little earlier (or where autologin is a little slower) will usually win, which may be why this didn't show up in testing.

### Suggested fix (one or more)

**A. Wait for a real KMS device before autologin (recommended).** Add a small oneshot that the getty drop-in orders after:

`/usr/libexec/dbrrg/wait-kms`:

```sh
#!/bin/sh
# Wait until a DRM card is driven by something other than simpledrm and udev
# has finished with it (seat tag / uaccess ACLs), so logind can hand it to labwc.
i=0
while [ $i -lt 100 ]; do                      # up to ~20 s
    for c in /sys/class/drm/card[0-9]*; do
        [ -e "$c" ] || continue
        drv=$(readlink "$c/device/driver" 2>/dev/null)
        case "$drv" in
            ''|*simpledrm*|*simple-framebuffer*) ;;
            *) exec udevadm wait --timeout=5 "/dev/dri/${c##*/}" ;;
        esac
    done
    sleep 0.2
    i=$((i + 1))
done
echo "wait-kms: no KMS driver after 20 s, continuing with what there is" >&2
exit 0      # never block the login for good: a simpledrm-only machine must still boot
```

`/etc/systemd/system/dbrrg-wait-kms.service`:

```ini
[Unit]
Description=Wait for a real KMS driver before the tty1 session
After=systemd-udev-trigger.service
Before=getty@tty1.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/dbrrg/wait-kms
```

Then in `getty@tty1.service.d/autologin.conf`:

```ini
[Unit]
After=plymouth-quit-wait.service dbrrg-wait-kms.service
Wants=dbrrg-wait-kms.service
```

A plain `After=dev-dri-card0.device` does **not** work, because simpledrm's `card0` satisfies it immediately. `systemd-udev-settle.service` would work but is deprecated and slow.

On machines with a non-Intel GPU, the driver name check is already generic, since it accepts anything except simpledrm. On a machine that only ever has simpledrm, the 20 s timeout lets it continue rather than hang.

**B. Retry once in `10-dbrrg-session.sh` before holding the failure shell.** If labwc exits non-zero within a few seconds and the log contains `Found 0 GPUs`, wait as in A and start it once more. This is cheap belt-and-braces and also covers late hotplug-type failures.

**C. Put i915 back into the initrd** (drop it from `--omit-drivers`, add it with `--add-drivers`, include `i915/*` firmware). This makes the driver ready long before switch-root, so the race cannot happen. It costs initrd size and loader time, and it is Intel-specific, so A is the better general fix. On the previous 24.04 image this was measured as a net win for time-to-tlclient: X no longer raced the driver either.

---

## 2. No per-machine network / WireGuard setup survives a reboot

### Symptom

After boot, `wlp58s0` was not configured and there was no `wg0`, although `~/wifi.yaml` and `~/wg0.conf` were restored with `$HOME`. (`netplan-wpa-wlp58s0` only appeared after the user had copied the file by hand.)

### Cause

On the X11 image this was done by `~/.xsessionrc`: copy `~/wifi.yaml` to `/etc/netplan`, `~/wg0.conf` to `/etc/wireguard`, then `netplan apply` and `systemctl start wg-quick@wg0`. That was needed at every boot, because `/etc` is a fresh zram overlay.

The labwc session never reads `~/.xsessionrc`, and nothing in the image replaced that job:

- `~/.dbrrg-sessionrc`, which the image's template presents as the replacement, only shows the **manual** netplan commands in a comment. They don't persist across reboots, because `/etc` is reset.
- Putting the commands into `~/.dbrrg-sessionrc` would only work when labwc starts. So a graphics failure like section 1 would also take the network down, and with it any chance of remote diagnosis over the VPN.
- `dbrrg-lib.sh` (initramfs) restores `$HOME` but does nothing with netplan or WireGuard files.

### Suggested fix

Add a system unit, independent of the graphical session, that installs per-machine network config from the restored home, after the home restore and before networkd:

```ini
# /etc/systemd/system/dbrrg-local-network.service
[Unit]
Description=Install per-machine netplan/WireGuard config from the restored home
DefaultDependencies=no
After=local-fs.target
Before=netplan-configure.service systemd-networkd.service network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/dbrrg/install-local-network

[Install]
WantedBy=sysinit.target
```

```sh
#!/bin/sh
# /usr/libexec/dbrrg/install-local-network
H=/home/tluser
[ -r "$H/wifi.yaml" ] && install -m 600 -o root -g root "$H/wifi.yaml" /etc/netplan/wifi.yaml
if [ -r "$H/wg0.conf" ]; then
    install -d -m 700 /etc/wireguard
    install -m 600 -o root -g root "$H/wg0.conf" /etc/wireguard/wg0.conf
    systemctl enable --runtime wg-quick@wg0.service   # /run, so nothing lingers
fi
exit 0
```

Running before `netplan-configure.service` means the generator output already includes WiFi. No `netplan apply` is needed, and WiFi associates during boot. The exact ordering should be checked against the 26.04 netplan generator; this unit was not tested, only the user-level equivalent described at the end.

Also update the NETWORK section of the `~/.dbrrg-sessionrc` template accordingly.

The ESP of this stick also has `wifi.yaml`, `wg0.conf`, `ethernet.yaml` and `vpn-aarweg.oetiker.ch-P42.conf` at its root (written 2026-10-01 12:19). If that is meant as a provisioning convention, the same unit could read from `/run/dbrrg/storage/efi` as a fallback.

---

## 3. `/etc/netplan/ethernet.yaml` ships world-readable

```
configure[431]: Permissions for /etc/netplan/ethernet.yaml are too open.
                Netplan configuration should NOT be accessible by others.
```

Please ship it `0600 root:root`. The content itself (`optional: true` on `en*`) is fine.

---

## 4. `/usr/bin/dbrrg-save-home` (run when tlclient quits)

Three problems, in order of impact:

1. **No exclude list.** It tars all of `$HOME`. On this machine that includes the Claude Code binary (~233 MB in `~/.local/share/claude/versions`) and `~/.cache`. A ~22 MB archive becomes several hundred MB, and since `restore_home()` unpacks it synchronously in the initramfs, every boot pays for it. The previous image's save script read an exclude file (`~/.save-home-exclude`, falling back to `/etc/dbrrg/save-home-exclude`, one `tar --exclude` pattern per line).
2. **Non-atomic overwrite.** `tar zcf - . | sudo dd of=/boot/efi/home.tar.gz` truncates the only copy of the home first. A power cut or a full ESP mid-write leaves a broken archive, and the next boot comes up with an empty home: no SSH host keys, no WireGuard key. Suggest writing `home.tar.gz.new`, checking it with `gzip -t` and `tar -tzf … | head -1`, then `mv`.
3. **It mounts `/dev/disk/by-partlabel/EFI-SYSTEM` a second time on `/boot/efi`**, although the boot ESP is already mounted at `/run/dbrrg/storage/efi`. Every dbrrg stick carries that partlabel. With a second dbrrg stick plugged in, the symlink can point at the **other** stick, and the home gets written there. Writing to the already-mounted boot ESP avoids both the double vfat mount and the wrong-stick risk.

---

## 5. Hostname is the podman container ID

```
$ hostname
fa0ad0f31bfa
$ cat /etc/hostname
fa0ad0f31bfa
```

`/etc/hosts` has `127.0.1.1 fa0ad0f31bfa`, and `un-dockerize.service` exists but is disabled. The build seems to squash `/` with podman's bind-mounted `/etc/{hostname,hosts,resolv.conf}` still in place. Squashing a plain non-recursive `mount --bind /` of the container root hides those bind mounts (and `/proc`, `/sys`, `/dev`, `/run`), so the image's own files are what get packed.

Cosmetic, but every machine booting this image has the same container ID as its hostname.

---

## Workarounds applied on this machine (remove once the image is fixed)

All of these are in `$HOME` and persisted with the home archive:

| What | Where | Replaces |
|---|---|---|
| Install `wifi.yaml` / `wg0.conf`, start `wg-quick@wg0`, restore a binary parked on the ESP | `~/bin/session-setup.sh`, run by the **user** unit `~/.config/systemd/user/dbrrg-local-setup.service` (`WantedBy=default.target`), log `~/.session-setup.log` | §2 |
| On labwc failure: wait for a non-simpledrm card plus `udevadm wait`, then re-source `/etc/profile.d/10-dbrrg-session.sh` once (guarded by `DBRRG_SESSION_RETRIED`) | end of `~/.profile` (bash reads it right after the profile.d script leaves the failure shell) | §1 |
| Home saved with an exclude-aware, atomic script | `~/bin/save-home` + `~/.save-home-exclude` | §4 |

The user-unit approach for §2 works, but it starts only at autologin (about 11 s into boot), uses `sudo`, and runs `netplan apply` after networkd is already up. The system unit proposed in §2 avoids all three.
