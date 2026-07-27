# Controller Handoff — dbrrg patched labwc (multi-monitor fullscreen + X keyboard grab)

> Starter pack for the next controller session. This handoff lives in ONE
> worktree — run `git worktree list` first and confirm this is the workstream
> you're resuming. Read this first, then `git log <handoff-commit>..HEAD` for
> everything that changed since. Detail is NOT here — it's in git + the
> superpowers plan/ledger/docs (§6). Before you rewrite this file at your own
> handoff: read the previous version (`git show HEAD:docs/controller-handoff.md`)
> and carry forward any lesson in §4/§5 that is still true. Fresh synthesis,
> not blank page. On merge into another branch, rewrite that branch's handoff
> to the merged reality — do not merge or preserve this text.

Handoff commit: 5b93e6f   Date: 2026-07-27   Reason: context budget
Worktree / branch: `/scratch/oetiker/claude-worktrees/dbrrg-feat-ubuntu-2604` @ `feat/session-diagnostics`
Sibling worktrees: `/home/oetiker/checkouts/dbrrg` @ `main`, at `c3508ab` — trunk, **no live work there**; this branch is 12 commits ahead. `main` is also ~20 commits ahead of `origin/main` and unpushed.

## 1. Mission

dbrrg builds a diskless Ubuntu 26.04 thin client that runs entirely from RAM
and whose sole job is the ThinLinc client. The 26.04 upgrade moved the session
from Xorg+wm2 to labwc/Wayland, which broke two things stock labwc cannot do.
This branch fixes both by shipping labwc as a **locally patched rebuild**
(`0.9.3-1+dbrrg1`) instead of the archive package:

- **Patch A** — a fullscreen Xwayland window spans the whole output layout
  instead of being clamped to one output, restoring multi-monitor ThinLinc.
- **Patch B** — implements `zwp_xwayland_keyboard_grab_manager_v1`, the
  protocol rootless Xwayland actually uses to forward `XGrabKeyboard`.

A third fix followed from a review finding: `~/.dbrrg-environment` per-machine
overrides had **never** worked, because labwc re-reads its own `-C`
environment file and overwrites whatever the session script exported. That
broke the new fullscreen knob *and* the pre-existing per-machine keyboard
feature that `CLAUDE.md` documented as working.

The mental model to keep: almost every bug in this layer is an **ordering or
resolution-chain** bug, not a logic bug. Something is installed but not
selected, exported but then overwritten, or asserted against the wrong
artifact. See §4.

## 2. Where we are now

All five tasks complete, reviewed and committed (`74772cf..5b93e6f`, 12
commits). The whole-branch review returned **fit to merge**; its findings were
fixed in `cabbd13`. Test state — every one of these was run and seen by the
controller itself, not taken from a subagent report:

- `test/integration/test-session-packages.sh` — 16/16, including
  `rc.xml registers no keybindings` and `labwc is the local rebuild (0.9.3-1+dbrrg1)`.
- `test/integration/test-labwc-config-merge.sh` — 9/9 (new).
- `make test-runtime` — 3/3: span `2560x720`; Xwayland binds the grab manager;
  a later duplicate env assignment wins (`1280x720`).
- `artifacts/images/dbrrg-usb.img` built 16:24 on 2026-07-27 from this HEAD.

**Confirmed on hardware 2026-07-27**, on the dual-head machine:
- the session starts normally (so the new merged-config-dir path works and
  did not need its fallback);
- fullscreen spans both monitors — Patch A does its job;
- an `XKB_DEFAULT_*` override in `~/.dbrrg-environment` takes effect, which is
  the per-machine feature that had never worked before this branch.

Not observed, still open: whether the remote session sees two distinct screens
rather than one wide one; whether `LABWC_FULLSCREEN_SPAN_OUTPUTS=0` gives
single-monitor fullscreen (same merge path as the keyboard override, so
expected to work); and anything about Patch B, which is unobservable while
keybindings stay at zero.

Not done: the branch is neither merged nor pushed, and
`superpowers:finishing-a-development-branch` was never run.

## 3. Do this next

1. **Finish the branch** — `superpowers:finishing-a-development-branch`. The
   work is done and hardware-confirmed (§2); this is the only thing standing
   between here and merge.
2. Optionally close the two small observation gaps on the next boot: check
   whether the remote session reports two screens (a ThinLinc/remote-side
   check, not a client one), and try `LABWC_FULLSCREEN_SPAN_OUTPUTS=0` to
   exercise the span override specifically.
3. If a session ever fails to start after a change in this area, look in the
   session log for `dbrrg: config merge failed` or `dbrrg: XDG_RUNTIME_DIR
   unset or unwritable`. Either means labwc fell back to
   `-C /etc/dbrrg/labwc` and the merge is the suspect. Get a shell via SSH or
   Ctrl+Alt+F2 — `foot` has no launch path inside the session.

## 4. Lessons & traps  ← the irreplaceable part

Carried forward, still true:

**QEMU proves almost nothing about this product.** Three bugs shipped past a
green `qemu-smoke`. When QEMU and hardware disagree, the hardware is right and
QEMU's pass was luck.

**"Installed" ≠ "selected" ≠ "reaches the hardware".** `xcursor-themes` was
installed but `update-alternatives` never selected it; `intel-ucode` in the
squashfs delivers nothing on kernel 7.0 and works only via dracut's
`early_microcode` default, which nothing pins or tests; `podman build --cpus`
was "verified" by grep and does not exist in podman 4.9.3. Verify to the **end
of the resolution chain, against the built artifact**.

**dracut 110 defaults `hostonly` ON**, and `podman build` shares the host
kernel — 683 modules instead of 955, silently dropping zram and every NIC
driver. `--add-drivers` is not a workaround.

**Ordering is the recurring shape of bugs in the session layer.** XKB is read
once at compositor startup, so user-controlled values must be on disk before
labwc launches — which is why `dbrrg-restore-home` runs in
`10-dbrrg-session.sh`, not `dbrrg-session`. Output rotation likewise must
precede `tlclient`, which reads the monitor layout once.

New this session:

**`_NET_WM_FULLSCREEN_MONITORS` is unnecessary — the earlier conclusion that
multi-monitor was structurally unfixable was wrong.** TigerVNC's
`remoteResize()` (`vncviewer/DesktopWindow.cxx`, fullscreen branch) builds the
remote `ScreenSet` from the window's **actual geometry** versus the X screens
it fully covers. It never reads the atom. Forcing union geometry
compositor-side is therefore sufficient, and yields a genuine two-screen
remote layout. Do not spend time implementing the atom in wlroots.

**labwc silently discards `~/.dbrrg-environment`, and this class of bug will
recur.** `session_environment_init()` (`src/config/session.c:77`) does
`setenv(key, value, 1)` — overwrite — while parsing `<config_dir>/environment`,
and with `-C` that file is the *only* one considered
(`src/common/dir.c:153-157`), at `src/main.c:211`, i.e. **after** the session
script exported the user's values. Exporting into labwc's environment is not
enough: whatever labwc re-reads wins. Hence
`overlay/usr/local/bin/dbrrg-compose-labwc-config`. The ordering assumption it
rests on — that a *later* duplicate assignment wins — is **tested against the
real binary**, not assumed.

**The `export` keyword breaks that same file.** `10-dbrrg-session.sh` sources
it under `set -a` (bare assignments export fine), and labwc's own parser
splits on the first `=`, so an `export ` prefix becomes part of the key and
the variable is never set — with no error. Keep every line bare `KEY=VALUE`.

**The headless rig cannot test keyboard grabs, structurally.**
`WLR_BACKENDS=headless` supplies no input devices, so `wl_seat` advertises
`capabilities(0)`, so Xwayland never creates `xwl_seat->keyboard` and never
installs its grab-forwarding hook. The rig asserts only that Xwayland *binds*
the manager global. Do not "fix" that assertion back to looking for a
`grab_keyboard` request — it can never pass there. wlroots' headless backend
has no `add_input_device` API.

**libwayland 1.24 changed the `WAYLAND_DEBUG` separator from `@` to `#`.** A
reviewer checked the *host's* libwayland 1.22 (`%s@%u`), concluded the rig's
regex could never match, and accused two implementers of fabricating
transcripts. The image ships 1.24 (`%s#%u`); the transcripts were honest.
Check the library the code actually runs against. The assertion now accepts
`[@#]`.

**Patch files must be Makefile prerequisites.** `.ubuntu-container` listed the
Dockerfile, the vendor deb and every overlay file — but not
`containers/ubuntu/patches/*`. Editing a patch therefore did not trigger a
rebuild, so `make rootfs && make test` would validate a **stale image and
report green**. Fixed via `PATCH_FILES` plus the bare directory (so deletions
are caught too). Watch for this shape whenever a new build input appears.

**`.dockerignore` negation cannot un-prune a pruned directory.** `!*.patch`
does not rescue files under a directory excluded by a broader `*` rule — the
directory itself must be negated. This would have shipped an unpatched labwc
while the build stayed green; only the first real patch exposed it.

**Reviewers see the brief, not your dispatch.** Four corrections handed to an
implementer in its dispatch message were silently classed "out of scope" by
the reviewer, which had only read the task brief — so a task passed review
with none of them applied. Requirements added at dispatch time must be
restated into the review prompt as first-class requirements.

**Subagents here do good work and then stall before reporting or committing —
eight times this session.** The work was sound every time; the reporting was
not. Verify against the repo, never the report. For short
verification-and-commit tails, doing it in the controller costs less than
another nudge cycle.

**My own controller error, worth not repeating:** I told the user a
verification rebuild was "in progress" when nothing was running — inferred
from an idle notification plus a modified file rather than checked. `ps`,
`pgrep` and artifact timestamps take seconds. Judge process state by checking
it; a subagent's silence is not evidence of activity.

## 5. Don'ts & constraints

Four constraints live in `CLAUDE.md` under "Standing Constraints" with their
failure modes. Read them before touching the build. Summary:

- **Firmware is selected by package only.** Never re-add a `find`/`rm -rf`
  sweep over `/usr/lib/firmware`. Guarded by `test-firmware.sh`.
- **dracut must keep `--no-hostonly`.** See §4.
- **labwc must register zero keybindings.** Not because of
  `zwp_keyboard_shortcuts_inhibit_manager_v1` — that was this repo's earlier
  (wrong) rationale; rootless Xwayland never requests that inhibition. Our
  labwc now implements the protocol Xwayland *does* use, but keybindings stay
  at zero until a real grab is confirmed on hardware. `foot` is deliberately
  reachable only from a VT or SSH.
- **labwc is a local rebuild (`0.9.3-1+dbrrg1`), not the archive package.**
  Reverting to the archive silently loses both patches. Patches live in
  `containers/ubuntu/patches/` as a quilt series; `dpkg-buildpackage` fails
  loudly if one stops applying.
- Keep `--no-install-recommends --no-install-suggests`.
- **Never more than 4 cores** in any build step — shared machine. `BUILD_JOBS`.

Settled, do not relitigate:
- **The tty1 console fallback stays** — the user chose to keep it after a
  recommendation to remove it; it is commented as intentional.
- `labwc` is the compositor; alternatives were checked and none help.
- `overlay/etc/dbrrg/labwc/rc.xml` stays **out of `$HOME`** — `save-home` tars
  the whole home, so a copy there would be pinned forever on deployed machines
  and the keybinding constraint would become unenforceable in the field.
- Compose is on **right-Alt** (`compose:ralt`), a deliberate divergence.
- `_NET_WM_FULLSCREEN_MONITORS` is rejected — see §4.
- `OXULNK_DEB`'s default path is stale on this machine; pass
  `OXULNK_DEB=vendor/oxulnk-desktop.deb`. Do not "fix" it in the repo without
  asking — the default points at another project's build output.

## 6. Where the detail lives

- Change history: `git log 5b93e6f..HEAD`; `git log 42bd38a..5b93e6f` for this
  workstream's implementation.
- Design spec: `docs/superpowers/specs/2026-07-27-labwc-multimonitor-fullscreen-design.md`
  — records why the atom was rejected and what remains unverified.
- Plan: `docs/superpowers/plans/2026-07-27-labwc-patches.md`
- Progress ledger — every ruling, rejected finding and controller error:
  `.superpowers/sdd/2026-07-27-labwc-patches/progress.md`
- `CLAUDE.md` → "Standing Constraints" and the `.dbrrg-environment` section.
- `overlay/usr/local/bin/dbrrg-compose-labwc-config` — the merge, with the
  full root-cause writeup in its header.
- `overlay/etc/profile.d/10-dbrrg-session.sh` — session launch, home restore,
  env sourcing, the merge call and its fallback. Ordering here is load-bearing.
- `test/runtime/test-labwc-runtime.sh` — the rig; its comment block explains
  what the rig structurally cannot prove.

## 7. Open questions / pending decisions

- **Everything on this branch is hardware-unverified.** Top item.
- **`save-home` is not crash-safe.** `tar zcf - . | sudo dd of=…` doesn't check
  the tar's exit status (no `pipefail`), so an interrupted save leaves a
  truncated `home.tar.gz` that gets restored over the user's home next boot —
  silent data loss. Offered, not done. Worth doing before fleet deployment.
- **Audio remains entirely unverified** (PipeWire wrapper from `2e108fb`).
- **`main` is far behind and unpushed.** The user hasn't said when to push.
- Two Minor items parked from reviews: a `present`-regex missing a `$` anchor
  in `test-session-packages.sh`, and the compose helper's error messages
  dropping errno detail.

## 8. Staleness watch

- The hardware confirmation in §2 covers three specific observations and no
  more. Do not let it drift into "the branch is verified" — Patch B in
  particular has never been exercised and cannot be while keybindings are
  zero.
- Task 5's *fallback* path is still unexercised: the hardware boot took the
  success path, which is the good news but means the `XDG_RUNTIME_DIR`
  unset/unwritable branch has only ever been read, never run.
- `.superpowers/sdd/2026-07-27-labwc-patches/` still exists; the SDD skill says
  to delete it once the final review is clean and the branch finished. It was
  kept because the branch is not finished.
