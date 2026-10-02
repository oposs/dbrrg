# dbrrg tile menu: a desktop grid for the thin client session

Date: 2026-10-01
Status: designed, not implemented.

## Problem

The session has exactly one thing in it. `overlay/usr/bin/dbrrg-session` runs
`/opt/thinlinc/bin/tlclient` in the foreground, and when the client exits the
script runs `dbrrg-save-home` and returns, which ends the labwc session and
hands the machine back to getty.

Everything else a person might want to do at the machine is unreachable from
the machine. `upgrade-image` is documented in the README as `sudo
upgrade-image` and can only be started over SSH or from a VT. `foot` has no
launch path at all, because the image ships zero labwc keybindings and no root
menu, which `CLAUDE.md` records as a standing constraint. `oxulnk-desktop` is
installed and has a `.desktop` file that nothing reads. Saving the home
directory happens as a side effect of quitting ThinLinc and at no other time.

A user at the machine therefore has one action available, and an operator has
to bring a second machine or a keyboard shortcut that does not exist.

## Findings

Measured against `ubuntu:26.04` and the built image `localhost/dbrrg-ubuntu:3.0.0`
on 2026-10-01.

### No tile grid exists in the archive

`nwg-launchers` and `nwg-drawer`, the usual Wayland tile grids, are not in
Ubuntu 26.04. `wofi`, `fuzzel` and `tofi` are present and draw a list, not a
grid. `yad` draws an icon grid from a directory of `.desktop` files and would
suit the shape of the problem, and `zenity` draws neither.

### What image size costs depends on the boot path

`artifacts/rootfs/ramroot.sqsh` is 548 MB, and the two boot paths in
`mount-squashfs.sh` pay for that differently.

On USB boot the EFI partition is mounted and the file is loop-mounted from
the stick. Pages are read on demand into the page cache and the kernel
reclaims them under pressure, so image size costs space on the stick and read
latency, not memory.

On network boot the script creates a `ramfs` and curls the whole file into it
before mounting the loop device. Every byte of the image is then pinned for
the life of the boot: `ramfs` is not `tmpfs`, so those pages cannot be swapped
and cannot be reclaimed. Image size there is memory taken from the user's
session, and download time at every boot.

- `yad`: 1 new package and no measurable size. The image already has GTK3,
  because waybar is a GTK3 application. An earlier draft of this section said
  131 MB and 106 packages, measured against a bare `ubuntu:26.04` rather than
  against this image, which was wrong.
- `python3-gi` with `gir1.2-gtk-4.0`: 384 MB installed, 176 new packages.
- `fuzzel`: 22 MB installed, 31 new packages, and it is a list.

A Rust binary using egui adds a single file of roughly 15 MB to 25 MB and no
new packages. What a winit plus softbuffer binary needs at runtime is
`libwayland-client.so.0`, `libwayland-cursor.so.0` and `libxkbcommon.so.0`,
and the image has all of them, from labwc and waybar. Not from
`oxulnk-desktop`: that is an X11 client and declares no Wayland library at
all. For comparison, `/usr/bin/oxulnk-desktop` is 33 MB.

### The GPU is not used, and the Vulkan path would not have worked anyway

The menu rasterises on the CPU, into a `softbuffer` surface backed by
`wl_shm`. This is a decision, not a fallback.

The measurements behind it: the image has Mesa's `iris_dri.so` for current
Intel graphics, `crocus_dri.so` for older Intel and `swrast_dri.so` as a
software fallback, with `libEGL`, `libGLESv2`, `libgbm` and `libwayland-egl`.
`/usr/share/vulkan/icd.d` does not exist, so the Vulkan loader at
`/usr/lib/x86_64-linux-gnu/libvulkan.so.1` has no driver behind it. A wgpu
backend would therefore work on any development machine that has Mesa's Vulkan
drivers and fail on every machine this image is built for.

A GL backend would work, and is still not used. It makes the menu a second
consumer of a GL context inside a compositor that is already the first one,
and it makes the menu's ability to start depend on EGL context creation
succeeding on whatever graphics the client happens to have. `softbuffer`
writes pixels into shared memory, which needs `libwayland-client` and nothing
else.

This does not make the client usable without a graphics driver. labwc is
wlroots based and needs Mesa to start at all, so a machine whose driver fails
has no session for the menu to appear in. What the choice removes is one
failure mode inside a session that did start.

## Design

A new program `dbrrg-menu` draws a full screen grid of tiles and is the body
of the session. It is written in Rust with egui, using the components from the
`egui-shadcn` skill.

The crate lives at `src/dbrrg-menu/` and is built in a new stage of
`containers/ubuntu/Dockerfile`, in the same shape as the existing
`labwc-build` stage. `Cargo.lock` is committed and the build uses `--locked`.

The crate must also be a prerequisite of the `.ubuntu-container` target in the
`Makefile`, as `MENU_FILES` alongside `PATCH_FILES`. `OVERLAY_FILES`
(`Makefile:79`) only finds files under `overlay/`, and the crate cannot live
there because `overlay/` is copied into the shipped rootfs. Without the new
prerequisite, editing `main.rs` leaves the stamp file valid, `make rootfs`
reports nothing to be done, and `make test` validates a stale binary while
printing green. `Makefile:81-94` is a comment about this having already
happened once with the labwc patches.

The build cost is real and should be expected: a cargo stage compiling egui,
winit and resvg, limited to 4 cores, adds minutes to every `make rootfs` that
touches the overlay, on top of the existing labwc build.

### Prerequisite, already done

`dbrrg-save-home` had to be fixed before any of this could be built on, and
was, in commit `cfe7aa0`. It archived `$HOME`, which is `/root` when the
script is called from a process running under sudo, and it exited on its
second line on any USB boot because it read a file that only the netboot
branch of `restore_home()` writes. Both defects lost the user's home and the
machine's SSH identity silently. The spec's earlier claim that
`upgrade-image`'s existing `dbrrg-save-home` call was correct was false.

### Rendering without a GPU

The menu drives egui itself with `egui-winit` and `begin_pass`/`end_pass`, not
eframe, and rasterises the resulting meshes into a `softbuffer` surface. The
reference for this is `references/cpu-rendering.md` in the `egui-shadcn` skill,
and these of its rules shape the design rather than only the code:

- A full window raster costs on the order of 100 ms, and how often the menu
  rasters matters more than how long one raster takes. `egui-winit` asks for a
  repaint on every `CursorMoved`, so the loop fingerprints the clipped
  primitives and skips both raster and present when nothing changed. Moving
  the mouse across a static grid must not re-raster it.
- The loop honours `repaint_delay` from `viewport_output`. Ignoring it leaves
  the first screen drawn in fallback fonts until the user moves the mouse,
  because the font atlas lands one frame late.
- Feathering is off, and tessellation uses the same `pixels_per_point` egui
  laid out with. A coverage blending assumption on an integer rasteriser shows
  up as fringes on rounded corners.
- Widget animation time is zero. An animated toggle on a CPU rasteriser
  arrives as a sequence of visibly staged full frames.
- The save runs on a worker thread, not on the event loop. The invariant is
  one action at a time, enforced by the menu refusing input, not by blocking
  the loop: a netboot save can spend 60 seconds pinging before it starts, and
  a window that stops answering frame callbacks for that long is
  indistinguishable from a dead menu. The dialog shows elapsed time.
- The save-home modal dims the grid behind it once, when it opens. Only the
  dialog redraws after that. Alpha blending a full window backdrop every
  frame is the most expensive thing this program could do, and it would do it
  exactly while a `tar` is running.
- Tile icons are rasterised once at startup and cached as pixmaps. `resvg`
  output is not something to recompute per frame.
- `egui-winit` is built with `default-features = false` and features `links`
  and `wayland`, not `x11`. The menu is a native Wayland client, and this
  section exists to remove failure modes rather than keep a second backend
  alive. The defaults are avoided because they pull `smithay-clipboard`, which
  segfaults on Wayland since its thread shares winit's `wl_display`.
- Pointer routing does not use `ctx.is_pointer_over_egui()`, which is always
  true under a `CentralPanel` in a hand driven loop. The predicate is
  `layer_id_at(pointer_interact_pos)` with an order above `Background`, and it
  is unit tested headless against a `RawInput`.

### Session lifecycle

`dbrrg-session` runs `dbrrg-menu` where it runs `tlclient` today. A tile that
starts a program spawns it, waits for it, and returns to the grid.

The grid comes up on every boot and no tile starts by itself. An
`X-DBRRG-Autostart=true` key on `10-thinlinc.desktop` was considered and
rejected on 2026-10-01. It would have kept the machines in the field going
straight to the ThinLinc login as they do today, at the cost of the decision
that the grid is what the user sees first. Every deployed machine therefore
changes behaviour with this image: it shows a grid, and reaching the ThinLinc
login takes one click.

The menu never shuts the machine down itself. It asks by exit code, and
`dbrrg-session` carries it out:

- `0`: Log out. The menu has already saved the home directory behind its
  dialog, or the save failed and the person at the machine chose "Log out
  anyway". dbrrg-session does not save. getty starts a fresh session.
- `10`: Save the home directory, then `sudo systemctl reboot`.
- `11`: Save the home directory, then `sudo systemctl poweroff`.
- Anything else: the menu failed. Do **not** save, print a diagnostic, and
  hold rather than returning.

The `sudo` is required. There is no polkit in this image, no `polkitd` and no
`pkexec`, and systemd gates `Reboot` and `PowerOff` for non-root callers on a
polkit authority. `dbrrg-session` runs as `tluser`, so a bare `systemctl
reboot` is refused and the user is dropped back at a fresh grid with no error.
`tluser` does have passwordless sudo (`Dockerfile:157`), which is how
`dbrrg-save-home:62,85` already escalates. `dbrrg-session` checks the exit
status of the reboot command and surfaces a failure, because falling through
to a fresh grid is indistinguishable from the user changing their mind.

The default branch must be failure, not logout. A Rust panic exits 101, a
segfault gives 139, a failed exec gives 126 or 127. Treating those as logout
makes a crash silent, and combined with the respawn described under Error
handling it would archive the home once per loop.

The indirection through `dbrrg-session` exists because `dbrrg-save-home` needs
a live session. It reads the home directory, calls `sudo
/usr/bin/dbrrg-ssh-hostkeys --stage`, mounts the EFI partition or posts to the
boot server, and on a netbooted machine waits up to 60 seconds for that server
to answer. A `systemctl poweroff` issued from inside the menu starts tearing
the session down while the archive is still being written.

Home is also saved when a tile carrying `X-DBRRG-Save-On-Exit=true` finishes,
which the ThinLinc and oxulnk tiles do. This preserves today's behaviour of
saving when the ThinLinc client quits. The key is per tile and defaults to
false, because the terminal tile would otherwise archive the home every time
someone closes a shell, and `upgrade-image` already saves at the end of a
successful run.

`waybar` and the `swayidle` blanking continue to run as they do now.

### Tile sources

Tiles come from two directories, read in this order:

- `/etc/dbrrg/menu/*.desktop`: The shipped tiles. They live outside `$HOME`
  for the reason recorded in `CLAUDE.md` for `rc.xml` and the waybar config:
  the home directory is captured and restored whole, so a file kept inside it
  is pinned on a deployed machine and a corrected file in a later image never
  arrives.
- `~/.config/dbrrg/menu/*.desktop`: The user's own tiles. They are inside the
  saved home, so `dbrrg-save-home` keeps them and the initramfs restores them
  on the next boot, which is what makes a tile a per machine customisation
  that survives without an image rebuild.

Both sets are sorted together by file name, so the shipped files are named
`10-thinlinc.desktop`, `20-oxulnk.desktop` and so on, leaving gaps for user
files to sort between them.

The user directory adds tiles and may reword the shipped ones, and four
further rules keep that from becoming a way to break the machine. A restored
home is re-restored on every boot, so one bad file must not be able to make
the machine unusable:

- A user file whose name matches a shipped file **rewords that tile rather
  than replacing it.** Only `Name`, `Comment` and `Icon` are taken from the
  user file. `Exec`, `X-DBRRG-Action`, `Terminal` and
  `X-DBRRG-Save-On-Exit` always come from the shipped file and are ignored in
  the user file, so a user file can make a tile read wrong but never make it
  unlaunchable, and the shutdown contract with `dbrrg-session` stays out of
  reach of a restored home. The grid shows on the tile that it was reworded,
  and names any key it ignored. Name matching is case sensitive, so
  `10-ThinLinc.desktop` does not collide with `10-thinlinc.desktop`; it is
  accepted as an ordinary user tile and sorts next to the real one.
- At most 32 user files are read, and only regular files in a real directory.
  `~/.config/dbrrg/menu` being a symlink, a regular file, or a directory with
  200000 entries must not hang or crash the grid.
- A parse failure is caught per file. One malformed file disables one tile.
- If fewer tiles render than the shipped set contains, the grid falls back to
  the shipped set alone and says why. The grid also scrolls, so user tiles
  sorting before the shipped ones cannot push them off screen. Without
that rule a saved home with one broken file removes the tile that launches
ThinLinc, on a machine with no keybindings and no menu to recover from, and
the next boot restores the same broken file.

### Tile file format

Ordinary desktop entry keys are read: `Name`, `Comment`, `Icon`, `Exec` and
`Terminal`. `Terminal=true` wraps the command in `foot`. Icon resolution is
described under Icons below.

Two extension keys are added. `X-DBRRG-Action` selects the behaviour:

- `run`: Spawn `Exec` and wait. The default when the key is absent.
- `save-home`: Run `dbrrg-save-home` behind the modal.
- `logout`: Exit 0.
- `reboot`: Exit 10.
- `poweroff`: Exit 11.

`X-DBRRG-Save-On-Exit=true` saves the home directory when the tile's program
exits. It defaults to false, is valid on a user tile, and is **ignored unless
the action is `run`**: the other actions have no program, `save-home` would
save twice, and the shutdown actions save unconditionally already.

A user file may use the `run` action only. A user file that names any other
action is rejected and reported on the tile, because the shutdown contract
between the menu and `dbrrg-session` is not something a restored home should
be able to redefine.

Which keys a user file may set depends on whether it stands alone or rewords a
shipped tile:

| key | own tile | rewording a shipped tile |
| --- | --- | --- |
| `Name`, `Comment`, `Icon` | set by the user | set by the user |
| `Exec`, `Terminal` | set by the user | ignored, shipped value wins |
| `X-DBRRG-Action` | `run` only | ignored, shipped value wins |
| `X-DBRRG-Save-On-Exit` | set by the user | ignored, shipped value wins |

An ignored key is not an error. The file still rewords the tile, and the grid
names the keys it dropped so the difference between "my file was ignored" and
"those keys are not mine to set" is visible at the machine.

### Icons

Icons are rendered from SVG and PNG by the menu itself, using `resvg` for SVG.
That costs roughly 1.5 MB in the binary, needs no system package, and the icon
files ship as they are drawn.

The image already has an icon theme. `adwaita-icon-theme` 50.0 is installed,
803 files, pulled in by `libgtk-3-0t64`, which is present because waybar is a
GTK3 application. All five action icons therefore already exist as symbolic
SVGs under `/usr/share/icons/Adwaita/`, and no artwork needs to be drawn,
shipped or licensed. An earlier draft of this section said the image had no
icon theme and that the five action tiles had no artwork anywhere. Both were
wrong, from a truncated listing read as evidence.

The two application tiles use the logos the packages already install, in full
colour, so ThinLinc and oxulnk stay recognisable.

Recolouring an action icon takes an explicit step, which resvg will not do by
itself. Adwaita's symbolic icons hardcode `fill="#2e3436"` and rely on GTK
recolouring them at load time; Lucide's use `stroke="currentColor"`, which
resvg resolves to black. Either way the menu substitutes the colour in the SVG
source before parsing, or tints the rasterised pixmap.

The action tiles use Lucide, decided on 2026-10-01. Adwaita costs nothing and
is already installed, but its symbolic icons are drawn on a 16x16 grid
(`drive-harddisk` and `media-removable` are 128x128, the three `*-symbolic`
ones are 16x16) and look coarse on a large tile. Lucide is drawn at 24 px with
stroke geometry that scales.

The five SVGs live in the crate's source tree and are installed to
`/usr/share/dbrrg/icons/`, a few kilobytes. The source is
`lucide-static@1.49.0`, ISC licensed, so its licence text ships beside them.

All five names below were **verified against that release** on 2026-10-01:
`hard-drive-download`, `usb`, `log-out`, `rotate-cw` and `power` all exist, as
does `terminal` for the foot tile. Re-check them on a version bump rather than
assuming: a name that no longer exists resolves to the letter fallback
described below, so the tile still appears, still launches, and the typo does
not announce itself.

`Icon=` resolves in this order:

- An absolute path, used as given.
- `/usr/share/dbrrg/icons/<name>.svg`, the shipped Lucide set.
- `/usr/share/icons/hicolor`: `scalable/apps/<name>.svg` first, then the
  largest pixel size. "Largest first" alone is ambiguous because `scalable`
  sorts between `48x48` and `256x256`, and `foot` ships both a scalable SVG
  and a 48x48 PNG.
- `/usr/share/icons/Adwaita/symbolic/**/<name>.svg`, then
  `/usr/share/icons/Adwaita/scalable/**/<name>.svg`, so a user tile can name
  any of the 715 icons already installed.
- A fallback that draws the first letter of `Name` on the tile.

The fallback exists so a user tile with a misspelled or missing icon still
appears and still launches. A tile that silently vanishes on a machine with no
keybindings cannot be diagnosed from the machine.

An earlier draft listed the Adwaita lookup twice, as the second step and again
as the fourth.

### Shipped tiles

| file | icon |
| --- | --- |
| `10-thinlinc.desktop` | `/opt/thinlinc/lib/tlclient/thinlinc_128.png` |
| `20-oxulnk.desktop` | `oxulnk-desktop` from `hicolor` |
| `30-terminal.desktop` | `foot` from `hicolor` |
| `40-save-home.desktop` | Lucide `hard-drive-download` |
| `50-upgrade-image.desktop` | Lucide `usb` |
| `80-logout.desktop` | Lucide `log-out` |
| `90-reboot.desktop` | Lucide `rotate-cw` |
| `95-poweroff.desktop` | Lucide `power` |

`30-terminal` runs `foot`. `tluser` has passwordless sudo, so this is a route
to a root shell for anyone at the keyboard. The same route already exists over
SSH and from a VT, so the tile makes it visible rather than making it
possible. Confirmed with the user on 2026-10-02: passwordless sudo for
`tluser` is the intended design, because the person at the keyboard of a thin
client is the person who administers it, and both `upgrade-image` and
`dbrrg-save-home` already depend on it. Do not propose removing it.

`50-upgrade-image` runs `sudo upgrade-image` in `foot`. The existing text
interface is kept.

### Copying a home onto a new stick

`upgrade-image` gains one question, in `do_fresh_install()` only, asked after
the image is written and defaulting to no: copy this machine's home directory
onto the new drive.

The source directory is `pwd.getpwnam("tluser").pw_dir`, never `~`,
`Path.home()` or `SUDO_USER`. By that point the process is root, so HOME is
`/root`, and `SUDO_USER` is unset for a VT root login, which is reachable
because root has no password. This is the same defect as the one `cfe7aa0`
fixed in `dbrrg-save-home`, arriving by a different door.

The destination is addressed by device node, from
`find_efi_partition(device)`, and mounted at a temporary directory. It must
not be reached through `/dev/disk/by-partlabel/EFI-SYSTEM`: a fresh install
writes the whole image byte for byte, so after `partprobe` two partitions
carry `PARTLABEL=EFI-SYSTEM`, the same PARTUUID and the same FAT label, and
that symlink resolves to whichever udev saw last. `dbrrg-save-home:84-88`
mounts exactly that symlink, so a save after a fresh install can land on the
wrong stick. Closing that for the save path as well was decided on
2026-10-01.

**Corrected 2026-10-02.** The first version of this paragraph said the save
should record the device node in the initramfs and mount it again at logout,
"by recording the node rather than by consulting a mount table: nothing mounts
the EFI partition during a normal session, so there is no mounted partition to
prefer". **That premise was false.** The boot ESP is mounted read-write at
`/run/dbrrg/storage/efi` by `mount-squashfs.sh:71` and deliberately left
mounted: `dbrrg-cleanup.sh` says "Do NOT unmount squashfs, EFI partition,
ZRAM, or overlay! They are needed for the running system." The mount survives
the pivot, which `dbrrg-save-home` already proves by reading
`/run/dbrrg/state/boot-mac` successfully in the booted system.

A field report from a NUC7i3BNK
(`docs/reports/2026-10-01-nuc7i3bnk-first-boot.md`, §4.3) found this, and it
is right. So the save writes to `/run/dbrrg/storage/efi`, which is by
construction the partition this boot read — the goal the breadcrumb was
invented to reach, without the breadcrumb, and without mounting the same vfat
filesystem a second time. The shipped `dbrrg-save-home` has no
by-partlabel fallback (2026-10-02): with nothing mounted it reports "nowhere
to store" (exit 4). No `boot-efi-dev` state
file is written, and `dbrrg_wait_for_efi()` is unchanged.

On yes it writes `home.tar.gz` to the new drive's EFI partition, which is the
file `restore_home()` reads at boot, so the new stick comes up with the user's
WiFi credentials, ThinLinc settings and customisations already in place.

The archive excludes `~/.dbrrg-ssh-host-keys`. That directory is the machine's
SSH identity, staged there by `dbrrg-ssh-hostkeys --stage` at every clean
logout, and copying it gives two machines the same host key. A machine booted
from the new stick finds no staged keys, `dbrrg-ssh-hostkeys.service`
generates its own on first boot, and its first clean logout stages them.

The A/B upgrade path needs no such question, because it writes to a drive that
already carries that machine's home.

Two changes to the existing save at `upgrade-image:649-652` go with this. Its
`timeout=60` is shorter than `dbrrg-save-home`'s own 60 second ping bound on a
netbooted machine, so the child is killed, possibly mid upload, and the bare
`except Exception: pass` discards it. The timeout rises above that bound plus
the tar and upload, and a non-zero result is reported rather than swallowed.

`dbrrg-save-home` also needs distinct exit codes for its refusals. Today the
restore-failed refusal, the unreachable-server refusal and the "no idea how to
store your home" branch all `exit 0`, and the last one still prints "home
saved". Nothing can tell success from refusal without scraping stderr for
sentences. The menu switches on exit codes instead, and additionally reads
`<state-dir>/home-restore` itself so the save tile is greyed out with the
reason before anyone waits a minute for a refusal.

The fresh install path already refuses to overwrite the running boot drive, so
the home being copied is always the live one.

### Error handling

A tile whose `Exec` names a program that is not installed is drawn disabled
with the reason on it, and the rest of the grid works. A malformed tile file
is reported the same way, naming the file.

A failing `dbrrg-menu` must be diagnosable at the machine, and today's
machinery cannot do it. `10-dbrrg-session.sh:121` captures **labwc's** exit
status, not `dbrrg-session`'s, and labwc always exits 0. Measured against the
shipped binary:

```
-S command exits 10  -> labwc exits 0
-S command exits 0   -> labwc exits 0
-S command exits 101 -> labwc exits 0
```

So `DBRRG_SESSION_RC` is always 0, the script always takes `exit 0`, and getty
starts a fresh session. The failure screen in that file fires only when labwc
itself cannot start. The same gap exists today for `tlclient`: a client that
fails respawns silently, which is not what the comment in that file describes.

Two changes close it. `dbrrg-session` handles a non-zero `dbrrg-menu` exit
itself rather than returning: it prints the diagnostic and holds, keeping
labwc alive so there is something on screen. And `10-dbrrg-session.sh` counts
restarts and falls through to its failure screen after several fast failures,
which also covers the `tlclient` case. labwc does log the child's status
(`[ERROR] [../src/server.c:167] spawned child 12 exited with 10`), so the
session log still names what happened.

Without this, a menu that crashes after drawing the grid reaches
`dbrrg-save-home` once per loop and re-archives the home each pass.

When a boot's home restore failed, `dbrrg-save-home` refuses to save and says
so on stderr. The menu shows that refusal rather than reporting a successful
save.

## Delivery order

Three pieces, in this order. The reason is independent value and independent
risk, not length.

1. **The `upgrade-image` home copy.** It depends on nothing else here, it is
   useful today from an SSH session, and it stands on the `dbrrg-save-home`
   fix that `cfe7aa0` landed.
2. **The menu with `run`, `save-home` and `logout` only.** One unit: the grid,
   the tile format and the icons are not separable, because a grid with no
   tiles is nothing. `logout` is exit 0, which is what the session does today.
3. **Reboot and shutdown.** Every data-destroying failure mode in this design
   lives here, and the menu is fully useful without them.

## Testing

The project has `make test` (six shell scripts over an `unsquashfs`-ed
`ramroot.sqsh`) and `make test-runtime` (labwc headless with
`WLR_RENDERER=pixman` plus `python3-xlib`). There is no Rust toolchain in the
repo, the image or the test images, and `test/unit/` is empty. The plan below
is what that harness can actually run.

A new `make test-unit` target runs `cargo test` on the host for the parser
rules: desktop entry parsing, name ordering across the two directories, a user
file rewording a shipped tile's `Name`, `Comment` and `Icon`, the same file's
`Exec`, `Terminal`, `X-DBRRG-Action` and `X-DBRRG-Save-On-Exit` being ignored
in favour of the shipped values, a standalone user file not claiming an action
other than `run`, `X-DBRRG-Save-On-Exit` ignored outside `run`, the 32 file
cap, the icon resolution order including the fallback, and the pointer routing
predicate headless against a `RawInput`. These are the rules that keep a
restored home from making a machine unusable, so they are the tests that must
not be the ones that get skipped.

The reword path needs one test that is easy to leave out and is the whole
point of the rule: a user file that rewords `10-thinlinc.desktop` *and* names
a broken `Exec` still launches the shipped `tlclient`.

`test/integration/test-session-packages.sh` gains, in the shape it already
uses for `usr/bin/labwc`:

- `/usr/bin/dbrrg-menu` and the eight shipped tile files are present.
- The binary links neither Vulkan nor GL, so a later switch to a GPU backend
  fails here instead of on a client.
- `dbrrg-session` launches `dbrrg-menu`.
- Every shipped tile's `Icon=` resolves to a file that exists in the image.
  `thinlinc_128.png` is an absolute path into `/opt/thinlinc/`, which has
  moved across client versions before.
- `Cargo.lock` is committed and contains no `smithay-clipboard`.

No `egui_kittest` image snapshot. Its snapshots render through wgpu, which
needs a working Vulkan or GL driver, and this design's premise is that the
target has none. Adding it would mean stating what the build host provides,
and an untested renderer story is how that test ends up quietly disabled.

The runtime check that the grid maps full screen cannot use `x11-probe.py`,
because a native Wayland client has no X connection to query. The menu prints
its own configure size when `DBRRG_MENU_DEBUG` is set, and the runtime test
asserts on that.

## Decisions taken

The three things this spec left open were settled on 2026-10-01, and two more
on 2026-10-02. Each one is written into the section that implements it; this
list exists so a reader does not have to hunt for them.

Settled 2026-10-02:

- **Tile text on the shipped tiles is approved as the mockup draws it**, and a
  user file may reword a shipped tile without rebuilding the image. The
  override covers `Name`, `Comment` and `Icon` and nothing else. See Tile
  sources and Tile file format.
- **`tluser` keeps passwordless sudo.** It is how `upgrade-image` and
  `dbrrg-save-home` escalate today, and the terminal tile is meant to make
  that route visible rather than add it. The person at the keyboard of a thin
  client is the person who administers it. This is the intended design, not a
  tolerated gap. See Shipped tiles.
- **Log out saves in the menu first.** The Log out tile runs
  `dbrrg-save-home` behind the same dialog as Back up home and exits 0 only
  after it. A failed or refused save shows the reason and offers Stay or
  Log out anyway; it never logs out by itself. A boot whose restore failed
  is asked at once, without a save attempt. `dbrrg-session` no longer saves
  on any status, so exit 0 means the save is done or was declined at the
  machine. Item 3's reboot and poweroff follow the same rule.

Settled 2026-10-01:

- **Icon set: Lucide.** The five SVGs ship in the crate and install to
  `/usr/share/dbrrg/icons/`, from `lucide-static@1.49.0` with its ISC licence
  beside them. All five names are verified against that release. See Icons.
- **No autostart.** The grid comes first on every boot and no tile starts by
  itself, so a deployed machine shows a grid where it shows a ThinLinc login
  today. See Session lifecycle.
- **`dbrrg-save-home` stops trusting `by-partlabel`.** It writes to the ESP
  the initramfs already mounted at `/run/dbrrg/storage/efi`, which is by
  construction the partition this boot read, and never mounts by partlabel.
  (The first version of this bullet said the initramfs records the device
  node; see "Corrected 2026-10-02" under Copying a home onto a new stick.)

## Mockup

`https://claude.ai/artifact/URQJWXkBctqKPWosDwuAPP` is an interactive mockup of
the grid built from this spec on 2026-10-01: the nine tiles (eight shipped plus
a user tile sorting between them), the three failure states drawn on the tile
itself, the save modal with its elapsed timer, and the exit codes handed back
to `dbrrg-session`. It is a picture, not the program.

The `Name` and `Comment` text it draws was approved on 2026-10-02 and is the
shipped wording. A machine can reword any of it from
`~/.config/dbrrg/menu/` without an image rebuild; see Tile sources.

One thing it does not settle: the ThinLinc and oxulnk tiles show a placeholder
rather than the logos their own packages install, and nobody has looked at
what those artwork files are at tile size.

## Known limits

The grid appears on one monitor. The labwc patch in
`containers/ubuntu/patches/0001` extends fullscreen across outputs for
Xwayland views only, and `dbrrg-menu` is a native Wayland client, so the
patch does not apply to it. The ThinLinc client continues to span every
monitor.

A fullscreen ThinLinc client covers `waybar`, which is recorded as intended
behaviour. The menu is not running while a client is in the foreground, so it
is not affected.

First paint takes about a tenth of a second, because the first frame is a full
CPU raster of the whole screen. Later frames are clipped to what changed.

Saving the home directory after every client exit costs the length of a `tar`
and, on a netbooted machine, an upload, each time the user returns to the
grid.

## Out of scope

- Hiding shipped tiles per machine. Nothing asks for it yet, and the file
  layout allows adding it later without moving anything.
- Authentication on the grid. `tluser` has no password, and session security
  is ThinLinc's job, which is the same reason the session has no lock screen.
- Rewriting `upgrade-image` as a graphical program.
- Shipping icon artwork. Adwaita is already in the image.
- A keybinding to reach the terminal. The zero keybindings constraint stands,
  and the tile is the launch path.
