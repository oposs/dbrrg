# Controller handoff — four-defects workstream

**Written:** 2026-08-12, mid-run, after Task 7 of 11.
**Worktree:** `/scratch/oetiker/claude-worktrees/dbrrg-four-defects`
**Branch:** `worktree-four-defects` (ff'd from local `main` @ c1d1546 — note
`origin/main` is far behind local `main`; do not branch from origin).

Read this, then `git log c1d1546..HEAD`, then the SDD ledger at
`.superpowers/sdd/2026-08-12-four-defects/progress.md`. **The ledger is the
authoritative record** — it carries every commit, finding, ruling and piece of
evidence. This file is the judgement that is not obvious from it.

## What this workstream is

Four defects the user reported, plus a fifth found during execution:

| | defect | status |
| --- | --- | --- |
| a | `grim` missing — no way to screenshot | Task 8, pending |
| b | minimized windows unreachable | Task 9, pending |
| c | `save-home` in `/opt/thinlinc/bin` | Task 7, done (build verifying) |
| d | sshd does not start; host keys not persisted | Tasks 2-6, DONE + verified |
| e | second ordering cycle (hwdb) — found in the Task 1 QEMU log | Task 11, pending |

Spec: `docs/superpowers/specs/2026-08-12-four-defects-design.md`
Plan: `docs/superpowers/plans/2026-08-12-four-defects.md`

## The one architectural decision everything rests on

The user's idea, not mine, and it was better than my design: **persist SSH host
keys inside the home directory**, which is already saved to the EFI partition
(USB) or the boot server (netboot). That deleted an entire EFI file format and a
`hostkeys.pkg` server endpoint from the design.

It only works if the home directory is populated before `multi-user.target`, so
**the home restore moved out of `/etc/profile.d/10-dbrrg-session.sh` and into the
dracut initramfs** (`restore_home()` in `dbrrg-lib.sh`, called from
`setup-overlay.sh`). That is the largest change in the branch.

Moving it EARLIER does not violate the standing rule in `10-dbrrg-session.sh` —
that rule forbids moving it back INTO `dbrrg-session`, because
`~/.dbrrg-environment` must be on disk before labwc reads `XKB_DEFAULT_*`. The
initramfs satisfies it a fortiori. Do not let anyone "restore" the old placement.

## Lessons that cost real time — carry these forward

**1. Verify the artifact, never the exit code.** Three separate false greens:
- `make ... | tail` reports *tail's* status. A hard build failure ("No rule to
  make target") was reported as exit 0 by both `$?` and the harness
  notification. Caught only because the initramfs file count and mtime had not
  changed. All builds now go through
  `.superpowers/sdd/2026-08-12-four-defects/build.sh` (sets `pipefail`, keeps a
  full log at `last-build.log`).
- `tail -25` in that same wrapper hid three of four `make test` suite verdicts,
  so "all suites passed" would have been an inference. Wrapper now logs in full.
- **`unsquashfs -d <path>` exits 0 even when the path does not exist.** It is
  NOT a presence test. This silently broke two assertions, one of them
  pre-existing and guarding a documented standing constraint (see below).

**2. Read the vendor's actual unit files before reasoning about systemd.** The
spec said `systemctl mask ssh.socket`, the user approved it twice, and it would
have shipped an image with **no sshd at all** — Ubuntu's `ssh.socket` declares
`RequiredBy=ssh.service`, so masking it makes `ssh.service` fail with "Unit
ssh.socket is masked". The fix is `disable` THEN `mask`, in that order; disable
is a no-op on an already-masked unit. `sshd-keygen.service` needed masking too:
it is `WantedBy` four different units, so disabling `ssh.socket` removes only one
of its four `.wants` symlinks, and it races `dbrrg-ssh-hostkeys.service`.

**3. QEMU is weak evidence for boot ordering.** The same ordering cycle produced
a clean boot under QEMU (systemd deleted `sockets.target`) and a dead sshd on the
user's hardware (it deleted the key-generation service). Which job systemd
deletes to break a cycle is not contractual. Any "it works in QEMU" claim about
ordering in this repo should be treated as provisional.

**4. Tests that pass on the broken image are worse than no tests.** My original
assertion checked that the mask symlink existed — equally true on an image with
no sshd. The assertion that matters is the ABSENCE of
`etc/systemd/system/ssh.service.requires/ssh.socket`. Anchor squashfs listing
greps to `^squashfs-root/etc/systemd/system/...`; an unanchored one also matches
`var/lib/systemd/deb-systemd-helper-enabled/...`, which is dpkg bookkeeping and
survives `systemctl disable` by design.

**5. Fault-inject every load-bearing assertion.** Two tests in this branch were
self-confirming until injected against: the rc.xml zero-keybindings guard (which
printed "ok" for an image containing no rc.xml at all) and the host-key top-up
test (whose `ssh-keygen` stub overwrote all keys unconditionally, so it could
never distinguish "topped up" from "was already there"). Scripts that prove both
are kept in the SDD workspace: `verify-rcxml-guard.sh`, `verify-topup.sh`,
`verify-t3-fix.sh`, `verify-url.sh`, `verify-url2.sh`.

## Process that worked, and should continue

- **Subagents edit; the controller builds.** A container rebuild outlasts a
  subagent turn timeout; on timeout the harness backgrounds the build and ends
  the turn, killing it. Every implementer dispatch says explicitly: do not run
  `make`/podman, run only the offline tests. This has held with no deadlocks.
- **Re-derive subagent numbers.** Assertion counts were misreported four times
  across three agents (15/17 when the true count was 18, 22 when it was 25).
  The suites were genuinely green each time — but count claims are not evidence.
  Use `grep -c '^ok   -'` on captured output yourself.
- **Reviewers must be told to `SendMessage` to "main".** Several ended their
  turn with the review as plain output, which never reached the controller. An
  idle notification is not a report; check the worktree and re-request.
- Briefs come from `scripts/task-brief`; regenerate after any plan amendment,
  since several tasks' briefs were amended mid-run.

## Build environment — REQUIRED

`make` must be invoked through `.superpowers/sdd/2026-08-12-four-defects/build.sh`.
It pins `OXULNK_DEB` to a snapshot at
`.superpowers/sdd/2026-08-12-four-defects/oxulnk-pinned.deb`, because the real
oxulnk-desktop deb is **work in progress**: it is rebuilt under a new
dev-timestamped filename while this run is going, so the Makefile's default path
vanishes mid-run and each new deb also invalidates the container layer cache.

**Before the Task 10 final image, ask the user whether to re-pin to their newest
oxulnk build.** Costs one full container rebuild.

`artifacts/` is a symlink to `/scratch/oetiker/dbrrg-artifacts`, **shared with the
main checkout**. Do not build in both concurrently.

## What remains

- **Task 7** — build + `make test` running as this was written. Then review.
  The implementer found and fixed a dangling `subprocess.run(["save-home"])` in
  `overlay/usr/bin/upgrade-image` that the plan did not anticipate.
  Still owed: the image-level check that ThinLinc itself does not invoke
  `/opt/thinlinc/bin/save-home` by name (grep `/opt/thinlinc/` in a built image).
- **Task 8** — `grim`/`slurp`/`wl-clipboard` packages. Small.
- **Task 9** — waybar taskbar. Note the accepted behaviour: a fullscreen
  ThinLinc client COVERS the bar (wlroots puts fullscreen above the layer-shell
  top layer and ignores exclusive zones). That is intended, documented, and must
  not be "fixed".
- **Task 11** — remove `Before=systemd-hwdb-update.service` from
  `un-dockerize.service`. Its Step 2 requires CHECKING whether
  `usr/lib/udev/hwdb.bin` ships prebuilt before deciding whether to mask the
  unit — do not assume. Adds `unwant "no systemd ordering cycle"` to
  `check-boot-smoke.sh`; run it AFTER Task 6 so both cycles are already gone.
- **Task 10** — full verification. **Needs the user on real hardware** for the
  two things nothing here can establish: that a host key survives a reboot after
  one clean logout, and that the waybar taskbar actually restores a minimized
  ThinLinc dialog.

## Deferred / parked

- Minor: two "rejects empty input" assertions in `test-initramfs-home.sh` can
  pass vacuously (an undefined function also returns non-zero). Inherited from
  the plan text. Flagged to the final whole-branch review.
- Contested minor: a re-reviewer called the new comment density "above project
  norms". The controller's ruling is that it matches house style — this repo's
  `dbrrg-lib.sh` and `10-dbrrg-session.sh` are deliberately comment-dense with
  rationale. Left standing.
- Out of scope, real, recorded in the spec: `mount-squashfs.sh` tries exactly one
  interface for DHCP and `break`s whether or not the lease succeeded.
