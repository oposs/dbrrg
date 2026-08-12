# Four field defects: screenshots, minimized windows, script locations, SSH host keys

Date: 2026-08-12

Four defects reported from the field. Three are small and self-contained.
The fourth turned out to be a symptom of where the home restore happens, so
fixing it properly moves the restore into the initramfs — which in turn
simplifies the other fixes rather than complicating them.

Implementation order matters: (d) relocates a script that (c) renames, so
(d)'s shape should be settled before (c)'s mechanical moves are applied.

## a) `grim` is missing — no way to take a screenshot

### Problem

The image ships no screenshot tool. `grim` was never installed, and nothing
pulled it in transitively once the X11 stack was removed.

### Design

Add to the package list in `containers/ubuntu/Dockerfile`:

- `grim` — the Wayland screenshot tool
- `slurp` — interactive region selection, `grim -g "$(slurp)"`
- `wl-clipboard` — `wl-copy`, so a screenshot can be pasted into the
  ThinLinc session rather than only written to a file

Roughly 1 MB installed.

### How it is invoked

The zero-keybindings constraint (CLAUDE.md, "labwc must have zero
keybindings") means there is no in-session trigger and none may be added.
The supported path is from a VT or over SSH, mirroring the existing `foot`
recipe in CLAUDE.md's Debugging section:

```bash
XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 grim /tmp/shot.png
```

This limitation is deliberate and gets documented next to the `foot` recipe,
so the next person does not "fix" it by adding a keybinding.

## b) Minimized windows vanish permanently

### Problem

labwc draws server-side decorations with an iconify button. Clicking it
removes the window from the screen, and with no taskbar, no menu and no
keybindings there is no way to bring it back. The window is unreachable for
the rest of the session.

In practice this hits the ThinLinc client's non-fullscreen windows — the
connect dialog, error popups — because a fullscreen window shows no
titlebar to click.

### Design

Install `waybar` and configure a taskbar.

Config lives at **`/etc/dbrrg/waybar/`**, not under `$HOME`. Same rule as
`rc.xml`: `$HOME` is captured wholesale by `dbrrg-save-home` and restored
wholesale on every boot, so a config file there would be pinned forever on
an already-deployed machine, and a corrected file shipped in a later image
would never reach it.

Two files:

- `overlay/etc/dbrrg/waybar/config.jsonc` — a single `wlr/taskbar` module,
  `all-outputs: true`, `on-click: activate`. No clock, no tray, no
  workspaces: the bar exists to recover lost windows and nothing else.
- `overlay/etc/dbrrg/waybar/style.css` — minimal styling, sized so the bar
  does not dominate a small panel.

Launched from `dbrrg-session` before `tlclient` and killed when the session
body returns, so the compositor-lifetime rule in that script's header still
holds — labwc terminates when its `-S` command returns, and a surviving
waybar would be orphaned:

```sh
waybar -c /etc/dbrrg/waybar/config.jsonc -s /etc/dbrrg/waybar/style.css &
WAYBAR_PID=$!
trap 'kill $WAYBAR_PID 2>/dev/null' EXIT
/opt/thinlinc/bin/tlclient
```

### Known behaviour: the bar is covered while fullscreen

With `LABWC_FULLSCREEN_SPAN_OUTPUTS=1`, a fullscreen ThinLinc client covers
the bar. wlroots places fullscreen surfaces above the layer-shell top layer
and ignores exclusive zones, so waybar reserves no space from a fullscreen
window.

This is accepted, not a defect to chase. The taskbar is visible exactly when
no window is fullscreen, which is the situation in which a window can go
missing. Recorded here so it is not later misread as a waybar
misconfiguration.

## c) Scripts scattered across three directories

### Problem

`save-home` sits in `/opt/thinlinc/bin`, a directory owned by the ThinLinc
package, named as though ThinLinc provided it. It does not — dbrrg ships it.
Its counterpart lives in `/usr/local/bin`. Two halves of one mechanism, two
directories, two naming conventions.

### Design

Consolidate under `/usr/bin` with a single `dbrrg-` prefix:

| from | to |
| --- | --- |
| `overlay/opt/thinlinc/bin/save-home` | `overlay/usr/bin/dbrrg-save-home` |
| `overlay/usr/local/bin/dbrrg-session` | `overlay/usr/bin/dbrrg-session` |
| `overlay/usr/local/bin/dbrrg-compose-labwc-config` | `overlay/usr/bin/dbrrg-compose-labwc-config` |

`dbrrg-restore-home` is **not** in this table. Section (d) turns it into a
library function inside the initramfs, so the script ceases to exist rather
than moving.

Call sites to update:

- `overlay/usr/bin/dbrrg-session` — the `save-home` call
- `overlay/etc/profile.d/10-dbrrg-session.sh` —
  `dbrrg-compose-labwc-config`, the `labwc -S` argument, and the "Retry by
  hand" line in the failure message that repeats it
- `test/integration/test-labwc-config-merge.sh`
- `CLAUDE.md` — boot-flow and persistence sections

No compatibility symlinks. Nothing outside this repository calls these.

**Verify during implementation:** that ThinLinc itself does not invoke
`/opt/thinlinc/bin/save-home` by name. Today only `dbrrg-session` calls it,
but the original path placement suggests it may once have been intended as
a ThinLinc-side hook. Grep `/opt/thinlinc/` in a built image before deleting
the old path.

## d) sshd does not start, and host keys do not persist

### Problem, part 1: no autostart

`regenerate_ssh_host_keys.service` declares `Before=ssh.service ssh.socket`
but is pulled in only by `multi-user.target`. With `DefaultDependencies=yes`
it also carries an implicit `After=basic.target`; `basic.target` is ordered
after `sockets.target`, which is ordered after `ssh.socket`. The unit is
therefore ordered both before and after `ssh.socket`.

systemd resolves an ordering cycle by deleting one of the jobs. Either
outcome is bad: no keys, or no socket.

**This diagnosis must be confirmed before anything is built on it.** On a
booted machine:

```bash
journalctl -b | grep -i "ordering cycle"
systemctl list-jobs
```

If the cycle is not what is actually happening, stop and re-diagnose rather
than applying the fix below and assuming it worked.

### Problem, part 2: no persistence

The root filesystem is a read-only squashfs with a ZRAM overlay, so
`/etc/ssh` is writable but volatile. Keys are regenerated on every boot and
every SSH client reports a changed host key each time. The existing service
comment already acknowledges this.

### Design: the home directory is the persistence channel

Host keys ride inside the home directory, which is already persisted to the
EFI partition (USB) or the boot server (netboot). No new file format, no new
server endpoint, no second mechanism to keep working.

For that to be usable by sshd, the home directory has to be in place before
`multi-user.target` — which it is not today. So the home restore moves into
the initramfs.

#### The home restore moves into the initramfs

`restore_home()` joins
`overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh`, called from
`setup-overlay.sh` immediately after the `machine-id` block, where the
overlay is mounted at `$NEWROOT` and the EFI partition is already mounted at
`$DBRRG_STORAGE/efi`.

| boot mode | source |
| --- | --- |
| USB | `$efi_mount/home.tar.gz` |
| netboot | `curl $BASE_PATH/home.pkg?mac=$MAC` |

`overlay/usr/local/bin/dbrrg-restore-home` is deleted; the
`/usr/local/bin/dbrrg-restore-home` call in `10-dbrrg-session.sh` goes with
it. That file keeps sourcing `~/.dbrrg-environment` and keeps the labwc
config merge — only the restore call leaves.

This does **not** violate the standing rule in that script's header. The
rule forbids moving the restore back *into* `dbrrg-session`, because
`~/.dbrrg-environment` must be on disk before labwc reads `XKB_DEFAULT_*`.
The initramfs is earlier still, so the ordering constraint is satisfied more
robustly than it is now. CLAUDE.md's explanation is updated accordingly
rather than deleted.

Three things this also fixes in passing:

- `dbrrg-restore-home` currently runs `sudo mount /dev/disk/by-partlabel/EFI-SYSTEM
  /boot/efi` even though the initramfs already left that partition mounted.
  In the initramfs it is just a path.
- One fewer use of tluser's NOPASSWD sudo.
- On netboot the archive is fetched once, on the interface the initramfs
  already brought up for `ramroot.sqsh`.

#### Requirements on `restore_home()`

**Bounded waits, never fatal.** The current script contains
`while true; do ping -nc 1 $BOOT_SRV && break; sleep 1; done`. Unbounded at
login is a hung session recoverable from a VT; unbounded in the initramfs is
a machine that never boots. It needs a timeout in the style of
`dbrrg_wait_for_efi()`, and every failure path must `warn` and continue — a
client that cannot fetch its home must still come up with a default one.

**Ownership.** The archive is written by `tar zcf` running as tluser, so it
stores uid/gid 1000 numerically. Extracting as root in the initramfs with
tar's default `--same-owner` restores that correctly. It must **not** be
given `--no-same-owner`. Note this is the opposite of what the key install
below requires, a few lines away in the same feature — comment both.

**Record the boot MAC.** `mount-squashfs.sh` writes the MAC of the interface
it brought up to `$DBRRG_STATE/boot-mac` at the point it brings it up.
`restore_home()` and `dbrrg-save-home` both read it.

Today both `save-home` and `dbrrg-restore-home` run in the booted system and
both derive the MAC from kernel ifindex 2, so they always agree — nothing is
broken now. Moving the restore into the initramfs would introduce the
disagreement: ifindex follows driver registration order, the initramfs loads
a deliberately small driver set, and `mount-squashfs.sh` picks interfaces by
`/sys/class/net/*` glob order instead. On a two-NIC machine those can name
different devices, and the client would then save its home under one MAC and
fetch it under another. Recording the MAC makes the two halves agree by
construction.

The recorded interface is also the better identity: on netboot it is the one
that demonstrably worked, having obtained a DHCP lease and served
`ramroot.sqsh`.

The current fleet is single-NIC, so no deployed client can be stranded by
the change and no migration fallback is included. `/run` survives the pivot,
so `/run/dbrrg/state/boot-mac` is readable in the booted system;
`dbrrg-cleanup.sh` already copies the state directory to `/var/log/dbrrg/`
as a second source. On USB boot the file is simply unused — that path keys
off the EFI partition, not a MAC — so its absence is normal, not an error.

#### Host keys inside the home directory

`overlay/usr/bin/dbrrg-ssh-hostkeys`, run by a new
`dbrrg-ssh-hostkeys.service`:

1. If `~tluser/.dbrrg-ssh-host-keys/` holds keys (the normal case — the
   initramfs restored them), install them into `/etc/ssh`, then
   `chown root:root` and `chmod 600` the private keys, `644` the public
   ones. sshd refuses to start on a group- or world-readable private key,
   and inside the archive these are tluser-owned.
2. Otherwise, if `/etc/ssh/ssh_host_*_key` already exist, do nothing.
3. Otherwise `ssh-keygen -A`, then copy the result into
   `~tluser/.dbrrg-ssh-host-keys/`, tluser-owned, so the next
   `dbrrg-save-home` captures it.

`dbrrg-save-home` additionally refreshes `~/.dbrrg-ssh-host-keys/` from
`/etc/ssh` immediately before tarring, so the archive always carries the
keys that were actually live in the session.

The unit needs no network and touches no EFI partition:

```ini
[Unit]
Description=Install or generate persistent SSH host keys
After=local-fs.target
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/dbrrg-ssh-hostkeys
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

`regenerate_ssh_host_keys.service` is deleted, along with its self-disabling
`ExecStartPost` and the comment describing per-boot regeneration.

#### `ssh.socket` is masked

In `containers/ubuntu/Dockerfile`:

```
systemctl mask ssh.socket
systemctl enable ssh.service    # already present
```

With the unit above carrying no network dependency, masking is no longer
strictly *required* to avoid the cycle — but it is kept deliberately. It
completes an intent the Dockerfile already records: `ssh.service` is enabled
eagerly there precisely because socket activation hides a broken config or a
missing host key behind a failed login instead of a logged unit failure.
Leaving both entry points active means sshd can be reached by two paths with
different ordering, which is what produced the cycle in the first place.
CLAUDE.md records the reason so the mask is not later removed as an apparent
oversight.

### Observed 2026-08-12 (QEMU): the cycle is real, the symptom is not reproduced

`make qemu-smoke` against the pre-fix image confirms the ordering cycle
exactly as predicted:

```
regenerate_ssh_host_keys.service: Found ordering cycle: basic.target/start
  after sockets.target/start after ssh.socket/start after
  regenerate_ssh_host_keys.service/start - after basic.target
regenerate_ssh_host_keys.service: Job sockets.target/start deleted to break
  ordering cycle starting with regenerate_ssh_host_keys.service/start
[ SKIP ] Ordering cycle found, skipping sockets.target
```

Two things this evidence does **not** support, and they must not be claimed:

1. **The deleted job was `sockets.target`, not an ssh unit.** The prediction
   in this spec said systemd would drop "no keys, or no socket". It dropped
   the synchronisation target instead.
2. **sshd started anyway.** In the same boot,
   `regenerate_ssh_host_keys.service` ran to completion, `ssh.socket` reached
   Listening, and `ssh.service` started. The log contains no ssh failure of
   any kind.

So the reported symptom — sshd not autostarting for want of a host key — is
**not reproduced under QEMU**, even though the cycle that causes it is
present.

### What the field report adds

On real hardware the observed sequence was: no host keys existed at all, none
were generated, sshd did not start, and running `ssh-keygen -A` by hand fixed
it immediately.

That is the same cycle resolving differently. systemd names
`regenerate_ssh_host_keys.service` as the cycle's starting point in both
cases; on hardware it deleted **that service's** job, under QEMU it deleted
`sockets.target`'s. Delete the service and no keys exist, so `sshd -t` fails
its precondition and sshd never comes up — precisely the field symptom.
Delete the target instead and everything happens to work.

**Which job systemd deletes to break a cycle is not contractual.** It falls
out of transaction order, so it can differ between boots and between
machines. That makes this a latent, intermittent fault, and it is why the fix
must *remove* the cycle rather than reorder around it — a re-timed cycle is
still a coin flip.

This also disposes of the "the image does not do firstboot" theory. The unit
is enabled in the image and is not first-boot-gated in any way that matters:
its `ExecStartPost` self-disable writes into the volatile ZRAM overlay and is
gone by the next boot. It did not run because its job was deleted.

## e) A second ordering cycle skips systemd-hwdb-update every boot

Found in the same QEMU log while confirming (d), and added to this spec's
scope on 2026-08-12:

```
sysinit.target: Found ordering cycle: systemd-hwdb-update.service/start after
  un-dockerize.service/start after basic.target/start after sysinit.target/start
  - after systemd-hwdb-update.service
[ SKIP ] Ordering cycle found, skipping systemd-hwdb-update.service
```

Same shape as (d). `overlay/etc/systemd/system/un-dockerize.service` declares
`Before=systemd-hwdb-update.service` while being `WantedBy=multi-user.target`.
`systemd-hwdb-update.service` belongs to `sysinit.target`, and a
`DefaultDependencies=yes` unit wanted by `multi-user.target` is implicitly
ordered after `basic.target` and therefore after `sysinit.target` — so the
unit is ordered both before and after the same target.

The `Before=` appears vestigial. Nothing `un-dockerize.service` still does —
stopping `systemd-resolved`, rewriting `resolv.conf` and `/etc/hosts`,
restarting it — has any relationship to the hardware database. The only
plausible original reason is the `depmod`/`modprobe` lines that sit commented
out in the same file.

**Fix:** drop `Before=systemd-hwdb-update.service` from
`un-dockerize.service`.

**Then decide what `systemd-hwdb-update` should do here, and verify rather
than assume.** On a read-only squashfs with a ZRAM overlay, regenerating
`hwdb.bin` at every boot writes a multi-megabyte file into the RAM overlay
for no benefit if the package already ships a prebuilt one. If
`/usr/lib/udev/hwdb.bin` is present in the image, mask the unit and say so;
if it is not, let it run. Check the built image before choosing — this is
exactly the kind of assumption that has bitten this repo before.

Note the current behaviour is not "hwdb is broken": the job has been deleted
on every boot for as long as this cycle has existed, and nothing has been
reported. The reason to fix it is that a silently skipped unit and an
intermittently resolved cycle are both hazards, not that anything is
observably wrong today.

### Accepted limitation: keys persist from the first clean logout

`dbrrg-save-home` runs when the ThinLinc client exits, so a machine that is
hard-powered-off before anyone logs out has not persisted its freshly
generated keys and will generate new ones next boot. From the first clean
logout onward the keys are stable.

This is accepted rather than mitigated. Adding a first-boot copy to the EFI
partition would restore a second persistence mechanism — exactly what this
design removed — for a window that closes the first time anyone uses the
machine normally.

### Security note carried over

`home.pkg` already traverses plain HTTP on netboot, carrying WiFi
credentials and ThinLinc settings. It now also carries private SSH host
keys, so anyone able to observe or intercept boot traffic can impersonate
that client's sshd. This raises what is on an already-exposed channel rather
than opening a new one. Serving the boot path over HTTPS would close it and
is out of scope here.

## Testing

### `test/integration/test-session-packages.sh` (extend)

- `grim`, `slurp`, `wl-clipboard`, `waybar` are installed
- `/etc/dbrrg/waybar/config.jsonc` exists and parses as JSON
- `/usr/bin/dbrrg-save-home`, `dbrrg-session`, `dbrrg-compose-labwc-config`
  and `dbrrg-ssh-hostkeys` exist and are executable
- `/opt/thinlinc/bin/save-home` and `/usr/local/bin/dbrrg-*` are gone
- no file in the image references the old paths
- `ssh.socket` is masked, `ssh.service` is enabled
- `regenerate_ssh_host_keys.service` is absent

### `test/integration/test-initramfs-home.sh` (new)

Offline, in the style of `test-labwc-config-merge.sh`: source the functions
directly, stub `curl`, assert behaviour rather than inspecting a built
image.

1. USB, `home.tar.gz` present → home restored under uid/gid 1000
2. USB, archive absent → default home intact, no failure
3. USB, corrupt archive → `warn`, boot continues
4. netboot, endpoint returns an archive → home restored
5. netboot, endpoint 404s → default home intact, no failure
6. netboot, endpoint hangs → bounded wait, `warn`, boot continues
7. `boot-mac` written by `mount-squashfs.sh` is the MAC used for the fetch
8. `dbrrg-save-home` reads the same `boot-mac` back

### `test/integration/test-ssh-hostkeys.sh` (new)

1. keys present in home → installed to `/etc/ssh`, root-owned, private 600
2. no keys anywhere → `ssh-keygen -A` runs, result copied into home
   tluser-owned
3. keys already in `/etc/ssh`, none in home → no regeneration
4. `dbrrg-save-home` refreshes `~/.dbrrg-ssh-host-keys` before tarring
5. group-readable private key in the archive → corrected on install

Both new scripts are wired into `make test`.

### `make qemu-smoke`

sshd listening after boot. `scripts/check-boot-smoke.sh` gains an assertion
that no ordering cycle was reported.

### Hardware confirmation required

Two claims here can only be settled on a real machine:

- that the ordering cycle is in fact why sshd does not start
- that the same host key survives a reboot after one clean logout

## Documentation

CLAUDE.md updates:

- Debugging: the `grim` recipe beside the existing `foot` one, and a note
  that the absence of a screenshot keybinding is intentional
- A waybar subsection, including the covered-while-fullscreen behaviour
- Boot flow: the home restore now happens in the initramfs, with the
  `~/.dbrrg-environment` ordering rationale rewritten rather than dropped
- Persistent Home Directory: the new script paths, `.dbrrg-ssh-host-keys`,
  and the first-clean-logout limitation
- A note that `ssh.socket` is masked on purpose

## Implementation order

1. (d) first — it decides whether `dbrrg-restore-home` moves or disappears
2. (c) — the mechanical moves, once (d) has settled the file list
3. (a) — packages only
4. (b) — waybar config plus the `dbrrg-session` change

## Out of scope

- Any labwc keybinding, for screenshots or window switching. The
  zero-keybindings constraint holds.
- Moving `home.pkg` onto HTTPS.
- A migration fallback for multi-NIC netboot clients; none exist.
- `mount-squashfs.sh`'s single-interface DHCP attempt, which `break`s after
  one try whether or not the lease succeeded. Real, pre-existing, and
  unrelated to these four defects.
