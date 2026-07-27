# Controller Handoff — dbrrg Ubuntu 26.04 / Wayland / PipeWire upgrade

> Starter pack for the next controller session. This handoff lives in ONE
> worktree — run `git worktree list` first and confirm this is the workstream
> you're resuming. Read this first, then `git log <handoff-commit>..HEAD` for
> everything that changed since. Detail is NOT here — it's in git + the
> superpowers plan/ledger/docs (§6). Before you rewrite this file at your own
> handoff: read the previous version (`git show HEAD:docs/controller-handoff.md`)
> and carry forward any lesson in §4/§5 that is still true. Fresh synthesis,
> not blank page. On merge into another branch, rewrite that branch's handoff
> to the merged reality — do not merge or preserve this text.

Handoff commit: 2cc54c9   Date: 2026-07-27   Reason: context budget
Worktree / branch: `/scratch/oetiker/claude-worktrees/dbrrg-feat-ubuntu-2604` @ `feat/session-diagnostics`
Sibling worktrees: `/home/oetiker/checkouts/dbrrg` @ `main` — trunk, at `c3508ab`. **Live work is here, not there**: this branch is one commit ahead. `main` is 20 commits ahead of `origin/main` and unpushed.

## 1. Mission

dbrrg builds a diskless thin-client image that runs entirely from RAM
(SquashFS + OverlayFS on ZRAM) whose sole job is running the ThinLinc remote
desktop client. The user asked for three things: upgrade to Ubuntu 26.04,
upgrade the ThinLinc client, and fix missing i915 GPU firmware.

The firmware request turned out to be a **build bug, not a packaging gap** —
`export-rootfs.sh` deleted all firmware except `iwlwifi*` right before
`mksquashfs`, so every image ever shipped lacked i915 firmware *and*
`intel-ucode`. That is fixed and merged.

The mental model that matters now: **this is a hardware-integration problem
wearing a packaging problem's clothes.** Everything that can be verified in a
container or QEMU has been. What remains — and what has produced every real
bug since — is behaviour that only appears on the physical NUC: USB
enumeration timing, DRM/plymouth interaction, monitor layout, audio. QEMU
passing means very little here; see §4.

## 2. Where we are now

**Merged to `main` (c3508ab) and validated on hardware — the NUC boots and
runs.** Base 26.04 (kernel 7.0, systemd 259), ThinLinc 4.20.0-4284, firmware
selected declaratively by package, labwc/Wayland replacing nodm/xorg/wm2,
PipeWire replacing PulseAudio, VA-API + `oxulnk-desktop` added. Squashfs
537 MiB (from 498 MB).

**On this branch, one commit above main (2cc54c9), building when this was
written.** Adds user-controlled keyboard and display config. A build was
in flight (`make rootfs && make image && make qemu-smoke`) — check
`artifacts/images/dbrrg-usb.img.zst` mtime against `2cc54c9`'s commit time
before assuming the image on disk contains it.

The user's stated next step: **deploy this build and test**. They have not
yet reported results.

Working but unverified on hardware: audio (either direction), multi-monitor
fullscreen, F8 to the client, PXE boot on a physical NIC.

## 3. Do this next

1. **Confirm the build finished and is green** — `make test` plus
   `scripts/check-boot-smoke.sh artifacts/images/qemu-smoke.log`. If the
   session was rolled over mid-build, it may have died with the shell.
2. **Wait for the user's hardware result.** Do not start new work
   speculatively; the last several rounds were all driven by concrete NUC
   findings, and guessing ahead of them has been consistently wrong (§4).
3. **When they report back**, the two known-open items are multi-monitor
   fullscreen (§7) and `save-home` hardening (§7). Neither is started.

## 4. Lessons & traps  ← the irreplaceable part

**QEMU proves almost nothing about this product.** Three separate bugs
shipped past a green `qemu-smoke`. The boot-medium race is the clearest: the
old code gave the USB device a 2-second budget, and QEMU's virtio-blk
appeared in ~1 second — passing with one second of margin, every time, for
however long that code has existed. When a QEMU result and a hardware result
disagree, **the hardware is right and QEMU's pass was luck.**

**"Installed" ≠ "selected" ≠ "reaches the hardware".** This cost the most
time and recurred three times:
- `xcursor-themes` was installed and verified — but `update-alternatives`
  still resolved `x-cursor-theme` to x11-common's `core.theme` (priority 30
  vs 20), which inherits from a theme that doesn't exist on disk. The "fix"
  provably did nothing until `XCURSOR_THEME` was set explicitly.
- `intel-ucode` in the squashfs delivers nothing on kernel 7.0 (late loading
  is gone). It works only because dracut's `early_microcode` default puts it
  in the initramfs — which nothing in this repo pins or tests.
- `podman build --cpus` was verified present by grep, and doesn't exist in
  podman 4.9.3 at all.
Verify to the **end of the resolution chain**, against the built artifact,
not the source tree.

**dracut 110 defaults `hostonly` ON.** This was the single worst latent bug
found. Because `podman build` shares the host kernel, every `instmods` call
filtered against *the build machine's* loaded modules: 683 modules instead of
955, silently dropping zram (aborts boot) and every NIC driver (breaks PXE).
`overlay` survived only because podman's storage driver keeps overlayfs
loaded — pure luck. `--add-drivers` is **not** a workaround: it bypasses the
filter for its own arguments only.

**labwc's partial EWMH is worse than wm2's absent EWMH, for one case.** Under
wm2 (no EWMH at all) ThinLinc sized *itself* to the union of both monitors
and wm2 left it alone — multi-monitor fullscreen worked. labwc implements
`_NET_WM_STATE_FULLSCREEN`, honours it, and clamps to one output.
`_NET_WM_FULLSCREEN_MONITORS` is implemented **nowhere** in the practical
field — checked and absent from libwlroots (so sway/cage/wayfire/labwc all
lack it), and from openbox and i3. Switching compositors will not fix this.

**Ordering is the recurring shape of bugs in the session layer.** XKB is read
once at compositor startup, so anything user-controlled must be on disk
before labwc launches — which is why `dbrrg-restore-home` now runs in
`10-dbrrg-session.sh` and not in `dbrrg-session`. Similarly, output rotation
must be applied before `tlclient` starts, because the client reads the
monitor layout once.

**My own tooling produced two false readings.** `pgrep -f "qemu…"` matched
the watcher's own command line (always true); `pgrep -x qemu-system-x86_64`
never matches because the name exceeds 15 chars (always false). Use `pidof`.
And I reported a smoke failure that was actually my checker racing a log
QEMU was still writing. **Judge the finished artifact, never process timing.**

**Subagents in this session completed good work and then went silent ~10
times**, several times leaving everything uncommitted. The work was sound
every time; the reporting wasn't. Verify against the repo, not the report.

## 5. Don'ts & constraints

Three constraints are recorded in `CLAUDE.md` under "Standing Constraints"
with their failure modes. Read them before touching the build. Summary:

- **Firmware is selected by package only.** Never re-add a `find`/`rm -rf`
  sweep over `/usr/lib/firmware`. Guarded by `test/integration/test-firmware.sh`.
- **dracut must keep `--no-hostonly`.** See §4.
- **labwc must register zero keybindings.** labwc 0.9.3 lacks
  `zwp_keyboard_shortcuts_inhibit_manager_v1`, so any key it binds can never
  reach the remote session. Guarded by `test-session-packages.sh`. Do not add
  a "convenient" terminal shortcut — `foot` is deliberately reachable only
  from a VT or SSH.
- Keep `--no-install-recommends --no-install-suggests`; it is what stops
  `linux-firmware-minimal` pulling ~1.5 GB.
- **Never more than 4 cores** in any build step — shared machine. `BUILD_JOBS`.

Settled decisions, do not relitigate:
- **The tty1 console fallback stays.** The user chose to keep it after I
  recommended removing it. It is commented as intentional in
  `10-dbrrg-session.sh`; do not "clean up" what looks like leftover debugging.
- `labwc` is the compositor. Alternatives were checked and none solve the
  multi-monitor problem (§4).
- `overlay/etc/dbrrg/labwc/rc.xml` stays **out of `$HOME`** — `save-home`
  tars the whole home with no excludes, so a copy there would be pinned on
  deployed machines forever and the keybinding constraint would become
  unenforceable in the field. User-editable config goes in `$HOME`; system
  config does not.
- Compose is on **right-Alt** (`compose:ralt`), a deliberate divergence from
  the migration table in `docs/superpowers/specs/`.

## 6. Where the detail lives

- Change history: `git log 2cc54c9..HEAD`, and `git log c3508ab..HEAD` for
  this branch's work above trunk.
- Plan: `docs/superpowers/plans/2026-07-26-ubuntu-2604-upgrade.md`
- Design spec: `docs/superpowers/specs/2026-07-26-ubuntu-2604-upgrade-design.md`
- Progress ledger (every task, review, finding and ruling, including two
  controller errors): `.superpowers/sdd/2026-07-26-ubuntu-2604-upgrade/progress.md`
- `CLAUDE.md` → "Standing Constraints" — the three load-bearing rules.
- `overlay/etc/profile.d/10-dbrrg-session.sh` — session launch, home restore,
  env sourcing order, tty1 fallback. The ordering here is load-bearing.
- `overlay/usr/local/bin/dbrrg-session` — restore is *not* here, deliberately.
- `overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh` —
  `dbrrg_wait_for_efi()`, the boot-medium poll.
- `overlay/opt/thinlinc/lib/tlclient/pulseaudio` — the audio wrapper; replaces
  Cendio's bundled PulseAudio 6.0 and translates the module spec.

## 7. Open questions / pending decisions

- **Multi-monitor fullscreen.** ThinLinc spans both monitors under wm2 but
  not labwc (§4). The user confirmed the L-shaped geometry worked fine before
  and wants it back. Most promising angle, untried: stop ThinLinc requesting
  WM fullscreen and let it size itself to the union, as it did under wm2 —
  check what geometry options `tlclient.conf` exposes. Alternative is
  patching labwc to honour `_NET_WM_FULLSCREEN_MONITORS`.
- **`save-home` is not crash-safe.** `tar zcf - . | sudo dd of=…` doesn't
  check the tar's exit status (no `pipefail`), so an interrupted save leaves a
  truncated `home.tar.gz` that gets restored over the user's home next boot.
  Silent data loss. Offered, not yet done: write to a temp file, verify,
  rename. Worth doing before fleet deployment.
- **Audio is entirely unverified.** The wrapper drops ThinLinc's `cookie=`
  and substitutes `auth-anonymous=true` on a loopback listener. Note before
  concluding it's a regression: the *old* wrapper also passed an invalid
  `cookie=` to PulseAudio 16, so that module may never have loaded on 24.04
  either.
- **`main` is 20 commits ahead of `origin/main`, unpushed.** The user hasn't
  said when to push.
- Per-machine keyboard now works via `~/.dbrrg-environment`, but has not been
  tested on hardware.

## 8. Staleness watch

- **A build was running when this was written.** Its outcome is unknown here.
  Check `artifacts/` mtimes and rerun `make test` before trusting any image.
- **The user was about to deploy and test.** Any hardware finding they report
  supersedes §2 and probably §7. Expect the first message of the next session
  to invalidate part of this file.
- §7's multi-monitor angle ("let ThinLinc size itself") is an untested
  hypothesis, not a plan. It is based on the user's report that wm2 behaved
  that way, which is credible but not something I verified.
- The `mutter` check in §4 covered only its helper libraries, not the main
  `libmutter-*.so`. The wlroots/openbox/i3 results are solid; mutter's is not.
- The `.superpowers/sdd/` workspace still exists. The SDD skill says to
  delete it once the final review is merged; it was kept because the ledger
  holds the hardware checklist and the reasoning behind each ruling.
