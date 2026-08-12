# Four field defects: screenshots, minimized windows, save-home location, SSH host keys

Date: 2026-08-12

Four independent defects reported from the field. They share no code, so
they can be implemented and reviewed in any order — except that (c) renames
scripts that (b) and (d) both touch, so (c) should land first to avoid
rewriting the same call sites twice.

## a) `grim` is missing — no way to take a screenshot

### Problem

The image ships no screenshot tool. `grim` was never installed, and nothing
pulled it in transitively once the X11 stack was removed.

### Design

Add to the package list in `containers/ubuntu/Dockerfile`:

- `grim` — the Wayland screenshot tool
- `slurp` — interactive region selection, `grim -g "$(slurp)"`
- `wl-clipboard` — `wl-copy` so a screenshot can be pasted into the ThinLinc
  session rather than only written to a file

Roughly 1 MB installed.

### How it is invoked

The zero-keybindings constraint (see CLAUDE.md, "labwc must have zero
keybindings") means there is no in-session trigger and none may be added.
The supported path is from a VT or over SSH, mirroring the existing `foot`
recipe in CLAUDE.md's Debugging section:

```bash
XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 grim /tmp/shot.png
```

This is a deliberate limitation, not an oversight: it is documented in
CLAUDE.md alongside the `foot` recipe so the next person does not "fix" it
by adding a keybinding.

## b) Minimized windows vanish permanently

### Problem

labwc draws server-side decorations with an iconify button. Clicking it
removes the window from the screen, and with no taskbar, no menu and no
keybindings there is no way to bring it back. The window is unreachable for
the rest of the session.

The windows this affects in practice are the ThinLinc client's
non-fullscreen ones — the connect dialog, error popups — because a
fullscreen window has no visible titlebar to click.

### Design

Install `waybar` and configure a taskbar.

Config lives at **`/etc/dbrrg/waybar/`**, not under `$HOME`. This follows
the same rule as `rc.xml`: `$HOME` is captured wholesale by
`dbrrg-save-home` and restored wholesale on every boot, so a config file
there would be pinned forever on an already-deployed machine and a
corrected file in a future image would never reach it.

Two files:

- `overlay/etc/dbrrg/waybar/config.jsonc` — a single `wlr/taskbar` module,
  `all-outputs: true`, `on-click: activate`. No clock, no tray, no
  workspaces: the bar exists to recover lost windows, nothing else.
- `overlay/etc/dbrrg/waybar/style.css` — minimal styling, sized so the bar
  does not dominate a small panel.

Launched from `dbrrg-session` before `tlclient` and killed when the session
body returns, so the compositor-lifetime rule in that script's header still
holds (labwc terminates when `-S` returns; a surviving waybar would be
orphaned):

```sh
waybar -c /etc/dbrrg/waybar/config.jsonc -s /etc/dbrrg/waybar/style.css &
WAYBAR_PID=$!
trap 'kill $WAYBAR_PID 2>/dev/null' EXIT
/opt/thinlinc/bin/tlclient
```

### Known behaviour: the bar is covered while fullscreen

With `LABWC_FULLSCREEN_SPAN_OUTPUTS=1`, a fullscreen ThinLinc client covers
the bar. wlroots places fullscreen surfaces above the layer-shell top layer
and ignores exclusive zones, so waybar does not reserve space from a
fullscreen window.

This is accepted, not a bug to chase. The taskbar is visible exactly when no
window is fullscreen, which is the situation in which a window can go
missing. Documenting it here so it is not later misread as a waybar
misconfiguration.

## c) `save-home` lives in `/opt/thinlinc/bin`

### Problem

`save-home` sits in `/opt/thinlinc/bin`, a directory owned by the ThinLinc
package, and is named as though ThinLinc provided it. It does not — dbrrg
ships it. Meanwhile its counterpart `dbrrg-restore-home` is in
`/usr/local/bin`, so the two halves of one mechanism live in two places
under two naming conventions.

### Design

Move all four dbrrg scripts to `/usr/bin` under a single `dbrrg-` prefix:

| from | to |
| --- | --- |
| `overlay/opt/thinlinc/bin/save-home` | `overlay/usr/bin/dbrrg-save-home` |
| `overlay/usr/local/bin/dbrrg-restore-home` | `overlay/usr/bin/dbrrg-restore-home` |
| `overlay/usr/local/bin/dbrrg-session` | `overlay/usr/bin/dbrrg-session` |
| `overlay/usr/local/bin/dbrrg-compose-labwc-config` | `overlay/usr/bin/dbrrg-compose-labwc-config` |

Call sites to update:

- `overlay/usr/bin/dbrrg-session` — the `save-home` call
- `overlay/etc/profile.d/10-dbrrg-session.sh` — `dbrrg-restore-home`,
  `dbrrg-compose-labwc-config`, and the `labwc -S` argument (which also
  appears in the failure-message "Retry by hand" line)
- `test/integration/test-labwc-config-merge.sh`
- `CLAUDE.md` — the boot-flow and persistence sections

No compatibility symlink is left behind. Nothing outside this repo calls
these scripts.

**Verify during implementation:** that ThinLinc itself does not invoke
`/opt/thinlinc/bin/save-home` by name. Today only `dbrrg-session` calls it,
but the original path placement suggests it may once have been intended as
a ThinLinc-side hook. Grep `/opt/thinlinc/` in a built image before
deleting the old path.

## d) sshd does not start, and host keys do not persist

### Problem, part 1: no autostart

`regenerate_ssh_host_keys.service` declares `Before=ssh.service ssh.socket`
but is pulled in only by `multi-user.target`. With `DefaultDependencies=yes`
it therefore also carries an implicit `After=basic.target`, and
`basic.target` is ordered after `sockets.target`, which is ordered after
`ssh.socket`. The unit is thus ordered both before and after `ssh.socket`.

systemd resolves an ordering cycle by deleting one of the jobs. Whichever it
picks, the outcome is bad: either the keys are never generated, or the
socket never starts.

**This diagnosis must be confirmed before it is built on.** On a booted
machine:

```bash
journalctl -b | grep -i "ordering cycle"
systemctl list-jobs
```

If the cycle is not what is actually happening, stop and re-diagnose rather
than applying the fix below and assuming it worked.

### Problem, part 2: no persistence

Even when key generation does run, the root filesystem is a read-only
squashfs with a ZRAM overlay. `/etc/ssh` is writable but volatile, so keys
are regenerated on every boot and every SSH client reports a changed host
key each time. The existing service comment already acknowledges this and
names the fix: persist under `/config` on the EFI partition, as `machine-id`
already is.

### Design: restore in the initramfs, generate in the running system

Split by capability. The initramfs has `curl` and `tar` and the EFI
partition mounted; it does not have `ssh-keygen`, and adding it would drag
`libcrypto.so.3` in for roughly 5 MB. So the initramfs restores existing
keys and the running system generates missing ones.

#### Initramfs: restore only

New `restore_ssh_host_keys()` in
`overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh`, called from
`setup-overlay.sh` immediately after the `machine-id` block, where the EFI
partition is already mounted and `$NEWROOT` already exists.

| boot mode | restore |
| --- | --- |
| USB | untar `$efi_mount/config/ssh-host-keys.tgz` into `$NEWROOT/etc/ssh` |
| netboot | `curl -f $BASE_PATH/hostkeys.pkg?mac=$MAC` piped into `tar -zx` |

No new tools: `module-setup.sh` already installs `curl`, `tar` is present.

Every failure path calls `warn`, never `die`. A machine that cannot restore
its keys must still boot — it simply generates fresh ones in the next step.
On netboot the first boot is a 404, which is the expected case and not an
error.

#### Running system: `dbrrg-ssh-hostkeys`

New `overlay/usr/bin/dbrrg-ssh-hostkeys`:

1. If `/etc/ssh/ssh_host_*_key` already exist, exit 0. This is the normal
   case on every boot after the first — the initramfs restored them.
2. Otherwise `ssh-keygen -A`.
3. Persist:
   - USB: tar the keys to `config/ssh-host-keys.tgz` on the EFI partition.
     `dbrrg-cleanup.sh` deliberately leaves it mounted at
     `/run/dbrrg/storage/efi`, so no mount is needed; the script falls back
     to mounting `EFI-SYSTEM` itself only if that mountpoint is gone.
   - Netboot: `curl -F data=@...` to `$BASE_PATH/hostkeys.pkg?mac=$MAC`.

Boot-mode detection reuses the `/proc/cmdline` parsing already used by
`dbrrg-save-home` and `dbrrg-restore-home`.

New `overlay/etc/systemd/system/dbrrg-ssh-hostkeys.service`:

```ini
[Unit]
Description=Restore or generate persistent SSH host keys
Wants=network-online.target
After=network-online.target
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/dbrrg-ssh-hostkeys
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

`regenerate_ssh_host_keys.service` is deleted, along with its
self-disabling `ExecStartPost` and the comment describing per-boot
regeneration.

#### Masking `ssh.socket` is required, not incidental

Persisting on netboot needs the network, so the unit must be
`After=network-online.target`. But `ssh.socket` is ordered before
`sockets.target`, which precedes `basic.target`, which precedes
`network.target`. `Before=ssh.socket` combined with
`After=network-online.target` reproduces exactly the cycle described above.

The way out is to stop having two entry points into sshd. In
`containers/ubuntu/Dockerfile`:

```
systemctl mask ssh.socket
systemctl enable ssh.service    # already present
```

This completes an intent the Dockerfile already records: `ssh.service` is
enabled eagerly there precisely because socket activation hides a broken
config or a missing host key behind a failed login instead of a logged unit
failure. Masking the socket makes that intent whole rather than
half-applied.

**Consequence:** sshd starts after `network-online.target` rather than at
`sockets.target`. Nothing can connect before the network is up, so the
practical cost is nil — but the boot ordering does change, and that is
stated here rather than discovered later.

### Risk accepted: host keys traverse plain HTTP on netboot

Netboot clients have no EFI partition, so persistence means uploading the
key tarball to the boot server, keyed by MAC, alongside the existing
`home.pkg` mechanism.

This puts **private** SSH host keys on the network and at rest on the boot
server. Over plain HTTP, anyone able to observe or intercept the boot
traffic can impersonate that client's sshd. The same exposure already
applies to `home.pkg`, which carries WiFi credentials and ThinLinc settings,
so this does not open a new channel — but it does raise what is on it.

This was chosen deliberately over the alternative (netboot keeps
regenerating keys every boot, accepting host-key churn there). Revisit if
the boot transport is ever expected to carry untrusted networks; serving the
boot path over HTTPS would close it.

### Server-side requirement

The boot server needs a `hostkeys.pkg` endpoint mirroring `home.pkg`: GET
returns the stored tarball for a MAC (404 when absent), POST stores it. This
is outside this repository and must be deployed before netboot clients gain
key persistence. USB boot has no such dependency and works as soon as the
image ships.

## Testing

### `test/integration/test-session-packages.sh` (extend)

- `grim`, `slurp`, `wl-clipboard`, `waybar` are installed
- `/etc/dbrrg/waybar/config.jsonc` exists and parses as JSON
- `/usr/bin/dbrrg-save-home`, `dbrrg-restore-home`, `dbrrg-session` and
  `dbrrg-compose-labwc-config` exist and are executable
- `/opt/thinlinc/bin/save-home` and `/usr/local/bin/dbrrg-*` are gone
- no file in the image references the old paths
- `ssh.socket` is masked and `ssh.service` is enabled
- `regenerate_ssh_host_keys.service` is absent

### `test/integration/test-ssh-hostkeys.sh` (new)

Offline, in the style of `test-labwc-config-merge.sh`: source the functions
directly, stub `curl` and `ssh-keygen`, assert behaviour rather than
inspecting the image.

Cases:

1. USB, tarball present → keys land in `$NEWROOT/etc/ssh`
2. USB, tarball absent → nothing written, no failure
3. USB, no keys after restore → generate, tarball written to EFI
4. netboot, endpoint returns a tarball → keys restored
5. netboot, endpoint 404s → nothing written, no failure
6. netboot, no keys after restore → generate, POST issued with the right MAC
7. keys already present → script exits 0 without calling `ssh-keygen`
8. corrupt tarball / EFI unwritable / `curl` failing → `warn`, exit non-fatal

Wired into `make test`.

### `make qemu-smoke`

Should show sshd listening. The smoke log check in
`scripts/check-boot-smoke.sh` gains an assertion that no ordering cycle was
reported.

### Documentation

CLAUDE.md updates:

- Debugging section: the `grim` recipe next to the existing `foot` one, and
  a note that the absence of a screenshot keybinding is intentional
- A waybar subsection under session configuration, including the
  covered-while-fullscreen behaviour
- Boot-flow and persistence sections: the new script paths
- The `/config` description gains `ssh-host-keys.tgz` alongside `machine-id`
- A note that `ssh.socket` is masked on purpose, with the cycle as the
  reason, so it is not re-enabled as an apparent oversight

## Implementation order

1. (c) — the moves, first, so later work edits final paths
2. (a) — packages only
3. (b) — waybar config plus the `dbrrg-session` change
4. (d) — largest, and the only one needing hardware confirmation of the
   diagnosis before it starts

## Out of scope

- Adding any labwc keybinding, for screenshots or window switching. The
  zero-keybindings constraint holds.
- Reworking `home.pkg`/`hostkeys.pkg` onto HTTPS.
- Simplifying `dbrrg-save-home`'s EFI mount to reuse the already-mounted
  `/run/dbrrg/storage/efi`. Real, but unrelated to these four defects.
