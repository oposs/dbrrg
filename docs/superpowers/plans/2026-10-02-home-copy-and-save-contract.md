# Home Copy and Save Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **SUPERSEDED IN PART, 2026-10-02.** Tasks 1, 2 and 3 are obsolete and must
> not be implemented from this file. A field report
> (`docs/reports/2026-10-01-nuc7i3bnk-first-boot.md`, §4.3) disproved the
> premise they rest on: the boot ESP **is** mounted, read-write, at
> `/run/dbrrg/storage/efi`, and `dbrrg-cleanup.sh` leaves it mounted on
> purpose. So no `boot-efi-dev` breadcrumb is needed — the save writes to the
> existing mount. Those three tasks, plus the exclude list and the atomic
> write the same report found, are now Task 4 of
> `docs/superpowers/plans/2026-10-02-nuc7-field-report-fixes.md`, which runs
> first.
>
> **Tasks 4, 5 and 6 still stand** — the `upgrade-image` home copy and its
> save-call fix are untouched by the correction. Resume from Task 4 once the
> field-report plan has landed, and note that Task 6's assertions about
> `boot-efi-dev` must be dropped.

**Goal:** `upgrade-image` can copy this machine's home directory onto a
freshly installed drive, and `dbrrg-save-home` reports what it did through
distinct exit codes instead of always exiting 0.

**Architecture:** Three layers change, bottom up. The initramfs records the
EFI device node it actually read, so the save addresses that node instead of a
`by-partlabel` symlink that can resolve to the wrong stick after a fresh
install. `dbrrg-save-home` mounts the recorded node and gives each of its
refusals its own exit code. `upgrade-image` gains one question in
`do_fresh_install()` that writes the user's home onto the new drive, and its
existing save call stops killing the child at 60 seconds and stops discarding
the error.

**Tech Stack:** POSIX shell (`dbrrg-save-home`, the dracut module), Python 3.12
stdlib only (`upgrade-image`, its tests via `unittest`), bash for the
integration tests. No new runtime dependency and no new package in the image.

**Spec:** `docs/superpowers/specs/2026-10-01-tile-menu-design.md` — sections
"Copying a home onto a new stick" and "Error handling". This plan implements
delivery item 1 of three. Items 2 and 3 (the `dbrrg-menu` crate) are a
separate plan, written after this one lands, because the menu switches on the
exit codes this plan defines.

## Global Constraints

- **Never resolve a user path from `$HOME`, `~`, `Path.home()` or
  `SUDO_USER`.** Use `getent passwd tluser | cut -d: -f6` in shell and
  `pwd.getpwnam("tluser").pw_dir` in Python. `sudo` on this image sets
  `HOME=/root` (`Defaults env_reset`, no `env_keep` for HOME), and `SUDO_USER`
  is unset for a VT root login, which is reachable because root has no
  password.
- **Every read of a file under the state directory ends in `|| true`.** `set -e`
  ends a script on `X=$(cat missing)`, and `boot-home-base` is written only on
  the netboot branch.
- **The home archive must exclude `~/.dbrrg-ssh-host-keys`.** That directory is
  the machine's SSH identity; copying it gives two machines the same host key.
- **`upgrade-image` imports from the Python 3.12 standard library only.** The
  image ships no pip packages for it.
- **Tests must run unprivileged and offline.** `mount`, `umount`, `dd`, `sudo`
  and `curl` are stubbed on `PATH`; `tar` is real, because archiving a temp
  directory needs no privileges and the archive's contents are the assertion.
- **Shell is `/bin/sh` with `set -e`** in `dbrrg-save-home`. No bashisms.
- Exact exit codes for `dbrrg-save-home`, used verbatim by the menu plan:

  | code | meaning | kind |
  | --- | --- | --- |
  | `0` | home saved | success |
  | `1` | the resolved home directory is missing or is not a directory | refusal |
  | `2` | this boot's home restore failed | refusal |
  | `3` | the boot server is unreachable | refusal |
  | `4` | this machine has no known place to store a home | refusal |
  | `5` | the save was attempted and failed | failure |

  `1` is already shipped and keeps its meaning. `5` is not named in the spec
  and is added deliberately: without it a failed upload exits `1` under
  `set -e` and the menu would tell the user their home directory is missing.

## Review Focus

Five conditions this plan's code will meet that the spec does not mention. Each
line names the task whose tests pin it.

- **`getpwnam("tluser")` raises `KeyError`** on an image where the account was
  renamed or removed. A bare lookup crashes `upgrade-image` with a traceback
  *after* the new image is written, so the user sees a successful install
  followed by a stack trace. Expected: the copy is skipped with a named reason
  and the install still reports success. → Task 5.
- **The home directory does not fit on the EFI partition.** `tar` fails partway
  and leaves a truncated `home.tar.gz` that the next boot's restore may accept
  as valid, replacing a good home with a broken one. Expected: a failed archive
  is removed, not left behind. → Task 5.
- **`umount` fails because the mount is busy.** The archive is still in the page
  cache and the drive is pulled out with an empty or partial file on it.
  Expected: `umount` failure is reported as a failed copy, not a successful
  one. → Task 5.
- **`find_efi_partition()` returns `None` straight after `partprobe`**, because
  udev has not re-read the new partition table yet. Expected: the copy retries
  briefly rather than silently skipping, and says so if it gives up. → Task 5.
- **The home contains a socket, a dangling symlink or a file being written.**
  GNU `tar` exits `1` for "file changed as we read it" while producing a
  usable archive, and exits `2` for a real error. Expected: exit `1` is
  reported as a warning and the archive kept; exit `2` discards it. → Task 5.

---

## File Structure

| file | responsibility | change |
| --- | --- | --- |
| `overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh` | initramfs helpers | record `boot-efi-dev` on both successful returns of `dbrrg_wait_for_efi`; make three paths overridable so the recording is testable |
| `overlay/usr/bin/dbrrg-save-home` | save the home at logout | mount the recorded node; one exit code per outcome |
| `overlay/usr/bin/upgrade-image` | install and upgrade drives | the home copy question, the archive builder, the fixed existing save call |
| `test/integration/test-initramfs-home.sh` | the initramfs helpers, offline | assertions for `boot-efi-dev` |
| `test/integration/test-save-home.sh` | `dbrrg-save-home`, offline | assertions for the node preference and every exit code |
| `test/unit/test_upgrade_image.py` | `upgrade-image`, offline | new file: the archive builder and the copy wrapper |
| `Makefile` | build and test entry points | new `test-unit` target, wired into `test` |

`upgrade-image` is one 680-line script and stays one script: it is a
self-contained text UI with no importable siblings, and splitting it is not
this plan's job. The new code is three functions beside the existing ones.

---

### Task 1: Record the EFI device node in the initramfs

**Files:**
- Modify: `overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh:25-28` (the
  `readonly` declarations) and `:47-69` (`dbrrg_wait_for_efi`)
- Test: `test/integration/test-initramfs-home.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `<state-dir>/boot-efi-dev`, a file holding one device node path
  such as `/dev/sda1`, written on every boot where the EFI partition was
  found. Task 2 reads it. Also
  `dbrrg_record_efi_dev <state-dir>` → writes that file, returns 0 always.

**Why:** A fresh install writes the whole image byte for byte, so after
`partprobe` two partitions carry `PARTLABEL=EFI-SYSTEM`, the same PARTUUID and
the same FAT label. `/dev/disk/by-partlabel/EFI-SYSTEM` then resolves to
whichever one udev saw last. `dbrrg-save-home:115-119` mounts exactly that
symlink, so a save after a fresh install can write the user's home onto the
wrong stick. Recording what the restore actually read means the save and the
restore cannot disagree, which is the same reason `boot-mac` and
`boot-home-base` exist.

- [ ] **Step 1: Write the failing test**

Append to `test/integration/test-initramfs-home.sh`, immediately before the
final `exit $fail`:

```bash
# --- dbrrg_wait_for_efi records the node it found ------------------------
#
# A fresh install leaves two partitions with PARTLABEL=EFI-SYSTEM, the same
# PARTUUID and the same FAT label, so by-partlabel resolves to whichever one
# udev saw last. The save must address the partition the restore read, not
# that symlink.

mkdir -p "$WORK/efidev/state"
: >"$WORK/efidev/sda1"

# The fast path: the device is already there, so the function returns before
# its loop. This return is easy to miss, and a boot that took it would record
# nothing.
( DBRRG_EFI_DEV="$WORK/efidev/sda1" \
  DBRRG_STATE="$WORK/efidev/state" \
  DBRRG_EFI_ABSENT_MARKER="$WORK/efidev/absent" \
  dbrrg_wait_for_efi 1 ) >/dev/null 2>&1
recorded=$(cat "$WORK/efidev/state/boot-efi-dev" 2>/dev/null || true)
if [[ "$recorded" == "$WORK/efidev/sda1" ]]; then
    ok "dbrrg_wait_for_efi records boot-efi-dev on the already-present path"
else
    bad "boot-efi-dev holds '$recorded', wanted '$WORK/efidev/sda1'"
fi

# The slow path: the device appears while the loop is waiting.
mkdir -p "$WORK/efidev2/state"
( DBRRG_EFI_DEV="$WORK/efidev2/sdb1" \
  DBRRG_STATE="$WORK/efidev2/state" \
  DBRRG_EFI_ABSENT_MARKER="$WORK/efidev2/absent" \
  sh -c 'sleep 2 && : >"'"$WORK"'/efidev2/sdb1"' &
  sleep 0.2
  DBRRG_EFI_DEV="$WORK/efidev2/sdb1" \
  DBRRG_STATE="$WORK/efidev2/state" \
  DBRRG_EFI_ABSENT_MARKER="$WORK/efidev2/absent" \
  dbrrg_wait_for_efi 10 ) >/dev/null 2>&1
recorded2=$(cat "$WORK/efidev2/state/boot-efi-dev" 2>/dev/null || true)
if [[ "$recorded2" == "$WORK/efidev2/sdb1" ]]; then
    ok "dbrrg_wait_for_efi records boot-efi-dev after waiting for the device"
else
    bad "boot-efi-dev after wait holds '$recorded2', wanted '$WORK/efidev2/sdb1'"
fi

# A timeout must record nothing rather than an empty file, so the save's
# "recorded nothing" fallback is reachable.
mkdir -p "$WORK/efidev3/state"
( DBRRG_EFI_DEV="$WORK/efidev3/never" \
  DBRRG_STATE="$WORK/efidev3/state" \
  DBRRG_EFI_ABSENT_MARKER="$WORK/efidev3/absent" \
  dbrrg_wait_for_efi 1 ) >/dev/null 2>&1
if [[ ! -e "$WORK/efidev3/state/boot-efi-dev" ]]; then
    ok "a timeout records no boot-efi-dev at all"
else
    bad "a timeout wrote boot-efi-dev '$(cat "$WORK/efidev3/state/boot-efi-dev")'"
fi

# An unwritable state directory must not abort the boot. restore_home cannot
# fail the boot and neither can this.
mkdir -p "$WORK/efidev4"
: >"$WORK/efidev4/sdc1"
if ( DBRRG_EFI_DEV="$WORK/efidev4/sdc1" \
     DBRRG_STATE="$WORK/efidev4/no-such-dir" \
     DBRRG_EFI_ABSENT_MARKER="$WORK/efidev4/absent" \
     dbrrg_wait_for_efi 1 ) >/dev/null 2>&1; then
    ok "an unwritable state dir still returns success"
else
    bad "an unwritable state dir made dbrrg_wait_for_efi fail"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-initramfs-home.sh`
Expected: FAIL on the first three new assertions. `boot-efi-dev` is never
written, so `recorded` is empty. The fourth may pass vacuously.

Note the test needs the three variables to be overridable, which they are not
yet — the first two assertions will fail with the real
`/dev/disk/by-partlabel/EFI-SYSTEM` path in the message, which is the
expected failure, not a broken test.

- [ ] **Step 3: Make the three paths overridable**

In `overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh`, replace:

```sh
readonly DBRRG_EFI_DEV="/dev/disk/by-partlabel/EFI-SYSTEM"
# Set once a wait has already exhausted its budget in this boot, so a later
# hook fails fast instead of repeating the whole timeout.
readonly DBRRG_EFI_ABSENT_MARKER="/run/dbrrg-efi-absent"
```

with:

```sh
# Overridable so test/integration/test-initramfs-home.sh can exercise the
# device wait and its recording without a block device or root. The defaults
# are the only values any real boot uses. `readonly` is deliberately not used:
# a readonly variable cannot be overridden from the environment even before
# the library is sourced, because `readonly X=default` assigns over a value
# that is merely set.
: "${DBRRG_EFI_DEV:=/dev/disk/by-partlabel/EFI-SYSTEM}"
# Set once a wait has already exhausted its budget in this boot, so a later
# hook fails fast instead of repeating the whole timeout.
: "${DBRRG_EFI_ABSENT_MARKER:=/run/dbrrg-efi-absent}"
```

And in the same block replace:

```sh
readonly DBRRG_STATE="$DBRRG_BASE/state"
```

with:

```sh
# Overridable for the same reason as DBRRG_EFI_DEV above.
: "${DBRRG_STATE:=$DBRRG_BASE/state}"
```

Leave `DBRRG_BASE`, `DBRRG_STORAGE` and `DBRRG_LAYERS` as they are. Only what
the test drives is unfrozen.

- [ ] **Step 4: Add the recorder and call it from both successful returns**

Insert this function directly above `dbrrg_wait_for_efi`:

```sh
# dbrrg_record_efi_dev <state-dir>
#
# Record the device node DBRRG_EFI_DEV currently resolves to, so
# dbrrg-save-home mounts the partition this boot actually read instead of
# resolving /dev/disk/by-partlabel/EFI-SYSTEM again at logout.
#
# A fresh install writes the whole image byte for byte, so after partprobe two
# partitions carry PARTLABEL=EFI-SYSTEM, the same PARTUUID and the same FAT
# label, and that symlink resolves to whichever one udev saw last. A save that
# re-resolves it can write the user's home onto the wrong stick.
#
# Never fails. A boot cannot be aborted over a missing breadcrumb, and the
# save keeps the symlink as its fallback for a boot that recorded nothing -
# which is why a failure here must leave NO file rather than an empty one.
dbrrg_record_efi_dev() {
    _dred_state="$1"
    _dred_node=$(readlink -f "$DBRRG_EFI_DEV" 2>/dev/null || true)
    [ -z "$_dred_node" ] && _dred_node="$DBRRG_EFI_DEV"

    if ! echo "$_dred_node" > "$_dred_state/boot-efi-dev" 2>/dev/null; then
        warn "dbrrg: could not write $_dred_state/boot-efi-dev"
        rm -f "$_dred_state/boot-efi-dev" 2>/dev/null || true
    fi
    return 0
}
```

Then in `dbrrg_wait_for_efi`, change the early return:

```sh
    [ -b "$DBRRG_EFI_DEV" ] && return 0
```

to:

```sh
    if [ -b "$DBRRG_EFI_DEV" ]; then
        dbrrg_record_efi_dev "$DBRRG_STATE"
        return 0
    fi
```

and change the post-loop return:

```sh
    [ "$_dwfe_waited" -gt 0 ] && dbrrg_log "EFI-SYSTEM appeared after ${_dwfe_waited}s"
    return 0
```

to:

```sh
    [ "$_dwfe_waited" -gt 0 ] && dbrrg_log "EFI-SYSTEM appeared after ${_dwfe_waited}s"
    dbrrg_record_efi_dev "$DBRRG_STATE"
    return 0
```

Both returns need it. The early one is taken on every boot where the stick was
already enumerated, which on QEMU is every boot, so missing it would record
nothing exactly where the tests run.

- [ ] **Step 5: Run the test to verify it passes**

Run: `test/integration/test-initramfs-home.sh`
Expected: PASS, including the pre-existing assertions. The test uses regular
files rather than block devices, so note that `[ -b ]` is false for them — if
the two new positive assertions still fail, the function is being driven
through its loop and timing out, not through `[ -b ]`. Change the probe in
`dbrrg_wait_for_efi` only if the test is wrong, never to make a real boot
accept a non-block device.

- [ ] **Step 6: Run the full offline suite**

Run: `test/integration/test-initramfs-home.sh && test/integration/test-save-home.sh && test/integration/test-labwc-config-merge.sh && test/integration/test-password.sh`
Expected: all PASS. These four need no image. Unfreezing `DBRRG_STATE` is the
change most likely to disturb a neighbour.

- [ ] **Step 7: Commit**

```bash
git add overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh \
        test/integration/test-initramfs-home.sh
git commit -m "fix: record the EFI partition the boot actually read

A fresh install writes the image byte for byte, so after partprobe two
partitions carry PARTLABEL=EFI-SYSTEM, the same PARTUUID and the same
FAT label. /dev/disk/by-partlabel/EFI-SYSTEM then resolves to whichever
one udev saw last, and dbrrg-save-home mounts exactly that symlink - so
a save after a fresh install could write the user's home onto the wrong
stick with nothing printed.

dbrrg_wait_for_efi now records the node it found as
<state-dir>/boot-efi-dev, on both of its successful returns. The early
return taken when the stick is already enumerated is the one every QEMU
boot takes, so recording on only the post-loop return would have left
the tests covering a path no test machine reaches.

A write failure leaves no file rather than an empty one, because the
save's fallback to the symlink keys on the file's absence.

DBRRG_EFI_DEV, DBRRG_EFI_ABSENT_MARKER and DBRRG_STATE lose their
readonly so the test can drive the wait without a block device or root.
readonly is not a usable guard here in any case: readonly X=default
assigns over a value that is merely set, so it never protected these
from the environment.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Mount the recorded node in dbrrg-save-home

**Files:**
- Modify: `overlay/usr/bin/dbrrg-save-home:115-119` (the USB branch)
- Test: `test/integration/test-save-home.sh`

**Interfaces:**
- Consumes: `<state-dir>/boot-efi-dev` from Task 1.
- Produces: nothing new. The USB branch mounts the recorded node when the file
  exists and is a block device, and `/dev/disk/by-partlabel/EFI-SYSTEM`
  otherwise.

- [ ] **Step 1: Write the failing test**

In `test/integration/test-save-home.sh`, the USB branch currently cannot run
unprivileged because it guards on `[ -b /dev/disk/by-partlabel/EFI-SYSTEM ]`.
Add a `mount` stub and a seam for the symlink. First extend the stub block,
after the existing `sudo` stub:

```bash
# mount and umount are reached through the sudo stub, which swallows them.
# These exist for the day the script stops using sudo for them.
cat >"$STUBS/mount" <<'STUB'
#!/bin/bash
echo "mount $*" >>"$DBRRG_TEST_MOUNT_LOG"
exit 0
STUB

cat >"$STUBS/umount" <<'STUB'
#!/bin/bash
echo "umount $*" >>"$DBRRG_TEST_MOUNT_LOG"
exit 0
STUB

cat >"$STUBS/dd" <<'STUB'
#!/bin/bash
echo "dd $*" >>"$DBRRG_TEST_MOUNT_LOG"
cat >/dev/null
exit 0
STUB
```

Extend `run_save_home` to pass the new log and the new seam:

```bash
run_save_home() {
    # $1 = value for HOME, $2 = value for DBRRG_HOME_DIR
    DBRRG_TEST_TAR_LOG="$WORK/tar.log" \
    DBRRG_TEST_CURL_LOG="$WORK/curl.log" \
    DBRRG_TEST_SUDO_LOG="$WORK/sudo.log" \
    DBRRG_TEST_MOUNT_LOG="$WORK/mount.log" \
    HOME="$1" \
    DBRRG_HOME_DIR="$2" \
    DBRRG_STATE_DIR="$WORK/state" \
    DBRRG_CMDLINE="$WORK/cmdline" \
    DBRRG_EFI_DEV="${DBRRG_EFI_DEV_OVERRIDE:-/dev/disk/by-partlabel/EFI-SYSTEM}" \
    PATH="$STUBS:$PATH" \
        "$SCRIPT" </dev/null >"$WORK/out" 2>"$WORK/err"
    echo $?
}
```

Add `"$WORK/mount.log"` to the `rm -rf` list in `setup`. Then append these
assertions before the final `exit $fail`:

```bash
# ---------------------------------------------------------------- test 4
# The save must mount the partition the restore read, not re-resolve
# by-partlabel: after a fresh install two partitions carry that label and the
# symlink points at whichever one udev saw last.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/dev"
: >"$WORK/dev/recorded"
: >"$WORK/dev/symlink"
echo "$WORK/dev/recorded" >"$WORK/state/boot-efi-dev"
rc=$(DBRRG_EFI_DEV_OVERRIDE="$WORK/dev/symlink" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if grep -q "mount $WORK/dev/recorded" "$WORK/sudo.log" 2>/dev/null; then
    ok "mounts the node recorded by the initramfs, not the by-partlabel symlink"
else
    bad "did not mount the recorded node (exit $rc, sudo log: $(cat "$WORK/sudo.log" 2>/dev/null))"
fi

# ---------------------------------------------------------------- test 5
# A boot that recorded nothing - an initramfs predating Task 1 - must still
# save. Falling back to the symlink is the old behaviour and keeps those
# machines working.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/dev"
: >"$WORK/dev/symlink"
rc=$(DBRRG_EFI_DEV_OVERRIDE="$WORK/dev/symlink" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if grep -q "mount $WORK/dev/symlink" "$WORK/sudo.log" 2>/dev/null; then
    ok "falls back to the by-partlabel symlink when nothing was recorded"
else
    bad "no fallback mount (exit $rc, sudo log: $(cat "$WORK/sudo.log" 2>/dev/null))"
fi

# ---------------------------------------------------------------- test 6
# A recorded node that has since gone away - the stick was swapped - must not
# be mounted. Fall back rather than mounting a path that is not a device.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/dev"
: >"$WORK/dev/symlink"
echo "$WORK/dev/vanished" >"$WORK/state/boot-efi-dev"
rc=$(DBRRG_EFI_DEV_OVERRIDE="$WORK/dev/symlink" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if grep -q "mount $WORK/dev/symlink" "$WORK/sudo.log" 2>/dev/null &&
   ! grep -q "vanished" "$WORK/sudo.log" 2>/dev/null; then
    ok "ignores a recorded node that no longer exists"
else
    bad "mounted a vanished node (exit $rc, sudo log: $(cat "$WORK/sudo.log" 2>/dev/null))"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-save-home.sh`
Expected: FAIL on tests 4, 5 and 6. The script has no `DBRRG_EFI_DEV` seam and
guards the USB branch on a real block device, so it takes the final `else`
branch and logs no mount at all.

- [ ] **Step 3: Rewrite the USB branch**

In `overlay/usr/bin/dbrrg-save-home`, add this below the existing
`DBRRG_CMDLINE` line near the top:

```sh
# Overridable so test/integration/test-save-home.sh can drive the USB branch
# without a block device or root.
DBRRG_EFI_DEV="${DBRRG_EFI_DEV:-/dev/disk/by-partlabel/EFI-SYSTEM}"
```

Then add, next to the other state reads (below the `MAC_ADDR` block):

```sh
# Prefer the EFI device node the initramfs actually read.
#
# A fresh install writes the whole image byte for byte, so after partprobe two
# partitions carry PARTLABEL=EFI-SYSTEM, the same PARTUUID and the same FAT
# label, and /dev/disk/by-partlabel/EFI-SYSTEM resolves to whichever one udev
# saw last. Mounting that symlink can write this machine's home onto the stick
# it was just installed onto, or onto the one it booted from, depending only on
# enumeration order.
#
# dbrrg_wait_for_efi records what it resolved to, so the save addresses the
# partition the restore read and the two cannot disagree. The symlink stays as
# the fallback for a boot by an initramfs that predates the recording, and the
# `|| true` is load-bearing for the reason given above boot-home-base.
EFI_DEV=$(cat "$DBRRG_STATE_DIR/boot-efi-dev" 2>/dev/null || true)
if [ -z "$EFI_DEV" ] || [ ! -e "$EFI_DEV" ]; then
  EFI_DEV="$DBRRG_EFI_DEV"
fi
```

Then replace the USB branch:

```sh
elif [ -b /dev/disk/by-partlabel/EFI-SYSTEM ]; then
  sudo mkdir -p /boot/efi
  sudo mount /dev/disk/by-partlabel/EFI-SYSTEM /boot/efi
  tar zcf - . | sudo dd of=/boot/efi/home.tar.gz
  sudo umount /boot/efi
```

with:

```sh
elif [ -e "$EFI_DEV" ]; then
  sudo mkdir -p /boot/efi
  sudo mount "$EFI_DEV" /boot/efi
  tar zcf - . | sudo dd of=/boot/efi/home.tar.gz
  sudo umount /boot/efi
```

The guard loosens from `-b` to `-e` only because the test drives regular
files; on a real machine `$EFI_DEV` is always a block device. The alternative,
a second seam for the test of the guard itself, buys nothing and adds a branch
no boot takes.

- [ ] **Step 4: Run the test to verify it passes**

Run: `test/integration/test-save-home.sh`
Expected: PASS, all six assertions including the three pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add overlay/usr/bin/dbrrg-save-home test/integration/test-save-home.sh
git commit -m "fix: save the home to the stick the boot read, not to a label

dbrrg-save-home mounted /dev/disk/by-partlabel/EFI-SYSTEM. After a fresh
install two partitions carry that PARTLABEL, the same PARTUUID and the
same FAT label, so the symlink resolves to whichever one udev enumerated
last - and a save could write the user's home onto the wrong stick with
nothing printed either way.

It now mounts the node dbrrg_wait_for_efi recorded, so the save
addresses the partition the restore read. The symlink stays as the
fallback for a boot by an older initramfs that recorded nothing, and a
recorded node that has since disappeared falls back too rather than
being mounted.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: One exit code per outcome in dbrrg-save-home

**Files:**
- Modify: `overlay/usr/bin/dbrrg-save-home` — the three refusal branches and
  the trailing `echo`
- Test: `test/integration/test-save-home.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the exit-code table in Global Constraints. The menu plan switches
  on these; they are the public interface of this script from now on.

**Why:** Today the restore-failed refusal, the unreachable-server refusal and
the "no idea how to store your home" branch all `exit 0`, and the last one
still prints `home saved`. Nothing can tell success from refusal without
scraping stderr for sentences.

- [ ] **Step 1: Write the failing test**

Append to `test/integration/test-save-home.sh` before the final `exit $fail`:

```bash
# ---------------------------------------------------------------- test 7
# Every refusal needs its own exit code. The menu switches on these to tell
# the user what happened; with everything at 0 it can only say "saved".
setup
echo failed >"$WORK/state/home-restore"
rc=$(run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "2" ]] && [[ ! -s "$WORK/tar.log" ]]; then
    ok "exit 2 when this boot's home restore failed"
else
    bad "restore-failed refusal exited $rc (wanted 2), tar log $(wc -c <"$WORK/tar.log") bytes"
fi

# ---------------------------------------------------------------- test 8
setup
cat >"$STUBS/ping" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$STUBS/ping"
rc=$(run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "3" ]] && [[ ! -s "$WORK/curl.log" ]]; then
    ok "exit 3 when the boot server is unreachable"
else
    bad "unreachable-server refusal exited $rc (wanted 3)"
fi
# restore the passing ping for the tests below
cat >"$STUBS/ping" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$STUBS/ping"

# ---------------------------------------------------------------- test 9
# No boot server in the cmdline and no EFI device: this machine has nowhere to
# put a home. It used to print "home saved" and exit 0 on this path.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
rc=$(DBRRG_EFI_DEV_OVERRIDE="$WORK/dev/absent" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "4" ]] && ! grep -q "home saved" "$WORK/out"; then
    ok "exit 4 with no 'home saved' when there is nowhere to store the home"
else
    bad "no-target branch exited $rc (wanted 4), stdout: $(cat "$WORK/out")"
fi

# ---------------------------------------------------------------- test 10
# An attempted save that breaks must not collide with the missing-home
# refusal, which is exit 1. The menu would otherwise tell the user their home
# directory does not exist when the upload merely failed.
setup
cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >>"$DBRRG_TEST_CURL_LOG"
exit 7
STUB
chmod +x "$STUBS/curl"
rc=$(run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "5" ]]; then
    ok "exit 5 when the upload was attempted and failed"
else
    bad "failed upload exited $rc (wanted 5)"
fi
cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >>"$DBRRG_TEST_CURL_LOG"
exit 0
STUB
chmod +x "$STUBS/curl"

# ---------------------------------------------------------------- test 11
setup
rc=$(run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "0" ]] && grep -q "home saved" "$WORK/out"; then
    ok "exit 0 and 'home saved' on a successful netboot save"
else
    bad "successful save exited $rc, stdout: $(cat "$WORK/out")"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-save-home.sh`
Expected: FAIL on tests 7, 8, 9 and 10. Test 7 and 8 exit 0; test 9 exits 0 and
prints `home saved`; test 10 exits 1 from `set -e`, which is the collision the
new code 5 removes. Test 11 passes already.

- [ ] **Step 3: Give each outcome its own exit code**

In `overlay/usr/bin/dbrrg-save-home`, add this below the `DBRRG_EFI_DEV` line
from Task 2:

```sh
# Exit codes, read by dbrrg-menu to tell the user what happened:
#
#   0  home saved
#   1  the resolved home directory is missing or is not a directory
#   2  this boot's home restore failed, so saving would destroy the good copy
#   3  the boot server is unreachable
#   4  this machine has no known place to store a home
#   5  the save was attempted and failed
#
# Everything except 1 used to be 0, and branch 4 printed "home saved" while
# storing nothing. A caller could not tell success from refusal without
# scraping stderr for sentences.
```

Change the restore-failed branch's `exit 0` to `exit 2`:

```sh
if [ "$DBRRG_RESTORE_STATE" = "failed" ]; then
  echo "dbrrg: home restore FAILED this boot - refusing to save, so the" >&2
  echo "       stored home and SSH host keys are not overwritten with a" >&2
  echo "       default one. Investigate before logging out again." >&2
  exit 2
fi
```

Change the unreachable-server branch's `exit 0` to `exit 3`:

```sh
  if [ "$_dsh_reachable" -ne 1 ]; then
    echo "dbrrg: boot server $BOOT_SRV unreachable after ${_dsh_waited}s -" >&2
    echo "       refusing to save. An upload that cannot reach its target" >&2
    echo "       cannot work; retry once the network is back." >&2
    exit 3
  fi
```

Replace the netboot upload so a failure is reported as 5 rather than 1, and so
the temporary archive is removed either way:

```sh
  if ! tar zcf /tmp/$$.tar.gz .; then
    rm -f /tmp/$$.tar.gz
    echo "dbrrg: could not archive $DBRRG_HOME_DIR - nothing was uploaded." >&2
    exit 5
  fi
  if ! curl -F data=@/tmp/$$.tar.gz ${BASE_PATH}/home.pkg?mac=${MAC_ADDR}; then
    rm -f /tmp/$$.tar.gz
    echo "dbrrg: upload to ${BASE_PATH} failed - your home was NOT saved." >&2
    exit 5
  fi
  rm -f /tmp/$$.tar.gz
```

Replace the USB branch's body so a failed mount, archive or unmount is also 5:

```sh
elif [ -e "$EFI_DEV" ]; then
  sudo mkdir -p /boot/efi
  if ! sudo mount "$EFI_DEV" /boot/efi; then
    echo "dbrrg: could not mount $EFI_DEV - your home was NOT saved." >&2
    exit 5
  fi
  if ! tar zcf - . | sudo dd of=/boot/efi/home.tar.gz; then
    sudo umount /boot/efi || true
    echo "dbrrg: could not write home.tar.gz - your home was NOT saved." >&2
    exit 5
  fi
  if ! sudo umount /boot/efi; then
    echo "dbrrg: could not unmount /boot/efi - the archive may be incomplete." >&2
    exit 5
  fi
```

Replace the final branch and the trailing echo:

```sh
else
  echo "dbrrg: this machine has no boot server and no EFI partition, so" >&2
  echo "       there is nowhere to store your home directory. Nothing was" >&2
  echo "       saved." >&2
  exit 4
fi
echo "home saved"
```

Note the `tar | dd` pipeline: `if ! tar zcf - . | sudo dd ...` tests `dd`'s
status, not `tar`'s, because `/bin/sh` has no `pipefail`. A `tar` that fails
mid-stream gives `dd` a short input and `dd` still succeeds. That is a real
hole and the reason the netboot path archives to a file first; the USB path
cannot without a writable temp of unknown size. It is accepted here and
recorded in the task's commit message rather than papered over.

- [ ] **Step 4: Run the test to verify it passes**

Run: `test/integration/test-save-home.sh`
Expected: PASS, all eleven assertions.

- [ ] **Step 5: Check no caller treated a refusal as success**

Run: `grep -rn 'dbrrg-save-home' --include='*' overlay/ scripts/ containers/ Makefile`
Expected: the callers are `overlay/usr/bin/dbrrg-session`,
`overlay/usr/bin/upgrade-image:649-652` and the ThinLinc session hook. Read
each one. Any that branches on the exit status needs its branches checked
against the new table; `upgrade-image` is fixed in Task 4. If a caller ignores
the status entirely, leave it — a non-zero exit from a script that used to
always return 0 cannot break a caller that never looked.

- [ ] **Step 6: Commit**

```bash
git add overlay/usr/bin/dbrrg-save-home test/integration/test-save-home.sh
git commit -m "fix: stop reporting a refused home save as a successful one

Three branches refused to save and exited 0. The last of them printed
\"home saved\" while storing nothing at all, so a machine with no boot
server and no EFI partition told the user their home was safe on every
logout.

Each outcome now has its own exit code: 2 for a boot whose home restore
failed, 3 for an unreachable boot server, 4 for a machine with nowhere
to store a home, 5 for a save that was attempted and failed, 0 only when
an archive was actually written. 1 keeps its existing meaning, a missing
home directory.

Code 5 matters on its own: a failed curl previously ended the script
through set -e with status 1, which is the code for \"your home
directory does not exist\". Anything switching on the status would have
reported the wrong cause.

Known hole, not introduced here: the USB path pipes tar into dd, and
/bin/sh has no pipefail, so a tar that fails mid-stream leaves dd
succeeding on a short input. The netboot path archives to a file first
and does not have this. Fixing the USB path needs a writable temp of
unknown size on a RAM-backed root.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Stop upgrade-image killing and swallowing the existing save

**Files:**
- Modify: `overlay/usr/bin/upgrade-image:648-652`
- Test: `test/unit/test_upgrade_image.py` (new file)
- Modify: `Makefile` — add `test-unit`

**Interfaces:**
- Consumes: the exit-code table from Task 3.
- Produces: `save_home_before_finish() -> int` — runs `dbrrg-save-home`,
  prints what happened, returns its exit status, or `-1` if it could not be
  run at all. Task 5 does not use it; it exists so the call site is testable.
- Produces: `make test-unit`, a host-side target with no image dependency.
  Task 5 extends the same test file, and the menu plan extends the same target
  with `cargo test`.

**Why:** The call is `subprocess.run(["dbrrg-save-home"], capture_output=True,
timeout=60)` inside `try: ... except Exception: pass`. `dbrrg-save-home` waits
up to 60 seconds for the boot server to answer *before* it starts the tar and
the upload, so on a netbooted machine the 60-second timeout kills the child
mid-upload, and the bare `except` discards both the timeout and any error.

- [ ] **Step 1: Write the failing test**

Create `test/unit/test_upgrade_image.py`:

```python
#!/usr/bin/env python3
"""Offline tests for upgrade-image.

upgrade-image has no .py extension and is executed, not imported, so these
tests load it through importlib. It guards its entry point with
`if __name__ == "__main__"`, so importing it runs no UI.

Everything here runs unprivileged. mount, umount and dbrrg-save-home are
replaced with fakes; tar is real, because archiving a temporary directory
needs no privileges and the archive's contents are the assertion.
"""

import importlib.util
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "overlay" / "usr" / "bin" / "upgrade-image"


def load_upgrade_image():
    spec = importlib.util.spec_from_loader(
        "upgrade_image",
        importlib.machinery.SourceFileLoader("upgrade_image", str(SCRIPT)),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ui = load_upgrade_image()


class TestSaveHomeBeforeFinish(unittest.TestCase):
    """The save before a reboot must not be killed or silently discarded."""

    def test_timeout_exceeds_the_scripts_own_ping_bound(self):
        # dbrrg-save-home pings the boot server for up to 60s BEFORE it starts
        # the tar and the upload. A 60s timeout here killed it mid-upload.
        with mock.patch.object(ui.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, b"", b"")
            ui.save_home_before_finish()
        timeout = run.call_args.kwargs["timeout"]
        self.assertGreater(
            timeout, 60,
            "timeout must exceed dbrrg-save-home's own 60s ping bound",
        )

    def test_a_refusal_is_reported_not_swallowed(self):
        with mock.patch.object(ui.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                [], 3, b"", b"boot server unreachable\n"
            )
            rc = ui.save_home_before_finish()
        self.assertEqual(rc, 3)

    def test_a_timeout_is_reported_not_swallowed(self):
        with mock.patch.object(ui.subprocess, "run") as run:
            run.side_effect = subprocess.TimeoutExpired(["dbrrg-save-home"], 600)
            rc = ui.save_home_before_finish()
        self.assertNotEqual(rc, 0)

    def test_a_missing_script_is_reported_not_swallowed(self):
        with mock.patch.object(ui.subprocess, "run") as run:
            run.side_effect = FileNotFoundError()
            rc = ui.save_home_before_finish()
        self.assertEqual(rc, -1)

    def test_success_returns_zero(self):
        with mock.patch.object(ui.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, b"", b"")
            rc = ui.save_home_before_finish()
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 -m unittest discover -s test/unit -v`
Expected: FAIL. Every test errors with `AttributeError: module 'upgrade_image'
has no attribute 'save_home_before_finish'`.

If instead the import itself fails, `upgrade-image` is running code at import
time that it should not; read the traceback before changing the test.

- [ ] **Step 3: Write the function and use it at the call site**

In `overlay/usr/bin/upgrade-image`, add this above `def main()`:

```python
# dbrrg-save-home's own bound on waiting for the boot server is 60 seconds,
# and the tar and upload come after it. A 60 second timeout here therefore
# killed the child while it was uploading, and the bare `except Exception:
# pass` around it discarded both the timeout and any failure, so a user whose
# home was not saved was told the operation completed successfully.
SAVE_HOME_TIMEOUT = 600

# Exit codes from dbrrg-save-home. See the table at the top of that script.
SAVE_HOME_MESSAGES = {
    0: None,  # saved; nothing to say
    1: "the home directory could not be found",
    2: "this boot's home restore had failed, so saving was refused",
    3: "the boot server could not be reached",
    4: "this machine has nowhere to store a home directory",
    5: "the save was attempted and failed",
}


def save_home_before_finish() -> int:
    """Save the home directory before the user reboots.

    Returns dbrrg-save-home's exit status, or -1 if it could not be run.
    Never raises: a failed save must not lose the install that just
    succeeded, but it must not be hidden either.
    """
    try:
        result = subprocess.run(
            ["dbrrg-save-home"],
            capture_output=True,
            timeout=SAVE_HOME_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        log(f"WARNING: saving the home directory timed out after "
            f"{SAVE_HOME_TIMEOUT}s - it may be incomplete")
        return -1
    except (FileNotFoundError, OSError) as e:
        log(f"WARNING: could not run dbrrg-save-home: {e}")
        return -1

    if result.returncode == 0:
        return 0

    reason = SAVE_HOME_MESSAGES.get(
        result.returncode, f"it exited {result.returncode}"
    )
    log(f"WARNING: your home directory was NOT saved - {reason}")
    stderr = result.stderr.decode("utf-8", "replace").strip()
    if stderr:
        for line in stderr.splitlines():
            print(f"    {line}", file=sys.stderr)
    return result.returncode
```

Then replace the call site:

```python
        # Try to save home before potential reboot
        try:
            subprocess.run(["dbrrg-save-home"], capture_output=True, timeout=60)
        except Exception:
            pass
```

with:

```python
        # Save home before a potential reboot. A failure here is reported and
        # does not fail the install, which has already succeeded.
        save_home_before_finish()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 -m unittest discover -s test/unit -v`
Expected: PASS, 5 tests.

- [ ] **Step 5: Add the make target**

In `Makefile`, add `test-unit` to the `.PHONY` line on line 67, then add this
above the existing `test:` target:

```makefile
# Host-side tests. No image, no container, no network: these run in under a
# second and are the fast feedback loop for the scripts in overlay/usr/bin.
# Deliberately not dependent on 'rootfs'.
test-unit:
	@python3 -m unittest discover -s test/unit -t . -v
```

and make the image suite run it first, so a broken script fails before a
multi-minute image build:

```makefile
test: test-unit rootfs
	@test/integration/test-firmware.sh
```

- [ ] **Step 6: Verify the target works**

Run: `make test-unit`
Expected: PASS, 5 tests, and no container build.

- [ ] **Step 7: Commit**

```bash
git add overlay/usr/bin/upgrade-image test/unit/test_upgrade_image.py Makefile
git commit -m "fix: report a failed home save instead of hiding it

upgrade-image saved the home directory before a reboot with a 60 second
timeout, wrapped in a bare except that discarded everything. On a
netbooted machine dbrrg-save-home spends up to 60 seconds pinging the
boot server before it starts the tar and the upload, so the timeout
killed the child mid-upload - and the except meant the user then read
\"Operation completed successfully\" on a machine whose home had not
been saved.

The timeout rises to 600s, above that ping bound plus the archive and
the upload, and every outcome is now printed: a timeout, a missing
script, and each of dbrrg-save-home's refusal codes by name, with the
script's own stderr underneath. A failure still does not fail the
install, which has already succeeded by that point.

Adds make test-unit, a host-side suite that needs no image, and runs it
ahead of the image suites so a broken script fails in a second rather
than after a rootfs build.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Copy the home directory onto a freshly installed drive

**Files:**
- Modify: `overlay/usr/bin/upgrade-image` — `do_fresh_install()` at `:477`,
  plus two new functions and one new import
- Test: `test/unit/test_upgrade_image.py`

**Interfaces:**
- Consumes: `find_efi_partition(device) -> Optional[str]`, `run_cmd`, `log`,
  `confirm`, `_register_cleanup` / `_unregister_cleanup`, all existing.
- Produces:
  - `home_archive_argv(home_dir: str, dest: str) -> List[str]` — the `tar`
    command line. Pure; no filesystem access.
  - `copy_home_to_drive(device: str) -> bool` — mounts the device's EFI
    partition, writes `home.tar.gz`, unmounts. Returns True on success. Never
    raises.
  - `TLUSER = "tluser"` and `HOME_ARCHIVE_NAME = "home.tar.gz"` constants.

**Why:** A user who installs a new stick loses their WiFi credentials,
ThinLinc settings and customisations, although the running machine has all of
them. `restore_home()` reads `home.tar.gz` from the EFI partition on every USB
boot, so writing that one file makes the new stick come up configured.

The question is asked in `do_fresh_install()` only. The A/B upgrade path
writes to a drive that already carries that machine's home.

- [ ] **Step 1: Write the failing test for the archive builder**

Append to `test/unit/test_upgrade_image.py`, above the `if __name__` block:

```python
class TestHomeArchiveArgv(unittest.TestCase):
    """The tar command line that writes a new stick's home.tar.gz."""

    def test_excludes_the_ssh_host_keys(self):
        argv = ui.home_archive_argv("/home/tluser", "/mnt/home.tar.gz")
        self.assertIn("--exclude=./.dbrrg-ssh-host-keys", argv)

    def test_archives_relative_to_the_home_directory(self):
        # restore_home() unpacks into the home directory itself, so members
        # must be relative: the archive is built with -C <home> and a bare ".".
        argv = ui.home_archive_argv("/home/tluser", "/mnt/home.tar.gz")
        self.assertIn("-C", argv)
        self.assertEqual(argv[argv.index("-C") + 1], "/home/tluser")
        self.assertEqual(argv[-1], ".")

    def test_writes_to_the_given_destination(self):
        argv = ui.home_archive_argv("/home/tluser", "/mnt/home.tar.gz")
        self.assertIn("/mnt/home.tar.gz", argv)


class TestHomeArchiveContents(unittest.TestCase):
    """Run the real tar and look inside the result."""

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.home = Path(self.work.name) / "home"
        (self.home / ".dbrrg-ssh-host-keys").mkdir(parents=True)
        (self.home / ".dbrrg-ssh-host-keys" / "ssh_host_ed25519_key").write_text(
            "PRIVATE KEY"
        )
        (self.home / ".dbrrg-sessionrc").write_text("wlr-randr --output DP-1\n")
        (self.home / ".config" / "dbrrg" / "menu").mkdir(parents=True)
        (self.home / ".config" / "dbrrg" / "menu" / "15-mine.desktop").write_text(
            "[Desktop Entry]\nName=Mine\n"
        )
        self.dest = Path(self.work.name) / "home.tar.gz"

    def tearDown(self):
        self.work.cleanup()

    def _members(self):
        with tarfile.open(self.dest, "r:gz") as tf:
            return tf.getnames()

    def test_the_ssh_identity_is_not_in_the_archive(self):
        # Copying it gives two machines the same SSH host key. The new stick
        # must generate its own on first boot.
        subprocess.run(
            ui.home_archive_argv(str(self.home), str(self.dest)), check=True
        )
        joined = "\n".join(self._members())
        self.assertNotIn(".dbrrg-ssh-host-keys", joined)

    def test_the_users_own_settings_are_in_the_archive(self):
        subprocess.run(
            ui.home_archive_argv(str(self.home), str(self.dest)), check=True
        )
        members = self._members()
        self.assertIn("./.dbrrg-sessionrc", members)
        self.assertIn("./.config/dbrrg/menu/15-mine.desktop", members)


class TestCopyHomeToDrive(unittest.TestCase):
    """The wrapper that mounts, archives and unmounts.

    Every test patches time.sleep. copy_home_to_drive retries the EFI lookup
    for EFI_RETRY_SECONDS, so a test that leaves the real sleep in place takes
    that many seconds to assert one boolean.
    """

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.home = Path(self.work.name) / "home"
        self.home.mkdir()
        (self.home / ".dbrrg-sessionrc").write_text("x\n")

        sleep = mock.patch.object(ui.time, "sleep")
        self.sleep = sleep.start()
        self.addCleanup(sleep.stop)

    def _as_tluser(self):
        """Make getpwnam("tluser") resolve to this test's temp home."""
        return mock.patch.object(
            ui.pwd, "getpwnam", return_value=mock.Mock(pw_dir=str(self.home))
        )

    def test_a_missing_tluser_account_is_reported_not_crashed(self):
        # On an image where the account was renamed, getpwnam raises KeyError.
        # A traceback AFTER the image is written reads as a failed install.
        with mock.patch.object(ui.pwd, "getpwnam", side_effect=KeyError("tluser")):
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        run_cmd.assert_not_called()

    def test_no_efi_partition_retries_then_reports(self):
        with self._as_tluser():
            with mock.patch.object(
                ui, "find_efi_partition", return_value=None
            ) as find:
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        # udev may not have re-read the new partition table yet, right after
        # partprobe on a drive written byte for byte. One look is not enough.
        self.assertGreater(ui.EFI_RETRY_SECONDS, 0)
        self.assertEqual(self.sleep.call_count, ui.EFI_RETRY_SECONDS)
        self.assertEqual(find.call_count, ui.EFI_RETRY_SECONDS + 1)
        run_cmd.assert_not_called()

    def test_an_efi_partition_appearing_late_is_used(self):
        # Returns None twice, then the device: the retry must take it.
        results = [None, None, "/dev/sdb1"]

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition",
                                   side_effect=results):
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))
        self.assertIn(
            "mount", [c.args[0][0] for c in run_cmd.call_args_list]
        )

    def test_a_failed_archive_removes_the_partial_file(self):
        # A truncated home.tar.gz on the new stick is worse than none: the
        # next boot's restore may accept it and replace a good home. The fake
        # tar writes a partial file and then fails, the way a real tar does
        # when the partition fills up, so the real os.unlink is exercised.
        # The check has to happen AT unmount time, not after the call
        # returns: copy_home_to_drive rmtree's its temporary mount point on
        # the way out, so a check afterwards finds the file gone whether the
        # code removed it or not, and passes vacuously.
        calls = []
        dest_seen = []
        existed_at_umount = []

        def fake_run_cmd(cmd, **kwargs):
            calls.append(cmd[0])
            if cmd[0] == "tar":
                dest = cmd[cmd.index("-czf") + 1]
                dest_seen.append(dest)
                Path(dest).write_text("truncated archive")
                raise subprocess.CalledProcessError(2, cmd)
            if cmd[0] == "umount" and dest_seen:
                existed_at_umount.append(os.path.exists(dest_seen[0]))
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))

        self.assertTrue(dest_seen, "tar was never called")
        self.assertIn("umount", calls, "a failed archive must still unmount")
        self.assertEqual(
            existed_at_umount, [False],
            "the truncated archive was still on the drive when it was unmounted",
        )

    def test_tar_exit_1_keeps_the_archive(self):
        # GNU tar exits 1 for "file changed as we read it" - a socket or a
        # file being written - while producing a usable archive. Exit 2 is a
        # real error. Treating 1 as failure throws away a good copy.
        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "tar":
                raise subprocess.CalledProcessError(1, cmd)
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))

    def test_a_failed_umount_is_a_failed_copy(self):
        # The archive is still in the page cache. Reporting success here means
        # the user pulls the stick out with an empty file on it.
        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "umount":
                raise subprocess.CalledProcessError(32, cmd)
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))

    def test_a_home_that_is_not_a_directory_is_refused(self):
        missing = str(Path(self.work.name) / "no-such-home")
        with mock.patch.object(
            ui.pwd, "getpwnam", return_value=mock.Mock(pw_dir=missing)
        ):
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        run_cmd.assert_not_called()

    def test_the_happy_path_mounts_archives_syncs_and_unmounts_in_order(self):
        calls = []

        def fake_run_cmd(cmd, **kwargs):
            calls.append(cmd[0])
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))
        self.assertEqual(
            [c for c in calls if c in ("mount", "tar", "sync", "umount")],
            ["mount", "tar", "sync", "umount"],
        )
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test-unit`
Expected: FAIL. `AttributeError` for `home_archive_argv`, `copy_home_to_drive`,
`EFI_RETRY_SECONDS` and `ui.pwd`.

- [ ] **Step 3: Write the two functions**

In `overlay/usr/bin/upgrade-image`, add `pwd` and `time` to the imports,
keeping them alphabetical. Both are standard library:

```python
import atexit
import glob
import os
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
```

Add to the constants block:

```python
TLUSER = "tluser"
HOME_ARCHIVE_NAME = "home.tar.gz"
# The machine's SSH identity, staged into the home directory at every clean
# logout. It must NOT travel to another machine: two machines with the same
# host key is a real problem, and a stick that carries none simply generates
# its own on first boot.
SSH_KEYSTORE_NAME = ".dbrrg-ssh-host-keys"
# udev may not have re-read the partition table yet, right after partprobe on
# a drive that was just written byte for byte.
EFI_RETRY_SECONDS = 15
```

Add these functions above `def do_fresh_install`:

```python
def home_archive_argv(home_dir: str, dest: str) -> List[str]:
    """Build the tar command line for a new stick's home.tar.gz.

    restore_home() in the initramfs unpacks this archive into the home
    directory itself, so the members must be relative: -C <home> with a bare
    ".". The SSH keystore is excluded - see SSH_KEYSTORE_NAME.
    """
    return [
        "tar",
        "-C", home_dir,
        f"--exclude=./{SSH_KEYSTORE_NAME}",
        "-czf", dest,
        ".",
    ]


def copy_home_to_drive(device: str) -> bool:
    """Write this machine's home directory onto a freshly installed drive.

    Returns True when home.tar.gz is on the drive's EFI partition. Never
    raises: the install has already succeeded by the time this runs, and a
    failed copy must not turn a good install into a traceback.
    """
    # Never $HOME, ~, Path.home() or SUDO_USER. This process is root by now,
    # so HOME is /root, and SUDO_USER is unset for a VT root login - which is
    # reachable because root has no password. The same defect in
    # dbrrg-save-home archived root's dotfiles over the user's home.
    try:
        home_dir = pwd.getpwnam(TLUSER).pw_dir
    except KeyError:
        log(f"WARNING: no {TLUSER} account on this system - home not copied")
        return False

    if not os.path.isdir(home_dir):
        log(f"WARNING: {home_dir} is not a directory - home not copied")
        return False

    efi_partition = find_efi_partition(device)
    waited = 0
    while efi_partition is None and waited < EFI_RETRY_SECONDS:
        time.sleep(1)
        waited += 1
        efi_partition = find_efi_partition(device)
    if efi_partition is None:
        log(f"WARNING: no {EFI_PARTLABEL} partition found on {device} after "
            f"{waited}s - home not copied")
        return False

    tmp_mount = tempfile.mkdtemp(prefix="dbrrg-home-")
    _register_cleanup("dir", tmp_mount)
    dest = os.path.join(tmp_mount, HOME_ARCHIVE_NAME)
    ok = False

    try:
        run_cmd(["mount", efi_partition, tmp_mount], capture=True)
        _register_cleanup("mount", tmp_mount)

        log(f"Copying {home_dir} to {device} (excluding the SSH host keys)")
        try:
            run_cmd(home_archive_argv(home_dir, dest), capture=True)
        except subprocess.CalledProcessError as e:
            # GNU tar exits 1 for "file changed as we read it" - a socket, a
            # dangling symlink, a file being written - and still produces a
            # usable archive. Only 2 and above are real errors.
            if e.returncode == 1:
                log("NOTE: some files changed while being archived; the copy "
                    "is usable")
            else:
                raise

        # The archive is in the page cache until this returns. A stick pulled
        # out before it lands carries an empty or partial file, which the next
        # boot's restore may accept in place of a good home.
        run_cmd(["sync"], capture=True)
        ok = True
    except subprocess.CalledProcessError as e:
        log(f"WARNING: could not copy the home directory: {e}")
        if os.path.isfile(dest):
            # A truncated home.tar.gz is worse than none at all: the next boot
            # may accept it and replace the user's good home with a broken one.
            try:
                os.unlink(dest)
            except OSError:
                pass
        ok = False
    except OSError as e:
        log(f"WARNING: could not copy the home directory: {e}")
        ok = False
    finally:
        try:
            run_cmd(["umount", tmp_mount], capture=True)
            _unregister_cleanup("mount", tmp_mount)
        except subprocess.CalledProcessError as e:
            log(f"WARNING: could not unmount {tmp_mount}: {e} - the copied "
                f"home may be incomplete")
            ok = False
        shutil.rmtree(tmp_mount, ignore_errors=True)
        _unregister_cleanup("dir", tmp_mount)

    if ok:
        log(f"Home directory copied to {device}")
    return ok
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test-unit`
Expected: PASS, 18 tests (5 from Task 4, 13 new).

If `test_a_failed_umount_is_a_failed_copy` fails, check that the `finally`
block's `ok = False` is not overwritten by the `if ok:` log below it — the
assignment must happen before the return.

- [ ] **Step 5: Ask the question in do_fresh_install**

In `do_fresh_install()`, replace:

```python
    # Sync and reload partition table
    run_cmd(["sync"])
    run_cmd(["partprobe", drive.device], check=False, capture=True)

    log("Fresh install complete!")
```

with:

```python
    # Sync and reload partition table
    run_cmd(["sync"])
    run_cmd(["partprobe", drive.device], check=False, capture=True)

    # Offer to carry this machine's configuration across. The new stick boots
    # with the shipped default home otherwise, so the user re-enters their
    # WiFi credentials and ThinLinc settings by hand. The SSH host keys are
    # excluded, so the new machine gets its own identity.
    #
    # Defaults to no: the person may be building a stick for somebody else.
    # Asked only here - the A/B upgrade path writes to a drive that already
    # carries this machine's home.
    print()
    print("  This machine's home directory holds its WiFi credentials,")
    print("  ThinLinc settings and customisations. Copying it onto the new")
    print("  drive means it boots configured. The SSH host keys are not")
    print("  copied, so the new machine generates its own.")
    print()
    if confirm("  Copy this machine's home directory to the new drive?"):
        copy_home_to_drive(drive.device)

    log("Fresh install complete!")
```

`confirm()` needs no `default` parameter and must not get one. It loops until
the user types `y` or `n`, and returns `False` on EOF or Ctrl-C
(`upgrade-image:167-180`). The answer you get without answering is therefore
already no, which is what the spec asks for. Adding a default that could be
`True` would be the only way to get this wrong.

- [ ] **Step 6: Run the whole offline set**

Run: `make test-unit && test/integration/test-save-home.sh && test/integration/test-initramfs-home.sh`
Expected: all PASS.

- [ ] **Step 7: Check the script still parses and the UI path is reachable**

Run: `python3 -c "import importlib.machinery, importlib.util; s=importlib.util.spec_from_loader('u', importlib.machinery.SourceFileLoader('u','overlay/usr/bin/upgrade-image')); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print('imports clean')"`
Expected: `imports clean`.

Run: `python3 -m py_compile overlay/usr/bin/upgrade-image && echo "compiles"`
Expected: `compiles`.

- [ ] **Step 8: Commit**

```bash
git add overlay/usr/bin/upgrade-image test/unit/test_upgrade_image.py
git commit -m "feat: offer to copy this machine's home onto a new drive

A fresh install produced a stick with the shipped default home, so the
user re-entered their WiFi credentials and ThinLinc settings by hand on
a machine that already had them. do_fresh_install now asks, after the
image is written and defaulting to no, whether to copy this machine's
home directory across. It writes home.tar.gz to the new drive's EFI
partition, which is the file the initramfs reads at boot, so the new
stick comes up configured.

~/.dbrrg-ssh-host-keys is excluded. That directory is the machine's SSH
identity; copying it gives two machines the same host key. A stick
without it generates its own on first boot and stages them at the first
clean logout.

The source directory comes from pwd.getpwnam(\"tluser\"), never \$HOME,
~ or SUDO_USER: the process is root by then so HOME is /root, and
SUDO_USER is unset for a VT root login, which is reachable because root
has no password. This is the defect cfe7aa0 fixed in dbrrg-save-home,
arriving by a different door.

The destination is addressed by device node from find_efi_partition, not
through /dev/disk/by-partlabel/EFI-SYSTEM: a fresh install writes the
image byte for byte, so two partitions then carry that label and the
symlink resolves to whichever one udev saw last.

Four failure modes are handled rather than left to a traceback after a
successful install: a renamed tluser account, an EFI partition udev has
not re-read yet (retried for 15s), a failed archive (the partial file is
removed, because a truncated home.tar.gz may be accepted by the next
boot in place of a good home), and a failed unmount (reported as a
failed copy, since the archive is still in the page cache). GNU tar's
exit 1, \"file changed as we read it\", keeps the archive; 2 and above
discard it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Guard the new behaviour in the image suite

**Files:**
- Modify: `test/integration/test-session-packages.sh`
- Test: the same file

**Interfaces:**
- Consumes: everything above, as it exists in a built `ramroot.sqsh`.
- Produces: nothing.

**Why:** Tasks 1 to 5 are tested against the source tree. This task asserts the
built image actually carries them, which is the gap that let a stale
`.ubuntu-container` stamp report green against an old binary once before
(`Makefile:81-94`).

- [ ] **Step 1: Read the existing idiom**

Run: `grep -n 'LIST\|unsquashfs\|^ok\|^bad' test/integration/test-session-packages.sh | head -30`
Expected: the file computes a listing once into `$LIST` and greps that.

**Two traps recorded in `CLAUDE.md` and both live bugs in this file before:**
`unsquashfs -l … | grep -q` reports failure on success under `pipefail`, because
`grep -q` exits at the first match and `unsquashfs` dies of SIGPIPE — grep the
listing the test already computed. And `unsquashfs` exits 0 for a path it did
not find, so an extraction check needs an explicit `[[ -f … ]]` after it or the
assertion passes vacuously on a missing file.

- [ ] **Step 2: Write the failing assertions**

Append to `test/integration/test-session-packages.sh`, before its final exit:

```bash
# --- the home copy and the save contract ---------------------------------

# dbrrg-save-home must address the node the initramfs recorded. A built image
# that still mounts the by-partlabel symlink can write a home onto the wrong
# stick after a fresh install.
if grep -q 'boot-efi-dev' "$EXTRACT/usr/bin/dbrrg-save-home"; then
    ok "dbrrg-save-home reads boot-efi-dev"
else
    bad "dbrrg-save-home does not read boot-efi-dev - it would re-resolve the label"
fi

if ! grep -q 'mount /dev/disk/by-partlabel/EFI-SYSTEM' \
        "$EXTRACT/usr/bin/dbrrg-save-home"; then
    ok "dbrrg-save-home does not mount the by-partlabel symlink directly"
else
    bad "dbrrg-save-home still mounts /dev/disk/by-partlabel/EFI-SYSTEM"
fi

# Each refusal needs its own code. The menu switches on them.
for code in 2 3 4 5; do
    if grep -q "exit $code" "$EXTRACT/usr/bin/dbrrg-save-home"; then
        ok "dbrrg-save-home can exit $code"
    else
        bad "dbrrg-save-home has no 'exit $code' - a refusal is still reported as success"
    fi
done

# The branch that used to print "home saved" while storing nothing.
if ! grep -q 'no idea how to store your home' \
        "$EXTRACT/usr/bin/dbrrg-save-home"; then
    ok "the no-target branch no longer claims the home was saved"
else
    bad "the old no-target message is still in the image"
fi

# The home copy must never carry the machine's SSH identity to another machine.
if grep -q 'exclude=./.dbrrg-ssh-host-keys' "$EXTRACT/usr/bin/upgrade-image"; then
    ok "upgrade-image excludes the SSH keystore from the copied home"
else
    bad "upgrade-image does not exclude .dbrrg-ssh-host-keys - two machines would share a host key"
fi

# The home must come from the passwd database, not from HOME. Under sudo on
# this image HOME is /root.
if grep -q 'getpwnam' "$EXTRACT/usr/bin/upgrade-image"; then
    ok "upgrade-image resolves the home from the passwd database"
else
    bad "upgrade-image does not call getpwnam - it may be archiving /root"
fi

if ! grep -qE 'Path\.home\(\)|os\.environ\[.HOME.\]|expanduser' \
        "$EXTRACT/usr/bin/upgrade-image"; then
    ok "upgrade-image resolves no user path from HOME"
else
    bad "upgrade-image resolves a path from HOME, which is /root under sudo"
fi

# The timeout must exceed dbrrg-save-home's own 60s ping bound, and the bare
# except that discarded the result must be gone.
if grep -q 'SAVE_HOME_TIMEOUT = 600' "$EXTRACT/usr/bin/upgrade-image"; then
    ok "upgrade-image gives the save longer than its own ping bound"
else
    bad "upgrade-image's save timeout is not 600s - a netboot upload gets killed"
fi

# The initramfs half. dbrrg-lib.sh is inside the initrd, not the squashfs, so
# assert against the overlay copy the build consumed plus the shipped initrd.
if lsinitrd "$INITRD" 2>/dev/null | grep -q 'dbrrg-lib.sh'; then
    if lsinitrd "$INITRD" -f \
            'usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh' 2>/dev/null |
            grep -q 'dbrrg_record_efi_dev'; then
        ok "the shipped initramfs records boot-efi-dev"
    else
        bad "the shipped initramfs has no dbrrg_record_efi_dev - the save cannot find the right stick"
    fi
else
    bad "dbrrg-lib.sh is not in the shipped initramfs"
fi
```

- [ ] **Step 3: Check the variables these assertions use exist**

Run: `grep -n 'EXTRACT=\|INITRD=\|LIST=' test/integration/test-session-packages.sh`
Expected: `EXTRACT` and `LIST` exist. `INITRD` may not. If it does not, add it
next to the other path variables, matching how the file locates `ramroot.sqsh`:

```bash
INITRD="${INITRD:-artifacts/rootfs/initrd.img}"
```

and if `lsinitrd` is unavailable on the host, replace that last assertion with
one against the source tree, saying plainly in the message that it is the
source and not the image:

```bash
if grep -q 'dbrrg_record_efi_dev' \
        overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh; then
    ok "dbrrg-lib.sh records boot-efi-dev (source tree; lsinitrd unavailable)"
else
    bad "dbrrg-lib.sh has no dbrrg_record_efi_dev"
fi
```

Do not silently drop the assertion. A test that cannot see the image should say
so rather than disappear.

- [ ] **Step 4: Run it against the current image to watch it fail**

Run: `test/integration/test-session-packages.sh`
Expected: FAIL on the new assertions. The image on disk predates this branch.

If it passes, the assertions are matching something they should not — check the
`grep` patterns before rebuilding.

- [ ] **Step 5: Rebuild and run the whole suite**

**Check `artifacts/` first.** It is a symlink to
`/home/oetiker/scratch/dbrrg-artifacts`, shared with every other checkout of
this project, so two concurrent builds corrupt each other.

Run: `ls -l artifacts && ps aux | grep -c '[p]odman build'`
Expected: `0` concurrent builds. If not, stop and wait.

Run: `make test`
Expected: PASS. 9 suites now, `test-unit` first.

- [ ] **Step 6: Boot it**

Run: `make qemu-smoke`
Expected: a clean boot, no `Found ordering cycle` line. `scripts/check-boot-smoke.sh`
fails the run on any such line.

Then confirm the new breadcrumb is actually written on a real boot:

Run: `grep -i 'boot-efi-dev\|EFI-SYSTEM appeared' artifacts/images/qemu-smoke.log`
Expected: no warning about being unable to write it. QEMU's virtio-blk appears
at once, so this boot takes `dbrrg_wait_for_efi`'s early return — which is
exactly the path Task 1 Step 4 warns is easy to miss.

- [ ] **Step 7: Commit**

```bash
git add test/integration/test-session-packages.sh
git commit -m "test: assert the built image carries the save contract

Tasks 1 to 5 are tested against the source tree. These assertions run
against the unsquashfs-ed image and the shipped initramfs, which is the
gap that once let a stale .ubuntu-container stamp report green against
an old binary.

Covers the node preference over the by-partlabel symlink, all four new
refusal codes, the removal of the branch that printed \"home saved\"
while storing nothing, the SSH keystore exclusion, the passwd-database
home lookup and the absence of any HOME-derived path, the 600s save
timeout, and dbrrg_record_efi_dev inside the initrd.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Verification

Run before declaring the plan done, and paste the output rather than
summarising it:

```bash
make test-unit                        # 18 tests, no container
make test                             # 9 suites
make qemu-smoke                       # clean boot, no ordering cycle
```

**What this plan does not verify, and cannot:** that a real stick written by
`do_fresh_install` boots with the copied home in place. QEMU has no second USB
device and no way to reproduce the two-partitions-one-PARTLABEL condition that
is the whole reason Task 1 and Task 2 exist. That needs two sticks and a real
machine:

1. On a configured machine, `sudo upgrade-image`, fresh install onto a second
   stick, answer yes to the home copy.
2. Boot the second stick. Its WiFi and ThinLinc settings should be present, and
   `ls ~/.dbrrg-ssh-host-keys` should be empty or absent — a copied keystore is
   the failure this excludes.
3. Log out on the second stick, reboot it, and check `ssh-keyscan` returns a
   *different* host key than the first stick's.
4. On the first stick, log out and confirm its own home still saves: the
   recorded node must still point at its own EFI partition after the install.

Step 4 is the regression Task 1 and 2 prevent. Before them, a save on the
first stick after installing the second could land on the wrong one.
