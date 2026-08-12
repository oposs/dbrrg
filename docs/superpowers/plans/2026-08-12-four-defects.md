# Four Field Defects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship screenshot tooling, make minimized windows recoverable, consolidate dbrrg's scripts under `/usr/bin`, and make sshd start with a host key that survives reboots.

**Architecture:** The home directory restore moves from `/etc/profile.d/10-dbrrg-session.sh` into the dracut initramfs, where it lands before `multi-user.target`. That makes the already-persisted home usable as the storage channel for SSH host keys, which removes the need for any new EFI file or boot-server endpoint. The other three fixes are package additions and file moves.

**Tech Stack:** POSIX `sh` (dracut initramfs and system scripts), bash (tests), systemd units, dracut module hooks, Podman/Ubuntu 26.04 container build, labwc/Wayland session.

**Spec:** `docs/superpowers/specs/2026-08-12-four-defects-design.md`

## Global Constraints

- **labwc must register zero keybindings.** No `<keybind>` or `<default />` may be added to `overlay/etc/dbrrg/labwc/rc.xml` by any task in this plan. See CLAUDE.md, "labwc must have zero keybindings".
- **Never add a `find`/`rm` sweep over `/usr/lib/firmware`.** Firmware content is decided by package selection alone.
- **`dracut` must keep `--no-hostonly`.** Do not touch that flag.
- **labwc stays the local `+dbrrg1` rebuild.** Do not switch to the archive package.
- **Build parallelism: never more than 4 cores.** The build host is shared.
- **Containers use `podman`,** not docker.
- All comments, variable names and technical documentation in **English**.
- Every initramfs failure path must `warn` and continue. Nothing added by this plan may `die` — a client that cannot restore its home or its keys must still boot.
- Shell in the initramfs and in `overlay/usr/bin/` is POSIX `sh`, not bash. Tests are bash.

---

## File Structure

**Created:**

| file | responsibility |
| --- | --- |
| `overlay/usr/bin/dbrrg-ssh-hostkeys` | install host keys from the home keystore, generate them if absent, stage them back |
| `overlay/etc/systemd/system/dbrrg-ssh-hostkeys.service` | run the above before `ssh.service` |
| `overlay/etc/dbrrg/waybar/config.jsonc` | taskbar module definition |
| `overlay/etc/dbrrg/waybar/style.css` | taskbar styling |
| `test/integration/test-initramfs-home.sh` | home restore helpers, offline |
| `test/integration/test-ssh-hostkeys.sh` | host key install/generate/stage, offline |

**Modified:**

| file | change |
| --- | --- |
| `overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh` | add `dbrrg_home_url`, `dbrrg_record_boot_mac`, `dbrrg_restore_home_from_file`, `dbrrg_restore_home_from_url`, `restore_home` |
| `overlay/usr/lib/dracut/modules.d/90dbrrg/setup-overlay.sh` | call `restore_home` after the machine-id block |
| `overlay/usr/lib/dracut/modules.d/90dbrrg/mount-squashfs.sh` | record the boot MAC when bringing an interface up |
| `overlay/usr/lib/dracut/modules.d/90dbrrg/module-setup.sh` | install `tar` and `gzip` into the initramfs |
| `overlay/etc/profile.d/10-dbrrg-session.sh` | drop the restore call; update script paths |
| `overlay/usr/bin/dbrrg-save-home` | read `boot-mac`; stage host keys before tarring |
| `overlay/usr/bin/dbrrg-session` | launch/kill waybar; updated `save-home` path |
| `containers/ubuntu/Dockerfile` | new packages; mask `ssh.socket`; drop the old regenerate unit |
| `test/integration/test-session-packages.sh` | assertions for every change above |
| `Makefile` | wire the two new test scripts into `make test` |
| `CLAUDE.md` | boot flow, persistence, debugging, waybar, ssh.socket |

**Deleted:**

- `overlay/usr/local/bin/dbrrg-restore-home` (becomes `restore_home()` in `dbrrg-lib.sh`)
- `overlay/etc/systemd/system/regenerate_ssh_host_keys.service`

**Renamed (Task 7):**

- `overlay/opt/thinlinc/bin/save-home` → `overlay/usr/bin/dbrrg-save-home`
- `overlay/usr/local/bin/dbrrg-session` → `overlay/usr/bin/dbrrg-session`
- `overlay/usr/local/bin/dbrrg-compose-labwc-config` → `overlay/usr/bin/dbrrg-compose-labwc-config`

**Note on paths:** Tasks 2–6 are written against the *pre-move* paths (`overlay/usr/local/bin/…`, `overlay/opt/thinlinc/bin/…`). Task 7 performs the move and fixes every reference in one commit. Do not anticipate the move in earlier tasks.

---

## Task 1: Confirm the sshd ordering-cycle diagnosis

**This is a gate, not a code change.** The whole of Task 6 rests on a diagnosis derived by reading unit files, never observed on a running machine. Confirm it or re-diagnose before writing that code.

**Files:** none.

**Interfaces:**
- Consumes: nothing.
- Produces: a go/no-go for Task 6's `ssh.socket` masking and unit ordering.

- [ ] **Step 1: Boot a current image on hardware or in QEMU**

```bash
make image
# then boot artifacts/images/dbrrg-usb.img on a test machine, or:
make qemu-smoke
```

- [ ] **Step 2: Look for the cycle**

On the booted machine (VT or serial console):

```bash
journalctl -b | grep -i "ordering cycle"
systemctl list-jobs
systemctl status regenerate_ssh_host_keys.service ssh.service ssh.socket
ls -l /etc/ssh/ssh_host_*
```

Expected if the diagnosis holds: a log line naming an ordering cycle and a
deleted job involving `regenerate_ssh_host_keys.service` or `ssh.socket`,
and/or no `ssh_host_*_key` files present.

- [ ] **Step 3: Record the finding in the spec**

Append the observed output to
`docs/superpowers/specs/2026-08-12-four-defects-design.md` under
"Hardware confirmation required", replacing the claim with evidence.

**If the cycle is NOT what is happening:** stop. Do not proceed to Task 6.
Re-diagnose why sshd does not start and revise the spec. Tasks 2–5 and 7–9
are independent of this finding and may proceed.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-12-four-defects-design.md
git commit -m "docs: record observed sshd startup failure mode"
```

---

## Task 2: `dbrrg_home_url` and `dbrrg_record_boot_mac`

Two small pure-ish helpers, done first because everything else in the
initramfs work consumes them.

**Files:**
- Modify: `overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh`
- Test: `test/integration/test-initramfs-home.sh` (create)

**Interfaces:**
- Consumes: `warn` (from `/lib/dracut-lib.sh`, stubbed in tests).
- Produces:
  - `dbrrg_home_url <ramroot-url> <mac>` → prints the archive URL on stdout, returns 1 on empty input.
  - `dbrrg_record_boot_mac <address-file> <state-dir>` → writes `<state-dir>/boot-mac`, returns 0/1.

Both take explicit paths rather than reading `$DBRRG_STATE`, because that
variable is `readonly` and points at `/run/dbrrg`, which a test cannot
write.

- [ ] **Step 1: Write the failing test**

Create `test/integration/test-initramfs-home.sh`:

```bash
#!/bin/bash
# Offline tests for the initramfs home restore helpers in dbrrg-lib.sh.
#
# The home restore moved out of /etc/profile.d/10-dbrrg-session.sh and into
# the initramfs so that /home/tluser is populated before multi-user.target -
# which is what lets the SSH host keys ride along inside the home archive
# instead of needing their own EFI file or boot-server endpoint. See
# docs/superpowers/specs/2026-08-12-four-defects-design.md.
#
# This runs without a container and without root: it stubs dracut's logging
# functions and curl, and calls the library functions directly. It therefore
# proves the logic, not the integration - setup-overlay.sh calling
# restore_home at the right moment is covered by make qemu-smoke.
#
# Usage: test/integration/test-initramfs-home.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh"

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: $LIB not found" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# dracut's logging helpers are absent outside an initramfs. Define them
# before sourcing so the library's "type info || . /lib/dracut-lib.sh"
# guard does not try to pull in the real one.
info() { :; }
warn() { echo "warn: $*" >>"$WORK/warnings"; }
dinfo() { :; }
die()  { echo "die: $*" >>"$WORK/deaths"; return 1; }
: >"$WORK/warnings"
: >"$WORK/deaths"

# shellcheck source=/dev/null
. "$LIB"

# --- dbrrg_home_url ------------------------------------------------------

url=$(dbrrg_home_url "http://boot.example.org/tl/ramroot.sqsh" "aa:bb:cc:dd:ee:ff")
if [[ "$url" == "http://boot.example.org/tl/home.pkg?mac=aa:bb:cc:dd:ee:ff" ]]; then
    ok "dbrrg_home_url builds the archive URL from the ramroot URL"
else
    bad "dbrrg_home_url returned '$url'"
fi

if dbrrg_home_url "" "aa:bb:cc:dd:ee:ff" >/dev/null 2>&1; then
    bad "dbrrg_home_url accepted an empty ramroot URL"
else
    ok "dbrrg_home_url rejects an empty ramroot URL"
fi

if dbrrg_home_url "http://x/tl/ramroot.sqsh" "" >/dev/null 2>&1; then
    bad "dbrrg_home_url accepted an empty MAC"
else
    ok "dbrrg_home_url rejects an empty MAC"
fi

# --- dbrrg_record_boot_mac ----------------------------------------------

mkdir -p "$WORK/sysfs/eth0" "$WORK/state"
echo "de:ad:be:ef:00:01" >"$WORK/sysfs/eth0/address"

if dbrrg_record_boot_mac "$WORK/sysfs/eth0/address" "$WORK/state" &&
   [[ "$(cat "$WORK/state/boot-mac")" == "de:ad:be:ef:00:01" ]]; then
    ok "dbrrg_record_boot_mac writes the MAC to <state-dir>/boot-mac"
else
    bad "dbrrg_record_boot_mac did not record the MAC"
fi

if dbrrg_record_boot_mac "$WORK/sysfs/nosuch/address" "$WORK/state" 2>/dev/null; then
    bad "dbrrg_record_boot_mac succeeded on a missing address file"
else
    ok "dbrrg_record_boot_mac fails on a missing address file"
fi

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - initramfs home helpers"
    exit 1
fi

echo ""
echo "PASSED - initramfs home helpers"
exit 0
```

```bash
chmod +x test/integration/test-initramfs-home.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-initramfs-home.sh`
Expected: FAIL — `dbrrg_home_url: command not found`.

- [ ] **Step 3: Add both functions to `dbrrg-lib.sh`**

Insert immediately after the `is_remote_url()` function, before
`verify_squashfs()`:

```sh
# dbrrg_home_url <ramroot-url> <mac>
#
# Build the URL the home archive lives at on the boot server, from the same
# ramroot URL the squashfs came from: .../tl/ramroot.sqsh -> .../tl/home.pkg
#
# dbrrg-save-home derives the identical base with a greedy sed over
# /proc/cmdline. Both reduce to "the directory the ramroot URL sits in", and
# they must not be allowed to diverge - a mismatch means the client posts its
# home somewhere it will never look for it again.
dbrrg_home_url() {
    _dhu_ramroot="$1"
    _dhu_mac="$2"

    [ -n "$_dhu_ramroot" ] || return 1
    [ -n "$_dhu_mac" ] || return 1

    echo "${_dhu_ramroot%/*}/home.pkg?mac=${_dhu_mac}"
}

# dbrrg_record_boot_mac <address-file> <state-dir>
#
# Persist the MAC of the interface the initramfs actually brought up, so
# dbrrg-save-home posts the home archive back under the same key the restore
# fetched it with.
#
# Before this, both halves derived the MAC independently from kernel ifindex
# 2 - which agreed only because both ran in the booted system. ifindex
# follows driver registration order, the initramfs loads a deliberately small
# driver set, and mount-squashfs.sh picks its interface by /sys/class/net
# glob order instead; on a machine with two NICs those can name different
# devices. Recording what was actually used makes the two halves agree by
# construction. It is also the better identity: on netboot it is the
# interface that demonstrably worked, having taken a DHCP lease and served
# ramroot.sqsh.
dbrrg_record_boot_mac() {
    _drbm_addr_file="$1"
    _drbm_state_dir="$2"

    if [ ! -r "$_drbm_addr_file" ]; then
        warn "dbrrg: cannot read MAC from $_drbm_addr_file"
        return 1
    fi

    _drbm_mac=$(cat "$_drbm_addr_file" 2>/dev/null | tr -d '\012')
    if [ -z "$_drbm_mac" ]; then
        warn "dbrrg: empty MAC in $_drbm_addr_file"
        return 1
    fi

    mkdir -p "$_drbm_state_dir" 2>/dev/null || true
    if ! echo "$_drbm_mac" > "$_drbm_state_dir/boot-mac" 2>/dev/null; then
        warn "dbrrg: could not write $_drbm_state_dir/boot-mac"
        return 1
    fi

    return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `test/integration/test-initramfs-home.sh`
Expected: PASS, 5 `ok` lines.

- [ ] **Step 5: Commit**

```bash
git add overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh \
        test/integration/test-initramfs-home.sh
git commit -m "feat(initramfs): add home archive URL and boot-MAC helpers"
```

---

## Task 3: Home archive extraction helpers

**Files:**
- Modify: `overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh`
- Test: `test/integration/test-initramfs-home.sh`

**Interfaces:**
- Consumes: `warn`; `dbrrg_restore_home_from_url` consumes `dbrrg_restore_home_from_file` from this same task.
- Produces:
  - `dbrrg_restore_home_from_file <archive> <target-home>` → 0 on success, 1 on missing/corrupt archive. Never fatal.
  - `dbrrg_restore_home_from_url <url> <target-home> [timeout-seconds] [tmp-file]` → 0/1. Defaults: timeout 120, tmp file `/tmp/dbrrg-home.pkg`.

- [ ] **Step 1: Write the failing tests**

Append to `test/integration/test-initramfs-home.sh`, immediately **before**
the final `if [[ $fail -ne 0 ]]` block:

```bash
# --- dbrrg_restore_home_from_file ---------------------------------------

# Build a home archive the way dbrrg-save-home does: tar czf from inside
# $HOME, so members are stored as ./relative paths.
mkdir -p "$WORK/src-home/.thinlinc"
echo "layout=ch" >"$WORK/src-home/.dbrrg-environment"
echo "tlconf" >"$WORK/src-home/.thinlinc/tlclient.conf"
( cd "$WORK/src-home" && tar czf "$WORK/home.tar.gz" . )

TARGET="$WORK/newroot/home/tluser"
mkdir -p "$TARGET"

if dbrrg_restore_home_from_file "$WORK/home.tar.gz" "$TARGET" &&
   [[ -f "$TARGET/.dbrrg-environment" ]] &&
   [[ -f "$TARGET/.thinlinc/tlclient.conf" ]]; then
    ok "restore_home_from_file extracts the archive into the target home"
else
    bad "restore_home_from_file did not extract the archive"
fi

# An absent archive is the normal first-boot case, not an error condition -
# it must not be fatal and must leave the default home alone.
mkdir -p "$WORK/newroot2/home/tluser"
echo "shipped-default" >"$WORK/newroot2/home/tluser/.bashrc"
if dbrrg_restore_home_from_file "$WORK/nope.tar.gz" "$WORK/newroot2/home/tluser" 2>/dev/null; then
    bad "restore_home_from_file reported success on a missing archive"
else
    ok "restore_home_from_file fails quietly on a missing archive"
fi
if [[ "$(cat "$WORK/newroot2/home/tluser/.bashrc")" == "shipped-default" ]]; then
    ok "missing archive leaves the shipped default home intact"
else
    bad "missing archive damaged the default home"
fi

# A corrupt archive must warn and return non-zero, never abort the boot.
echo "this is not a tarball" >"$WORK/corrupt.tar.gz"
mkdir -p "$WORK/newroot3/home/tluser"
if dbrrg_restore_home_from_file "$WORK/corrupt.tar.gz" "$WORK/newroot3/home/tluser" 2>/dev/null; then
    bad "restore_home_from_file reported success on a corrupt archive"
else
    ok "restore_home_from_file fails on a corrupt archive"
fi
if [[ ! -s "$WORK/deaths" ]]; then
    ok "no die() was called on any failure path"
else
    bad "a failure path called die(): $(cat "$WORK/deaths")"
fi

# --- dbrrg_restore_home_from_url ----------------------------------------

# Stub curl. $DBRRG_TEST_CURL_MODE selects the behaviour under test.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
# Minimal curl stand-in: find the -o target, act per DBRRG_TEST_CURL_MODE.
out=""
prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && out="$a"
    prev="$a"
done
case "${DBRRG_TEST_CURL_MODE:-ok}" in
    ok)      cp "$DBRRG_TEST_CURL_PAYLOAD" "$out"; exit 0 ;;
    notfound) exit 22 ;;   # curl -f exit code for an HTTP 4xx
    timeout)  exit 28 ;;   # curl exit code for a timeout
esac
STUB
chmod +x "$STUBS/curl"
PATH="$STUBS:$PATH"
export DBRRG_TEST_CURL_PAYLOAD="$WORK/home.tar.gz"

mkdir -p "$WORK/newroot4/home/tluser"
DBRRG_TEST_CURL_MODE=ok
export DBRRG_TEST_CURL_MODE
if dbrrg_restore_home_from_url "http://boot/tl/home.pkg?mac=x" \
        "$WORK/newroot4/home/tluser" 5 "$WORK/dl.pkg" &&
   [[ -f "$WORK/newroot4/home/tluser/.dbrrg-environment" ]]; then
    ok "restore_home_from_url extracts a fetched archive"
else
    bad "restore_home_from_url did not extract a fetched archive"
fi
if [[ ! -e "$WORK/dl.pkg" ]]; then
    ok "restore_home_from_url removes its temporary download"
else
    bad "restore_home_from_url left $WORK/dl.pkg behind"
fi

# First netboot of a machine the server has never seen: a 404 is expected,
# not a fault.
mkdir -p "$WORK/newroot5/home/tluser"
DBRRG_TEST_CURL_MODE=notfound
if dbrrg_restore_home_from_url "http://boot/tl/home.pkg?mac=x" \
        "$WORK/newroot5/home/tluser" 5 "$WORK/dl5.pkg" 2>/dev/null; then
    bad "restore_home_from_url reported success on a 404"
else
    ok "restore_home_from_url fails quietly on a 404"
fi

# A hanging boot server must not hang the boot.
mkdir -p "$WORK/newroot6/home/tluser"
DBRRG_TEST_CURL_MODE=timeout
if dbrrg_restore_home_from_url "http://boot/tl/home.pkg?mac=x" \
        "$WORK/newroot6/home/tluser" 5 "$WORK/dl6.pkg" 2>/dev/null; then
    bad "restore_home_from_url reported success on a timeout"
else
    ok "restore_home_from_url fails quietly on a timeout"
fi

# The bounded wait is the whole point: the login-time script this replaces
# looped on ping forever, which in an initramfs is a machine that never boots
# and has no console to interrupt it.
if grep -q -- '--max-time' \
        "$REPO/overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh"; then
    ok "the fetch is bounded by --max-time"
else
    bad "no --max-time in the fetch - an unbounded wait would hang the boot"
fi

if [[ ! -s "$WORK/deaths" ]]; then
    ok "still no die() on any failure path"
else
    bad "a failure path called die(): $(cat "$WORK/deaths")"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-initramfs-home.sh`
Expected: FAIL — `dbrrg_restore_home_from_file: command not found`.

- [ ] **Step 3: Add both functions to `dbrrg-lib.sh`**

Insert after `dbrrg_record_boot_mac()`:

```sh
# dbrrg_restore_home_from_file <archive> <target-home>
#
# Extract a home archive over the target home directory. Returns non-zero on
# a missing or unreadable archive; both are normal (first boot, or a machine
# whose home was never saved) and must leave the shipped default home in
# place rather than aborting the boot.
dbrrg_restore_home_from_file() {
    _drhf_archive="$1"
    _drhf_home="$2"

    if [ ! -f "$_drhf_archive" ]; then
        warn "dbrrg: no home archive at $_drhf_archive"
        return 1
    fi

    if ! mkdir -p "$_drhf_home" 2>/dev/null; then
        warn "dbrrg: cannot create $_drhf_home"
        return 1
    fi

    # A payload that is valid gzip but not a tar decompresses cleanly, lists
    # zero members, and makes GNU tar exit 0 - measured on this host, not
    # assumed. Trusting that exit code would report a successful restore
    # having restored nothing, and the damage compounds: dbrrg-ssh-hostkeys
    # would then treat the machine as keyless and generate fresh host keys,
    # and dbrrg-save-home would overwrite the user's good archive with the
    # empty one at logout. A boot server answering 200 with a gzip-encoded
    # error page is enough to trigger it, and curl -f does not catch a 200.
    #
    # sed, not head: module-setup.sh installs sed into the initramfs and does
    # not install head, so a head-based check would pass every offline test on
    # a build host and fail on the target. The q makes it stop after the first
    # member instead of listing a whole home directory.
    if [ -z "$(tar -tzf "$_drhf_archive" 2>/dev/null | sed -n '1p;q')" ]; then
        warn "dbrrg: $_drhf_archive is not a usable tar archive"
        return 1
    fi

    # tar's default as root is --same-owner, and that is REQUIRED here, not
    # incidental. dbrrg-save-home writes the archive as tluser, so members
    # carry uid/gid 1000 numerically; preserving them is what makes the
    # restored home belong to tluser. Do NOT add --no-same-owner.
    #
    # Note this is the exact OPPOSITE of what dbrrg-ssh-hostkeys must do a
    # few files away: host keys come out of this same archive tluser-owned
    # and have to be forced to root:root before sshd will touch them. Two
    # different problems; do not "make them consistent".
    if ! tar -xzf "$_drhf_archive" -C "$_drhf_home" 2>/dev/null; then
        warn "dbrrg: home archive $_drhf_archive did not extract cleanly"
        return 1
    fi

    return 0
}

# dbrrg_restore_home_from_url <url> <target-home> [timeout] [tmp-file]
#
# Fetch a home archive from the boot server and extract it. Downloads to a
# temporary file first: piping curl straight into tar would extract a
# half-written archive over the home directory if the transfer died midway.
dbrrg_restore_home_from_url() {
    _drhu_url="$1"
    _drhu_home="$2"
    _drhu_timeout="${3:-120}"
    _drhu_tmp="${4:-/tmp/dbrrg-home.pkg}"

    rm -f "$_drhu_tmp" 2>/dev/null || true

    # -f makes an HTTP 404 a failure rather than a saved error page. A 404
    # is the ordinary first-netboot case for a machine the server has not
    # seen before, so it is warned about and not treated as a fault.
    #
    # --connect-timeout and --max-time are mandatory. The login-time script
    # this replaces waited on `while true; do ping ...; done`; unbounded at
    # login is a session recoverable from a VT, but unbounded here is a
    # machine that never finishes booting.
    if ! curl -f -s -S \
            --connect-timeout 10 --max-time "$_drhu_timeout" \
            -o "$_drhu_tmp" "$_drhu_url" 2>/dev/null; then
        warn "dbrrg: could not fetch home archive from $_drhu_url"
        rm -f "$_drhu_tmp" 2>/dev/null || true
        return 1
    fi

    dbrrg_restore_home_from_file "$_drhu_tmp" "$_drhu_home"
    _drhu_rc=$?
    rm -f "$_drhu_tmp" 2>/dev/null || true
    return $_drhu_rc
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `test/integration/test-initramfs-home.sh`
Expected: PASS, 15 `ok` lines.

- [ ] **Step 5: Commit**

```bash
git add overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh \
        test/integration/test-initramfs-home.sh
git commit -m "feat(initramfs): add home archive extraction helpers"
```

---

## Task 4: `restore_home` orchestrator

**Files:**
- Modify: `overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh`
- Test: `test/integration/test-initramfs-home.sh`

**Interfaces:**
- Consumes: `dbrrg_home_url`, `dbrrg_record_boot_mac`, `dbrrg_restore_home_from_file`, `dbrrg_restore_home_from_url`, `is_remote_url`.
- Produces: `restore_home <newroot> <efi-mount> <state-dir> <ramroot>` → **always returns 0**.

The four explicit parameters exist so the function is testable; `$DBRRG_STORAGE`
and `$DBRRG_STATE` are `readonly` and point into `/run`.

- [ ] **Step 1: Write the failing tests**

Append to `test/integration/test-initramfs-home.sh` before the final
`if [[ $fail -ne 0 ]]` block:

```bash
# --- restore_home (orchestrator) ----------------------------------------

# USB boot: ramroot is a relative path, archive sits at the EFI mount root.
mkdir -p "$WORK/usb/efi" "$WORK/usb/state" "$WORK/usb/newroot/home/tluser"
cp "$WORK/home.tar.gz" "$WORK/usb/efi/home.tar.gz"
if restore_home "$WORK/usb/newroot" "$WORK/usb/efi" "$WORK/usb/state" \
        "tl/ramroot.sqsh" &&
   [[ -f "$WORK/usb/newroot/home/tluser/.dbrrg-environment" ]]; then
    ok "restore_home restores from the EFI partition on USB boot"
else
    bad "restore_home did not restore from the EFI partition"
fi

# Netboot: uses the recorded boot MAC to build the URL.
mkdir -p "$WORK/net/efi" "$WORK/net/state" "$WORK/net/newroot/home/tluser"
echo "de:ad:be:ef:00:01" >"$WORK/net/state/boot-mac"
DBRRG_TEST_CURL_MODE=ok
if restore_home "$WORK/net/newroot" "$WORK/net/efi" "$WORK/net/state" \
        "http://boot.example.org/tl/ramroot.sqsh" &&
   [[ -f "$WORK/net/newroot/home/tluser/.dbrrg-environment" ]]; then
    ok "restore_home fetches from the boot server on netboot"
else
    bad "restore_home did not fetch from the boot server"
fi

# Netboot with no recorded MAC: skip, do not guess. Guessing is exactly the
# failure this design removed - a wrong key means the home is posted where
# it will never be found again.
mkdir -p "$WORK/nomac/efi" "$WORK/nomac/state" "$WORK/nomac/newroot/home/tluser"
if restore_home "$WORK/nomac/newroot" "$WORK/nomac/efi" "$WORK/nomac/state" \
        "http://boot.example.org/tl/ramroot.sqsh"; then
    ok "restore_home returns 0 when no boot MAC was recorded"
else
    bad "restore_home returned non-zero with no boot MAC"
fi

# The base the URL was built from must be recorded, so dbrrg-save-home posts
# to the same place instead of re-deriving it with a greedy sed over the whole
# /proc/cmdline. That sed backtracks to the last slash ANYWHERE in the command
# line, so a later parameter containing "/" (root=/dev/sda1, init=/sbin/init)
# silently produces a different base and orphans the client's home.
if [[ "$(cat "$WORK/net/state/boot-home-base" 2>/dev/null)" == "http://boot.example.org/tl" ]]; then
    ok "restore_home records boot-home-base for the save side to reuse"
else
    bad "restore_home did not record boot-home-base (got: $(cat "$WORK/net/state/boot-home-base" 2>/dev/null))"
fi

# USB boot never builds a URL, so there is nothing to record and its absence
# must not be treated as a fault.
if [[ ! -e "$WORK/usb/state/boot-home-base" ]]; then
    ok "no boot-home-base recorded on USB boot"
else
    bad "boot-home-base was recorded on USB boot, where it has no meaning"
fi

# Every failure mode must still return 0: restore_home is called from
# setup-overlay.sh, where a non-zero return would abort the boot.
mkdir -p "$WORK/fail/efi" "$WORK/fail/state" "$WORK/fail/newroot/home/tluser"
DBRRG_TEST_CURL_MODE=timeout
if restore_home "$WORK/fail/newroot" "$WORK/fail/efi" "$WORK/fail/state" \
        "tl/ramroot.sqsh"; then
    ok "restore_home returns 0 when the USB archive is absent"
else
    bad "restore_home returned non-zero on a missing USB archive"
fi
DBRRG_TEST_CURL_MODE=ok

if [[ ! -s "$WORK/deaths" ]]; then
    ok "restore_home never calls die()"
else
    bad "restore_home called die(): $(cat "$WORK/deaths")"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-initramfs-home.sh`
Expected: FAIL — `restore_home: command not found`.

- [ ] **Step 3: Add the orchestrator to `dbrrg-lib.sh`**

Insert after `dbrrg_restore_home_from_url()`:

```sh
# restore_home <newroot> <efi-mount> <state-dir> <ramroot>
#
# Populate /home/tluser in the new root before the pivot.
#
# This used to run at login, from /etc/profile.d/10-dbrrg-session.sh. It runs
# here now so the home directory exists before multi-user.target, which is
# what lets the SSH host keys persist inside it - see
# overlay/usr/bin/dbrrg-ssh-hostkeys.
#
# Moving it EARLIER does not violate the standing rule recorded in
# 10-dbrrg-session.sh. That rule forbids moving the restore back INTO
# dbrrg-session, because ~/.dbrrg-environment must be on disk before labwc
# reads XKB_DEFAULT_* at startup. The initramfs is earlier still, so the
# ordering constraint holds a fortiori.
#
# ALWAYS returns 0. It is called from setup-overlay.sh, where a non-zero
# return aborts the boot. A client that cannot restore its home must still
# come up with the shipped default one.
restore_home() {
    _rh_newroot="$1"
    _rh_efi="$2"
    _rh_state="$3"
    _rh_ramroot="$4"

    _rh_home="$_rh_newroot/home/tluser"

    if is_remote_url "$_rh_ramroot"; then
        _rh_mac=$(cat "$_rh_state/boot-mac" 2>/dev/null | tr -d '\012')
        if [ -z "$_rh_mac" ]; then
            # Deliberately do not fall back to guessing an interface. A
            # wrong MAC means fetching one machine's home onto another, or
            # saving to a key nothing will ever read back.
            warn "dbrrg: no boot MAC recorded, skipping home restore"
            return 0
        fi

        _rh_url=$(dbrrg_home_url "$_rh_ramroot" "$_rh_mac") || return 0

        # Record the base the URL was built from, for the same reason the MAC
        # is recorded: so dbrrg-save-home posts to the identical location
        # rather than re-deriving it.
        #
        # save-home derives the base with a greedy sed over the whole
        # /proc/cmdline (s/.*ramroot=\(.*\)\/.*$/\1/). That backtracks to the
        # LAST slash anywhere in the command line, so any kernel parameter
        # appearing after ramroot= that contains a "/" - root=/dev/sda1,
        # init=/sbin/init - silently yields a wrong base. Today's
        # configs/syslinux.cfg happens to have no such parameter, so the bug
        # is latent rather than live; recording the resolved value here
        # removes the whole class instead of relying on that staying true.
        echo "${_rh_ramroot%/*}" > "$_rh_state/boot-home-base" 2>/dev/null || \
            warn "dbrrg: could not record boot-home-base"

        dbrrg_log "dbrrg: restoring home from $_rh_url"
        dbrrg_restore_home_from_url "$_rh_url" "$_rh_home" 120 || true
    else
        dbrrg_log "dbrrg: restoring home from $_rh_efi/home.tar.gz"
        dbrrg_restore_home_from_file "$_rh_efi/home.tar.gz" "$_rh_home" || true
    fi

    return 0
}
```

Add a `dbrrg_log` stub to the test's helper block (next to `info`/`warn`) so
sourcing works outside an initramfs:

```bash
dbrrg_log() { :; }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `test/integration/test-initramfs-home.sh`
Expected: PASS, 22 `ok` lines.

- [ ] **Step 5: Commit**

```bash
git add overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh \
        test/integration/test-initramfs-home.sh
git commit -m "feat(initramfs): add restore_home orchestrator"
```

---

## Task 5: Wire the restore into the boot, retire `dbrrg-restore-home`

**Files:**
- Modify: `overlay/usr/lib/dracut/modules.d/90dbrrg/setup-overlay.sh`
- Modify: `overlay/usr/lib/dracut/modules.d/90dbrrg/mount-squashfs.sh`
- Modify: `overlay/usr/lib/dracut/modules.d/90dbrrg/module-setup.sh`
- Modify: `overlay/etc/profile.d/10-dbrrg-session.sh`
- Modify: `test/integration/test-session-packages.sh`
- Modify: `Makefile`
- Modify: `CLAUDE.md`
- Delete: `overlay/usr/local/bin/dbrrg-restore-home`

**Interfaces:**
- Consumes: `restore_home`, `dbrrg_record_boot_mac` (Tasks 2–4).
- Produces: `/run/dbrrg/state/boot-mac` in the booted system, consumed by `dbrrg-save-home` in Task 6.

- [ ] **Step 1: Install `tar` and `gzip` into the initramfs**

`restore_home` shells out to `tar -xzf`, and neither binary is in the
initramfs today — `module-setup.sh` installs `curl ip dhclient`, filesystem
tools and `awk grep sed`, but no archiver. GNU tar invokes `gzip` as a
separate process for `-z`, so both are needed.

In `overlay/usr/lib/dracut/modules.d/90dbrrg/module-setup.sh`, change:

```sh
    # Network tools
    inst_multiple curl ip dhclient
```

to:

```sh
    # Network tools
    inst_multiple curl ip dhclient

    # Archive tools for the home restore in restore_home(). GNU tar runs
    # gzip as a separate process for -z, so both are required.
    inst_multiple tar gzip
```

- [ ] **Step 2: Record the boot MAC when the interface comes up**

In `mount-squashfs.sh`, inside the netboot interface loop, replace:

```sh
        info "Bringing up interface $iface_name"
        ip link set "$iface_name" up
        dhclient -v "$iface_name" || true
        break
```

with:

```sh
        info "Bringing up interface $iface_name"
        ip link set "$iface_name" up
        dhclient -v "$iface_name" || true
        # Record which interface this actually was, so dbrrg-save-home posts
        # the home archive back under the same MAC restore_home fetched it
        # with. See dbrrg_record_boot_mac() for why both halves must not
        # derive it independently.
        dbrrg_record_boot_mac "/sys/class/net/$iface_name/address" \
            "$DBRRG_STATE" || true
        break
```

- [ ] **Step 3: Call `restore_home` from `setup-overlay.sh`**

In `setup-overlay.sh`, after the `info "Machine-id set: $machine_id"` line
and before `echo "$zram_dev" > "$DBRRG_STATE/zram-device"`, add:

```sh
# Restore the home directory here, in the initramfs, rather than at login.
#
# It has to be in place before multi-user.target so dbrrg-ssh-hostkeys can
# take the persistent SSH host keys out of it before sshd starts. Doing it
# at login - where it used to happen - is far too late for that.
#
# restore_home always returns 0; a client that cannot reach its home archive
# still boots with the shipped default home.
restore_home "$NEWROOT" "$DBRRG_STORAGE/efi" "$DBRRG_STATE" \
    "$(cat /tmp/dbrrg-ramroot 2>/dev/null)"
```

- [ ] **Step 4: Remove the restore from the login path**

Delete the script:

```bash
git rm overlay/usr/local/bin/dbrrg-restore-home
```

In `overlay/etc/profile.d/10-dbrrg-session.sh`, delete this block entirely
(the comment and the call):

```sh
    # Restore the home directory HERE, before the compositor starts - not from
    # inside the session as the X11 setup did.
    #
    # The reason is the user-controlled keyboard layout below. XKB_DEFAULT_*
    # is read by the compositor when it starts, so a user override has to be
    # on disk and sourced before that. Restoring home inside the session (the
    # obvious place, and where dbrrg-restore-home used to run) would make any
    # user keyboard setting take effect only on the NEXT boot.
    #
    # The user sees the plymouth splash during this, exactly as before; only
    # the ordering relative to the compositor changed.
    /usr/local/bin/dbrrg-restore-home >>"$DBRRG_SESSION_LOG" 2>&1 || true
```

and replace it with:

```sh
    # The home directory is ALREADY restored - the initramfs did it, in
    # restore_home() (dbrrg-lib.sh), before the pivot.
    #
    # Do not add a restore call here or in dbrrg-session. The constraint that
    # forced it out of dbrrg-session still stands: ~/.dbrrg-environment must
    # be on disk before labwc reads XKB_DEFAULT_* at startup, or a user's
    # keyboard change takes effect only on the NEXT boot. The initramfs
    # satisfies that; a restore at this point would merely re-satisfy it,
    # and a restore any later would break it.
```

- [ ] **Step 5: Update `test-session-packages.sh`**

Replace the line:

```bash
present "restore-home"     'usr/local/bin/dbrrg-restore-home$'
```

with:

```bash
absent  "restore-home script" 'usr/local/bin/dbrrg-restore-home$'
```

- [ ] **Step 6: Wire the new test into `make test`**

In `Makefile`, change the `test` target to:

```make
test: rootfs
	@test/integration/test-firmware.sh
	@test/integration/test-session-packages.sh
	@test/integration/test-labwc-config-merge.sh
	@test/integration/test-initramfs-home.sh
```

- [ ] **Step 7: Update CLAUDE.md**

In the **Boot Process** list under "Dracut Module", add a fifth bullet after
"machine-id Persistence":

```markdown
   - **Home Restore**: Restores `/home/tluser` from the boot medium
     (`home.tar.gz` on the EFI partition, or `home.pkg` from the boot server)
     before the pivot, so the home directory is in place before
     `multi-user.target`
```

In the **Home Persistence** section, replace:

```markdown
5. **Home Persistence** - `overlay/usr/local/bin/dbrrg-session` (run by labwc via `labwc -S`) restores the home directory at login (`dbrrg-restore-home`) and saves it on logout, after the ThinLinc client exits (`save-home`)
```

with:

```markdown
5. **Home Persistence** - the initramfs restores the home directory before
   the pivot (`restore_home()` in the dracut module); `dbrrg-session` saves
   it on logout, after the ThinLinc client exits (`dbrrg-save-home`)
```

In the **Persistent Home Directory** section, replace the "On boot" bullet
with:

```markdown
- On boot: the initramfs restores `/home/tluser` — from `home.tar.gz` on the
  EFI partition when booting from USB, or from `home.pkg` on the boot server
  when netbooting. This happens in `restore_home()`
  (`overlay/usr/lib/dracut/modules.d/90dbrrg/dbrrg-lib.sh`), called from
  `setup-overlay.sh`, **not** at login. It moved there so the SSH host keys
  stored inside the home directory are available before sshd starts.
  Netboot identifies the machine by the MAC recorded at
  `/run/dbrrg/state/boot-mac` — the interface the initramfs actually used —
  rather than by re-deriving it, so restore and save cannot disagree.
```

In the **.dbrrg-environment** subsection, replace the sentence beginning
"This is why `dbrrg-restore-home` runs in `10-dbrrg-session.sh`" with:

```markdown
  This is why the home restore happens in the **initramfs** rather than
  inside the session: a user's saved `.dbrrg-environment` has to be on disk
  before the compositor reads `XKB_DEFAULT_*`. Restoring home inside the
  session would make a user keyboard change take effect only on the *next*
  boot. Do not move the restore into `dbrrg-session`, and do not move it
  back into `10-dbrrg-session.sh` either — `dbrrg-ssh-hostkeys` now needs
  the home directory before `multi-user.target`.
```

- [ ] **Step 8: Verify the full build and boot**

```bash
make rootfs
make test
```

Expected: all four integration scripts pass.

```bash
make qemu-smoke
```

Expected: boot completes. The smoke log should contain the
`dbrrg: restoring home from` line from `restore_home`.

- [ ] **Step 9: Commit**

```bash
git add -A overlay/usr/lib/dracut/modules.d/90dbrrg/ \
        overlay/etc/profile.d/10-dbrrg-session.sh \
        overlay/usr/local/bin/dbrrg-restore-home \
        test/integration/test-session-packages.sh Makefile CLAUDE.md
git commit -m "feat: restore the home directory from the initramfs

Moves the restore out of /etc/profile.d/10-dbrrg-session.sh so /home/tluser
is populated before multi-user.target, which is what lets the SSH host keys
persist inside the home archive. dbrrg-restore-home is retired in favour of
restore_home() in the dracut module."
```

---

## Task 6: Persistent SSH host keys

**Gate:** requires Task 1 to have confirmed the ordering cycle. If it did
not, stop and re-diagnose.

**Files:**
- Create: `overlay/usr/bin/dbrrg-ssh-hostkeys`
- Create: `overlay/etc/systemd/system/dbrrg-ssh-hostkeys.service`
- Create: `test/integration/test-ssh-hostkeys.sh`
- Modify: `overlay/opt/thinlinc/bin/save-home`
- Modify: `containers/ubuntu/Dockerfile`
- Modify: `test/integration/test-session-packages.sh`, `Makefile`, `CLAUDE.md`
- Delete: `overlay/etc/systemd/system/regenerate_ssh_host_keys.service`

**Interfaces:**
- Consumes: `/run/dbrrg/state/boot-mac` (Task 5); a restored `/home/tluser` (Task 5).
- Produces: `/usr/bin/dbrrg-ssh-hostkeys`, invoked with no arguments (install-or-generate) or `--stage` (copy live keys into the keystore).

- [ ] **Step 1: Write the failing test**

Create `test/integration/test-ssh-hostkeys.sh`:

```bash
#!/bin/bash
# Offline tests for dbrrg-ssh-hostkeys.
#
# Host keys persist inside the home directory, which is already saved to the
# EFI partition or the boot server. That removes the need for a separate EFI
# file or a hostkeys.pkg endpoint, but it means the keys arrive tluser-owned
# and must be forced to root:root 0600 before sshd will use them - the exact
# opposite of the home restore, which must PRESERVE uid 1000.
#
# Runs without root: chown is stubbed and its invocations are recorded, so
# the ownership fix can be asserted without actually being able to perform
# it. Directory layout is redirected via DBRRG_SSH_DIR / DBRRG_HOME_DIR.
#
# Usage: test/integration/test-ssh-hostkeys.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/overlay/usr/bin/dbrrg-ssh-hostkeys"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# chown cannot work as an unprivileged user. Record the calls instead so the
# ownership fix is still assertable.
cat >"$STUBS/chown" <<'STUB'
#!/bin/bash
echo "chown $*" >>"$DBRRG_TEST_CHOWN_LOG"
exit 0
STUB
chmod +x "$STUBS/chown"

# ssh-keygen -A normally writes into /etc/ssh; honour DBRRG_SSH_DIR instead.
cat >"$STUBS/ssh-keygen" <<'STUB'
#!/bin/bash
echo "ssh-keygen $*" >>"$DBRRG_TEST_KEYGEN_LOG"
for t in rsa ecdsa ed25519; do
    echo "PRIVATE-$t" >"$DBRRG_SSH_DIR/ssh_host_${t}_key"
    echo "PUBLIC-$t"  >"$DBRRG_SSH_DIR/ssh_host_${t}_key.pub"
done
exit 0
STUB
chmod +x "$STUBS/ssh-keygen"

export PATH="$STUBS:$PATH"

# fresh_case <name> -> sets DBRRG_SSH_DIR, DBRRG_HOME_DIR, logs
fresh_case() {
    CASE="$WORK/$1"
    export DBRRG_SSH_DIR="$CASE/etc-ssh"
    export DBRRG_HOME_DIR="$CASE/home"
    export DBRRG_TEST_CHOWN_LOG="$CASE/chown.log"
    export DBRRG_TEST_KEYGEN_LOG="$CASE/keygen.log"
    mkdir -p "$DBRRG_SSH_DIR" "$DBRRG_HOME_DIR"
    : >"$DBRRG_TEST_CHOWN_LOG"
    : >"$DBRRG_TEST_KEYGEN_LOG"
}

# --- keys present in the home keystore -> installed into /etc/ssh --------

fresh_case restore
mkdir -p "$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys"
echo "PRIVATE-ed25519" >"$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key"
echo "PUBLIC-ed25519"  >"$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key.pub"
chmod 644 "$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key"

"$SCRIPT" >/dev/null 2>&1

if [[ -f "$DBRRG_SSH_DIR/ssh_host_ed25519_key" ]]; then
    ok "keystore keys are installed into the ssh dir"
else
    bad "keystore keys were not installed"
fi

if [[ ! -s "$DBRRG_TEST_KEYGEN_LOG" ]]; then
    ok "no regeneration when the keystore already has keys"
else
    bad "ssh-keygen ran even though the keystore had keys"
fi

# sshd refuses to start on a private key that is not 0600.
perm=$(stat -c %a "$DBRRG_SSH_DIR/ssh_host_ed25519_key")
if [[ "$perm" == "600" ]]; then
    ok "installed private key is chmod 600"
else
    bad "installed private key is $perm, expected 600 (it was 644 in the archive)"
fi

perm=$(stat -c %a "$DBRRG_SSH_DIR/ssh_host_ed25519_key.pub")
if [[ "$perm" == "644" ]]; then
    ok "installed public key is chmod 644"
else
    bad "installed public key is $perm, expected 644"
fi

if grep -q "chown root:root" "$DBRRG_TEST_CHOWN_LOG"; then
    ok "installed keys are chowned to root:root"
else
    bad "no chown to root:root - keys arrive tluser-owned and sshd will refuse them"
fi

# --- nothing anywhere -> generate, then stage into the keystore ----------

fresh_case generate
"$SCRIPT" >/dev/null 2>&1

if grep -q -- "-A" "$DBRRG_TEST_KEYGEN_LOG"; then
    ok "ssh-keygen -A runs when no keys exist anywhere"
else
    bad "ssh-keygen -A did not run with no keys present"
fi

if [[ -f "$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key" ]]; then
    ok "generated keys are staged into the home keystore"
else
    bad "generated keys were not staged into the keystore - they would not persist"
fi

if grep -q "chown -R tluser:tluser" "$DBRRG_TEST_CHOWN_LOG"; then
    ok "staged keystore is chowned back to tluser"
else
    bad "staged keystore not chowned to tluser - save-home could not read it"
fi

# --- keys already live, keystore empty -> do nothing ---------------------

fresh_case already
echo "EXISTING" >"$DBRRG_SSH_DIR/ssh_host_ed25519_key"
"$SCRIPT" >/dev/null 2>&1

if [[ "$(cat "$DBRRG_SSH_DIR/ssh_host_ed25519_key")" == "EXISTING" ]]; then
    ok "existing live keys are left untouched"
else
    bad "existing live keys were overwritten"
fi

if [[ ! -s "$DBRRG_TEST_KEYGEN_LOG" ]]; then
    ok "no regeneration when live keys already exist"
else
    bad "ssh-keygen ran despite live keys existing"
fi

# --- --stage copies live keys into the keystore --------------------------

fresh_case stage
echo "LIVE" >"$DBRRG_SSH_DIR/ssh_host_ed25519_key"
echo "LIVEPUB" >"$DBRRG_SSH_DIR/ssh_host_ed25519_key.pub"
"$SCRIPT" --stage >/dev/null 2>&1

if [[ "$(cat "$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key" 2>/dev/null)" == "LIVE" ]]; then
    ok "--stage copies the live keys into the keystore"
else
    bad "--stage did not copy the live keys into the keystore"
fi

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - SSH host key persistence"
    exit 1
fi

echo ""
echo "PASSED - SSH host key persistence"
exit 0
```

```bash
chmod +x test/integration/test-ssh-hostkeys.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-ssh-hostkeys.sh`
Expected: FAIL — `overlay/usr/bin/dbrrg-ssh-hostkeys not found or not executable`.

- [ ] **Step 3: Write the script**

Create `overlay/usr/bin/dbrrg-ssh-hostkeys`:

```sh
#!/bin/sh
# Install the machine's persistent SSH host keys, or generate them once.
#
# The root filesystem is a read-only squashfs with a ZRAM overlay, so
# /etc/ssh is writable but volatile: without this, keys are regenerated on
# every boot and every client reports a changed host key every time.
#
# The keys are persisted INSIDE the home directory, which is already saved
# to the EFI partition (USB) or the boot server (netboot) by
# dbrrg-save-home, and restored by the initramfs before the pivot. That is
# why this can run as an ordinary system service with no EFI mount, no
# network, and no server-side endpoint of its own.
#
# Ordering: the initramfs has already put ~tluser/.dbrrg-ssh-host-keys in
# place by the time this runs, and dbrrg-ssh-hostkeys.service is ordered
# Before=ssh.service.
#
# Usage:
#   dbrrg-ssh-hostkeys            install from the keystore, or generate
#   dbrrg-ssh-hostkeys --stage    copy the live keys into the keystore
#                                 (called by dbrrg-save-home before tarring)
#
# The DBRRG_* variables exist so test/integration/test-ssh-hostkeys.sh can
# redirect the layout; nothing in the image sets them.

set -u

SSH_DIR="${DBRRG_SSH_DIR:-/etc/ssh}"
HOME_DIR="${DBRRG_HOME_DIR:-/home/tluser}"
KEY_OWNER="${DBRRG_KEY_OWNER:-tluser}"
KEYSTORE="$HOME_DIR/.dbrrg-ssh-host-keys"

# has_keys <dir> - true if <dir> holds at least one private host key.
# An unmatched glob stays literal in POSIX sh, so the -e test is the check.
has_keys() {
    set -- "$1"/ssh_host_*_key
    [ -e "$1" ]
}

# Install the persisted keys over the volatile ones.
install_from_keystore() {
    has_keys "$KEYSTORE" || return 1

    cp -p "$KEYSTORE"/ssh_host_* "$SSH_DIR"/ 2>/dev/null || return 1

    # The keystore lives inside tluser's home, so these arrive owned by
    # tluser and carrying whatever mode the archive preserved. sshd refuses
    # to start on a host key that is not root-owned and 0600, so both are
    # forced here rather than trusted.
    #
    # NOTE: this is deliberately the OPPOSITE of the home restore in
    # dbrrg-lib.sh, which must PRESERVE uid 1000 (tar --same-owner). Same
    # archive, two different requirements. Do not "make them consistent".
    chown root:root "$SSH_DIR"/ssh_host_* 2>/dev/null || \
        echo "dbrrg-ssh-hostkeys: WARNING could not chown host keys" >&2
    chmod 600 "$SSH_DIR"/ssh_host_*_key 2>/dev/null || true
    chmod 644 "$SSH_DIR"/ssh_host_*_key.pub 2>/dev/null || true

    return 0
}

# Copy the live keys into the keystore so the next dbrrg-save-home run
# captures them in the home archive.
stage_to_keystore() {
    has_keys "$SSH_DIR" || {
        echo "dbrrg-ssh-hostkeys: no host keys in $SSH_DIR to stage" >&2
        return 1
    }

    mkdir -p "$KEYSTORE" 2>/dev/null || return 1
    cp -p "$SSH_DIR"/ssh_host_* "$KEYSTORE"/ 2>/dev/null || return 1

    # Must end up readable by tluser: dbrrg-save-home tars $HOME as tluser,
    # and a root-owned unreadable file would be silently dropped.
    chown -R "$KEY_OWNER:$KEY_OWNER" "$KEYSTORE" 2>/dev/null || \
        echo "dbrrg-ssh-hostkeys: WARNING could not chown $KEYSTORE" >&2
    chmod 700 "$KEYSTORE" 2>/dev/null || true
    chmod 600 "$KEYSTORE"/ssh_host_*_key 2>/dev/null || true

    return 0
}

case "${1:-}" in
    --stage)
        stage_to_keystore
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Usage: dbrrg-ssh-hostkeys [--stage]" >&2
        exit 1
        ;;
esac

if install_from_keystore; then
    echo "dbrrg-ssh-hostkeys: installed persistent host keys from $KEYSTORE"
    exit 0
fi

if has_keys "$SSH_DIR"; then
    echo "dbrrg-ssh-hostkeys: host keys already present in $SSH_DIR"
    exit 0
fi

# First boot of this machine, or a machine whose home was never saved.
echo "dbrrg-ssh-hostkeys: no persistent host keys, generating"
if ! ssh-keygen -A; then
    echo "dbrrg-ssh-hostkeys: ssh-keygen -A failed" >&2
    exit 1
fi

# Stage immediately so the keys are captured by the first dbrrg-save-home.
# Note they do not actually persist until that runs, at logout - a machine
# powered off before its first clean logout will generate fresh keys again
# next boot. Accepted; see the design spec.
stage_to_keystore || \
    echo "dbrrg-ssh-hostkeys: WARNING could not stage keys into $KEYSTORE" >&2

exit 0
```

```bash
chmod +x overlay/usr/bin/dbrrg-ssh-hostkeys
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `test/integration/test-ssh-hostkeys.sh`
Expected: PASS, 11 `ok` lines.

- [ ] **Step 5: Add the systemd unit**

Create `overlay/etc/systemd/system/dbrrg-ssh-hostkeys.service`:

```ini
[Unit]
Description=Install or generate persistent SSH host keys
# The keys come out of /home/tluser, which the initramfs restored before the
# pivot - so there is nothing to wait for here beyond the filesystem.
After=local-fs.target
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/dbrrg-ssh-hostkeys
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
# last line
```

Note there is deliberately no `Before=ssh.socket`: the socket is masked in
the Dockerfile. Ordering before both is what produced the cycle this fixes —
`ssh.socket` is ordered before `sockets.target`, which precedes
`basic.target`, which a `DefaultDependencies=yes` unit is ordered after.

- [ ] **Step 6: Delete the old unit**

```bash
git rm overlay/etc/systemd/system/regenerate_ssh_host_keys.service
```

- [ ] **Step 7: Update the Dockerfile**

In `containers/ubuntu/Dockerfile`, replace:

```dockerfile
RUN rm -f /etc/ssh/ssh_host_*_key* && \
    systemctl enable regenerate_ssh_host_keys || true && \
    systemctl enable ssh.service || true && \
```

with:

```dockerfile
# ssh.socket is masked on purpose. sshd had two entry points with different
# ordering - the socket from sockets.target and the service from
# multi-user.target - and the host key unit had to be ordered before both.
# Since a DefaultDependencies=yes unit is implicitly ordered after
# basic.target, and basic.target comes after sockets.target and therefore
# after ssh.socket, "Before=ssh.socket" made the unit both before and after
# the same target. systemd breaks such a cycle by deleting a job, which left
# the machine with either no host keys or no listening socket. One entry
# point removes the cycle. Do not re-enable it.
RUN rm -f /etc/ssh/ssh_host_*_key* && \
    systemctl mask ssh.socket || true && \
    systemctl enable dbrrg-ssh-hostkeys.service || true && \
    systemctl enable ssh.service || true && \
```

- [ ] **Step 8: Stage the keys from `dbrrg-save-home`, and use the recorded MAC and base path**

In `overlay/opt/thinlinc/bin/save-home`, replace the `BASE_PATH=` line:

```sh
BASE_PATH=$(cat /proc/cmdline | sed -n 's/.*ramroot=\(.*\)\/.*$/\1/p')
```

with:

```sh
# Prefer the base the initramfs actually built the fetch URL from.
#
# The sed below is kept only as a fallback, and it is wrong in a way worth
# naming: the greedy .* backtracks to the LAST slash anywhere in
# /proc/cmdline, so any kernel parameter appearing after ramroot= that
# contains a "/" - root=/dev/sda1, init=/sbin/init - yields a base with that
# parameter's text glued on. Today's configs/syslinux.cfg has no such
# parameter after ramroot=, so this has never fired, but adding one would
# silently orphan every netboot client's home. Reading the recorded value
# removes the whole class.
BASE_PATH=$(cat /run/dbrrg/state/boot-home-base 2>/dev/null)
if [ -z "$BASE_PATH" ]; then
  BASE_PATH=$(cat /proc/cmdline | sed -n 's/.*ramroot=\(.*\)\/.*$/\1/p')
fi
```

Then replace the `MAC_ADDR=` line:

```sh
MAC_ADDR=$(cat /sys/class/net/$(ip  addr show  | sed -n 's/^2: *\([^: ]*\).*$/\1/p')/address)
```

with:

```sh
# Prefer the MAC the initramfs actually used to fetch this machine's home.
# Re-deriving it here (kernel ifindex 2) agreed with the restore only while
# both ran in the booted system; the restore now runs in the initramfs,
# which loads a smaller driver set and can therefore see a different ifindex
# order. Posting the archive under a different MAC than it was fetched with
# would silently orphan it. The old expression stays as a fallback for a
# boot where nothing was recorded.
MAC_ADDR=$(cat /run/dbrrg/state/boot-mac 2>/dev/null)
if [ -z "$MAC_ADDR" ]; then
  MAC_ADDR=$(cat /sys/class/net/$(ip  addr show  | sed -n 's/^2: *\([^: ]*\).*$/\1/p')/address)
fi
```

Then, immediately after the `cd $HOME` line, add:

```sh
# Capture the live SSH host keys into the home directory so they travel with
# the archive. This is the ONLY place they are persisted - see
# /usr/bin/dbrrg-ssh-hostkeys and CLAUDE.md.
sudo /usr/bin/dbrrg-ssh-hostkeys --stage || true
```

- [ ] **Step 9: Extend `test-session-packages.sh`**

Add these three to the existing `present`/`absent` block near the top:

```bash
present "ssh host key helper" 'usr/bin/dbrrg-ssh-hostkeys$'
present "ssh host key unit"   'dbrrg-ssh-hostkeys\.service$'
absent  "old regenerate unit" 'regenerate_ssh_host_keys\.service$'
```

Add the mask check at the **end** of the file, immediately before the final
`if [[ $fail -ne 0 ]]` block. It must go there, not with the block above:
`$DPKG_TMP` is not created until partway down the file, and referencing it
earlier would expand to an empty path and silently write into `/`.

```bash
# ssh.socket must stay masked: two entry points into sshd with different
# ordering is what produced the ordering cycle that stopped it starting.
if unsquashfs -no-xattrs -d "$DPKG_TMP/ssh" "$SQSH" \
        etc/systemd/system/ssh.socket >/dev/null 2>&1 &&
   [[ -L "$DPKG_TMP/ssh/etc/systemd/system/ssh.socket" ]] &&
   [[ "$(readlink "$DPKG_TMP/ssh/etc/systemd/system/ssh.socket")" == "/dev/null" ]]; then
    echo "ok   - ssh.socket is masked"
else
    echo "FAIL - ssh.socket is not masked (see CLAUDE.md on the ordering cycle)"
    fail=1
fi
```

- [ ] **Step 10: Wire the new test into `make test`**

```make
test: rootfs
	@test/integration/test-firmware.sh
	@test/integration/test-session-packages.sh
	@test/integration/test-labwc-config-merge.sh
	@test/integration/test-initramfs-home.sh
	@test/integration/test-ssh-hostkeys.sh
```

- [ ] **Step 11: Update CLAUDE.md**

Add to **Container Build Best Practices**, replacing item 1:

```markdown
1. **SSH Host Keys**: Host keys are removed at build time. On first boot
   `dbrrg-ssh-hostkeys.service` generates them and stages them into
   `~tluser/.dbrrg-ssh-host-keys`, from where `dbrrg-save-home` captures them
   into the home archive at logout; the initramfs restores them on every
   subsequent boot. `ssh.socket` is **masked** — see Standing Constraints.
   Keys do not persist until the first clean logout: a machine hard-powered
   off before then generates fresh keys next boot.
```

Add a new **Standing Constraints** subsection after "labwc must have zero
keybindings":

```markdown
### ssh.socket must stay masked

`containers/ubuntu/Dockerfile` runs `systemctl mask ssh.socket` and enables
`ssh.service` alone. Re-enabling the socket reintroduces an ordering cycle.

`dbrrg-ssh-hostkeys.service` must run before sshd. With the socket active,
sshd has two entry points with different ordering — the socket from
`sockets.target`, the service from `multi-user.target` — so the key unit had
to be ordered `Before=ssh.socket`. But a `DefaultDependencies=yes` unit is
implicitly ordered `After=basic.target`, and `basic.target` comes after
`sockets.target`, which comes after `ssh.socket`. Before and after the same
unit is a cycle, and systemd resolves a cycle by deleting a job: the machine
came up with either no host keys or no listening socket.

`test/integration/test-session-packages.sh` guards this — run via `make test`.
```

- [ ] **Step 12: Build and verify**

```bash
make rootfs
make test
```

Expected: all five integration scripts pass.

- [ ] **Step 13: Commit**

```bash
git add -A overlay/usr/bin/dbrrg-ssh-hostkeys \
        overlay/etc/systemd/system/ \
        overlay/opt/thinlinc/bin/save-home \
        containers/ubuntu/Dockerfile \
        test/integration/test-ssh-hostkeys.sh \
        test/integration/test-session-packages.sh Makefile CLAUDE.md
git commit -m "fix: persist SSH host keys in the home directory

sshd did not start because regenerate_ssh_host_keys.service was ordered both
before and after ssh.socket, and systemd broke the cycle by deleting a job.
Masking ssh.socket leaves sshd one entry point, and the new
dbrrg-ssh-hostkeys.service takes the keys from the home directory the
initramfs already restored - so they survive reboots without a second
persistence mechanism."
```

- [ ] **Step 14: Confirm on hardware**

Boot the image twice with a clean logout in between:

```bash
ssh-keyscan <client-ip>        # after first boot + logout
# reboot the client
ssh-keyscan <client-ip>        # must return the same key
systemctl status dbrrg-ssh-hostkeys.service ssh.service
journalctl -b | grep -i "ordering cycle"    # must be empty
```

Record the result in the spec's "Hardware confirmation required" section and
commit.

---

## Task 7: Consolidate scripts under `/usr/bin`

**Files:**
- Rename: `overlay/opt/thinlinc/bin/save-home` → `overlay/usr/bin/dbrrg-save-home`
- Rename: `overlay/usr/local/bin/dbrrg-session` → `overlay/usr/bin/dbrrg-session`
- Rename: `overlay/usr/local/bin/dbrrg-compose-labwc-config` → `overlay/usr/bin/dbrrg-compose-labwc-config`
- Modify: `overlay/etc/profile.d/10-dbrrg-session.sh`, `test/integration/test-labwc-config-merge.sh`, `test/integration/test-session-packages.sh`, `CLAUDE.md`

**Interfaces:**
- Consumes: `dbrrg-save-home` gained a `--stage` call in Task 6; carry it across unchanged.
- Produces: final script paths used by Task 9.

- [ ] **Step 1: Check nothing outside this repo calls the old path**

`save-home` sits in a ThinLinc-owned directory and is named as though
ThinLinc provided it. Confirm ThinLinc does not invoke it by name before
deleting the path:

```bash
make rootfs
mkdir -p /tmp/claude-1003/tl && unsquashfs -q -f -d /tmp/claude-1003/tl \
    artifacts/rootfs/ramroot.sqsh 'opt/thinlinc/*'
grep -rl "save-home" /tmp/claude-1003/tl/opt/thinlinc/ || echo "no ThinLinc references"
```

Expected: `no ThinLinc references`. If ThinLinc *does* reference it, stop and
leave a wrapper at the old path instead of deleting it.

- [ ] **Step 2: Move the files**

```bash
mkdir -p overlay/usr/bin
git mv overlay/opt/thinlinc/bin/save-home overlay/usr/bin/dbrrg-save-home
git mv overlay/usr/local/bin/dbrrg-session overlay/usr/bin/dbrrg-session
git mv overlay/usr/local/bin/dbrrg-compose-labwc-config \
       overlay/usr/bin/dbrrg-compose-labwc-config
rmdir overlay/opt/thinlinc/bin overlay/opt/thinlinc overlay/opt \
      overlay/usr/local/bin overlay/usr/local 2>/dev/null || true
```

- [ ] **Step 3: Update the references**

In `overlay/usr/bin/dbrrg-session`, replace:

```sh
/opt/thinlinc/bin/save-home
```

with:

```sh
/usr/bin/dbrrg-save-home
```

In `overlay/etc/profile.d/10-dbrrg-session.sh`, replace all three
occurrences of `/usr/local/bin/`:

- `/usr/local/bin/dbrrg-compose-labwc-config` → `/usr/bin/dbrrg-compose-labwc-config`
- `labwc -C "$LABWC_CONFIG_DIR" -S /usr/local/bin/dbrrg-session` → `... -S /usr/bin/dbrrg-session`
- the `Retry byhand:` echo line, same substitution

In `test/integration/test-labwc-config-merge.sh`, replace:

```bash
HELPER="$(cd "$(dirname "$0")/../.." && pwd)/overlay/usr/local/bin/dbrrg-compose-labwc-config"
```

with:

```bash
HELPER="$(cd "$(dirname "$0")/../.." && pwd)/overlay/usr/bin/dbrrg-compose-labwc-config"
```

- [ ] **Step 4: Verify no stale references remain**

```bash
grep -rn "usr/local/bin/dbrrg\|opt/thinlinc/bin/save-home" \
    --exclude-dir=.git --exclude-dir=docs . || echo "clean"
```

Expected: `clean`. (`docs/` is excluded — the spec quotes the old paths
historically and should keep doing so.)

- [ ] **Step 5: Update `test-session-packages.sh`**

Replace:

```bash
present "session script"   'usr/local/bin/dbrrg-session$'
absent  "restore-home script" 'usr/local/bin/dbrrg-restore-home$'
```

with:

```bash
present "session script"    'usr/bin/dbrrg-session$'
present "save-home"         'usr/bin/dbrrg-save-home$'
present "labwc config merge" 'usr/bin/dbrrg-compose-labwc-config$'
absent  "restore-home script" 'usr/local/bin/dbrrg-restore-home$'
absent  "old save-home path"  'opt/thinlinc/bin/save-home$'
```

- [ ] **Step 6: Update CLAUDE.md**

Replace every occurrence of `overlay/usr/local/bin/` with `overlay/usr/bin/`
and `/opt/thinlinc/bin/save-home` with `/usr/bin/dbrrg-save-home`. Affected
sections: Boot Flow Architecture item 5, Customizing the System
("Session startup"), and Persistent Home Directory.

- [ ] **Step 7: Build and test**

```bash
make rootfs
make test
```

Expected: all five scripts pass.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: consolidate dbrrg scripts under /usr/bin

save-home lived in /opt/thinlinc/bin, a ThinLinc-owned directory, named as
though ThinLinc shipped it; its counterparts were in /usr/local/bin. One
directory, one dbrrg- prefix."
```

---

## Task 8: Screenshot tooling

**Files:**
- Modify: `containers/ubuntu/Dockerfile`, `test/integration/test-session-packages.sh`, `CLAUDE.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `grim`, `slurp`, `wl-copy` in the image.

- [ ] **Step 1: Add the failing assertion**

In `test/integration/test-session-packages.sh`, add next to the other
`present` calls:

```bash
present "grim"             'usr/bin/grim$'
present "slurp"            'usr/bin/slurp$'
present "wl-copy"          'usr/bin/wl-copy$'
```

- [ ] **Step 2: Run to verify it fails**

```bash
test/integration/test-session-packages.sh
```

Expected: FAIL — `grim missing`, `slurp missing`, `wl-copy missing`.

- [ ] **Step 3: Add the packages**

In `containers/ubuntu/Dockerfile`, in the main `apt-get install` list, after
the `foot-terminfo \` line:

```dockerfile
    grim \
    slurp \
    wl-clipboard \
```

- [ ] **Step 4: Rebuild and verify it passes**

```bash
make rootfs
test/integration/test-session-packages.sh
```

Expected: PASS.

- [ ] **Step 5: Document the invocation**

In CLAUDE.md's **Debugging** section, after the existing `foot` block:

```markdown
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
```

- [ ] **Step 6: Commit**

```bash
git add containers/ubuntu/Dockerfile test/integration/test-session-packages.sh CLAUDE.md
git commit -m "feat: ship grim, slurp and wl-clipboard for screenshots"
```

---

## Task 9: waybar taskbar for minimized windows

**Files:**
- Create: `overlay/etc/dbrrg/waybar/config.jsonc`, `overlay/etc/dbrrg/waybar/style.css`
- Modify: `containers/ubuntu/Dockerfile`, `overlay/usr/bin/dbrrg-session`, `test/integration/test-session-packages.sh`, `CLAUDE.md`

**Interfaces:**
- Consumes: `overlay/usr/bin/dbrrg-session` at its post-Task-7 path.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Add the failing assertions**

In `test/integration/test-session-packages.sh`, add these three to the
`present`/`absent` block near the top:

```bash
present "waybar"           'usr/bin/waybar$'
present "waybar config"    'etc/dbrrg/waybar/config\.jsonc$'
present "waybar style"     'etc/dbrrg/waybar/style\.css$'
```

Add the two content checks at the **end** of the file, before the final
`if [[ $fail -ne 0 ]]` block — they use `$DPKG_TMP`, which is not created
until partway down the file:

```bash
# The taskbar is the ONLY way back to a minimized window: labwc draws an
# iconify button, and with zero keybindings and no menu there is no other
# route. If the config ever loses the taskbar module, minimized windows
# become unreachable again.
if unsquashfs -no-xattrs -d "$DPKG_TMP/wb" "$SQSH" \
        etc/dbrrg/waybar/config.jsonc >/dev/null 2>&1 &&
   grep -q 'wlr/taskbar' "$DPKG_TMP/wb/etc/dbrrg/waybar/config.jsonc"; then
    echo "ok   - waybar config declares the wlr/taskbar module"
else
    echo "FAIL - waybar config has no wlr/taskbar module"
    fail=1
fi

# dbrrg-session must both start waybar and kill it: labwc terminates when
# its -S command returns, and a surviving waybar would be orphaned.
if unsquashfs -no-xattrs -d "$DPKG_TMP/sess" "$SQSH" \
        usr/bin/dbrrg-session >/dev/null 2>&1 &&
   grep -q 'waybar' "$DPKG_TMP/sess/usr/bin/dbrrg-session" &&
   grep -q 'trap .*kill' "$DPKG_TMP/sess/usr/bin/dbrrg-session"; then
    echo "ok   - dbrrg-session starts waybar and kills it on exit"
else
    echo "FAIL - dbrrg-session does not start and clean up waybar"
    fail=1
fi
```

- [ ] **Step 2: Run to verify it fails**

```bash
test/integration/test-session-packages.sh
```

Expected: FAIL — waybar missing, config missing, no taskbar module.

- [ ] **Step 3: Add the package**

In `containers/ubuntu/Dockerfile`, after the `wlr-randr \` line:

```dockerfile
    waybar \
```

- [ ] **Step 4: Write the config**

Create `overlay/etc/dbrrg/waybar/config.jsonc`:

```jsonc
// dbrrg taskbar.
//
// This exists for exactly one reason: labwc draws an iconify button on its
// server-side decorations, and with zero keybindings and no root menu a
// minimized window is otherwise unreachable for the rest of the session.
// Clicking its entry here brings it back.
//
// Deliberately minimal - no clock, tray or workspaces. This is a recovery
// affordance on a kiosk, not a desktop panel.
//
// It lives in /etc/dbrrg, NOT under $HOME: the home directory is captured
// wholesale by dbrrg-save-home and restored wholesale by the initramfs, so
// a config file in $HOME would be pinned forever on an already-deployed
// machine and a corrected file in a later image would never reach it. Same
// reasoning as /etc/dbrrg/labwc/rc.xml.
//
// Known behaviour: a fullscreen ThinLinc client COVERS this bar. wlroots
// places fullscreen surfaces above the layer-shell top layer and ignores
// exclusive zones. That is fine - the bar is visible exactly when no window
// is fullscreen, which is when a window can go missing. Not a
// misconfiguration; do not "fix" it.
{
    "layer": "top",
    "position": "bottom",
    "height": 32,
    "modules-left": ["wlr/taskbar"],
    "modules-center": [],
    "modules-right": [],
    "wlr/taskbar": {
        "all-outputs": true,
        "format": "{icon} {title:.40}",
        "icon-size": 20,
        "tooltip-format": "{title}",
        "on-click": "activate",
        "on-click-middle": "close"
    }
}
```

Create `overlay/etc/dbrrg/waybar/style.css`:

```css
/* dbrrg taskbar styling - see config.jsonc for why this bar exists. */

* {
    font-family: "DejaVu Sans", sans-serif;
    font-size: 13px;
    border: none;
    border-radius: 0;
}

window#waybar {
    background: #1c1c1c;
    color: #e0e0e0;
}

#taskbar button {
    padding: 0 12px;
    margin: 2px;
    background: #2a2a2a;
    color: #e0e0e0;
}

#taskbar button.active {
    background: #3d5a80;
}

#taskbar button:hover {
    background: #4a4a4a;
}
```

- [ ] **Step 5: Launch waybar from the session**

In `overlay/usr/bin/dbrrg-session`, replace:

```sh
/opt/thinlinc/bin/tlclient
/usr/bin/dbrrg-save-home
```

(post-Task-7 the first line reads `/opt/thinlinc/bin/tlclient` and the
second `/usr/bin/dbrrg-save-home`) with:

```sh
# The taskbar. Without it a window minimized via labwc's iconify button is
# gone for the rest of the session - there are no keybindings and no menu to
# get it back. See /etc/dbrrg/waybar/config.jsonc.
#
# It must die with the session: labwc terminates when this script returns,
# and an orphaned waybar would linger against the next session's compositor.
if command -v waybar >/dev/null 2>&1; then
    waybar -c /etc/dbrrg/waybar/config.jsonc \
           -s /etc/dbrrg/waybar/style.css &
    WAYBAR_PID=$!
    trap 'kill "$WAYBAR_PID" 2>/dev/null' EXIT INT TERM
fi

/opt/thinlinc/bin/tlclient
/usr/bin/dbrrg-save-home
```

- [ ] **Step 6: Rebuild and verify the tests pass**

```bash
make rootfs
make test
```

Expected: all five scripts pass.

- [ ] **Step 7: Verify the taskbar in the runtime rig**

```bash
make test-runtime
```

Expected: still passes — this task adds no labwc config change, so the
zero-keybindings and grab assertions are unaffected.

- [ ] **Step 8: Document it**

In CLAUDE.md's **Customizing the System** list, after the
"Session/compositor" bullet:

```markdown
- Taskbar: `overlay/etc/dbrrg/waybar/` (`config.jsonc`, `style.css`) - a
  single `wlr/taskbar` module, launched by `dbrrg-session`. It exists
  because labwc draws an iconify button and, with zero keybindings and no
  menu, a minimized window would otherwise be unreachable for the rest of
  the session. Kept outside `$HOME` for the same reason `rc.xml` is.
  Note a fullscreen ThinLinc client covers the bar - wlroots puts
  fullscreen surfaces above the layer-shell top layer and ignores exclusive
  zones - so it is visible exactly when no window is fullscreen, which is
  when a window can go missing.
```

- [ ] **Step 9: Commit**

```bash
git add -A overlay/etc/dbrrg/waybar/ overlay/usr/bin/dbrrg-session \
        containers/ubuntu/Dockerfile \
        test/integration/test-session-packages.sh CLAUDE.md
git commit -m "feat: add a waybar taskbar so minimized windows are recoverable"
```

---

## Task 10: Full-image verification

**Files:** none (verification only, plus a spec update).

- [ ] **Step 1: Clean build**

```bash
make clean
make image
```

- [ ] **Step 2: Full test suite**

```bash
make test
make test-runtime
make qemu-smoke
```

Expected: all green.

- [ ] **Step 3: Hardware pass**

On a real client, USB boot:

1. First boot → log in → set something in `~/.dbrrg-environment` → log out
2. `ssh tluser@<ip>` — record the host key fingerprint
3. Reboot → confirm the same fingerprint, and the `.dbrrg-environment`
   setting still in effect
4. Minimize a ThinLinc dialog → confirm it appears in the taskbar and
   restores on click
5. `XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 grim /tmp/s.png`
   over SSH → confirm a valid PNG

- [ ] **Step 4: Record what hardware actually confirmed**

Update the spec's "Hardware confirmation required" section with what was
observed — and, importantly, what was *not*. Follow the precedent set by
commit `4ba6aa7` ("docs: record what the hardware test actually confirmed"):
claim only what was seen.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-12-four-defects-design.md
git commit -m "docs: record hardware verification of the four defect fixes"
```

---

## Self-Review Notes

**Spec coverage:** every section of the design maps to a task — (a) Task 8,
(b) Task 9, (c) Task 7, (d) Tasks 1–6, testing folded into each, docs folded
into each, full verification Task 10.

**Two things this plan adds that the spec did not call out:**

1. **`tar` and `gzip` must be installed into the initramfs** (Task 5, Step 1).
   `module-setup.sh` installs no archiver today, so `restore_home` would
   fail at runtime while every offline test passed — the tests run on a host
   that has `tar`. This is the single most likely way to ship this feature
   broken.
2. **`dbrrg-save-home` needs the `boot-mac` fallback** (Task 6, Step 8) for
   the first boot after upgrading an already-deployed machine, where the
   initramfs recorded nothing because the old image had no such code.

**Deliberate ordering:** Task 1 gates only Task 6. Tasks 2–5 and 7–9 can
proceed even if the ordering-cycle diagnosis turns out wrong.

---

## Task 11: Remove the un-dockerize / systemd-hwdb-update ordering cycle

Added 2026-08-12, after the Task 1 QEMU boot surfaced a second ordering cycle
alongside the one being fixed in Task 6. See the design spec's section
"e) A second ordering cycle skips systemd-hwdb-update every boot".

**Files:**
- Modify: `overlay/etc/systemd/system/un-dockerize.service`
- Modify: `test/integration/test-session-packages.sh`
- Modify: `scripts/check-boot-smoke.sh`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Reproduce the cycle in the current smoke log**

```bash
grep -a "ordering cycle" artifacts/images/qemu-smoke.log | sed 's/\x1b\[[0-9;:]*m//g'
```

Expected: a line naming `systemd-hwdb-update.service` after
`un-dockerize.service` after `basic.target` after `sysinit.target`.

- [ ] **Step 2: Establish whether hwdb.bin ships prebuilt**

This decides the fix and must be checked, not assumed:

```bash
unsquashfs -l artifacts/rootfs/ramroot.sqsh | grep -E 'hwdb\.bin$'
```

Record the actual output in the report. If `usr/lib/udev/hwdb.bin` is
present, take branch A below; if only `etc/udev/hwdb.bin` or nothing is
present, take branch B.

- [ ] **Step 3: Remove the cycle**

In `overlay/etc/systemd/system/un-dockerize.service`, delete the line:

```ini
Before=systemd-hwdb-update.service
```

and replace it with a comment recording why it is absent:

```ini
# Deliberately NO Before=systemd-hwdb-update.service. That unit belongs to
# sysinit.target, while this one is WantedBy=multi-user.target and so is
# implicitly ordered After=basic.target -> After=sysinit.target. Declaring
# Before= on it made this unit both before and after the same target, and
# systemd broke the resulting cycle by deleting the hwdb update job on every
# single boot. Nothing this service does - resolv.conf, /etc/hosts,
# systemd-resolved - relates to the hardware database; the ordering was
# vestigial, left over from the depmod/modprobe lines commented out below.
```

- [ ] **Step 4 (branch A only): mask the unit if hwdb.bin ships prebuilt**

Only if Step 2 found `usr/lib/udev/hwdb.bin`. In
`containers/ubuntu/Dockerfile`, alongside the other `systemctl mask` calls:

```dockerfile
    systemctl mask systemd-hwdb-update.service || true && \
```

with a comment stating that the package ships a prebuilt `hwdb.bin` and that
regenerating it at boot would write megabytes into the ZRAM overlay for no
benefit. If Step 2 took branch B, skip this step entirely and note in the
report that the unit now runs at boot where it previously never did.

- [ ] **Step 5: Guard it**

In `test/integration/test-session-packages.sh`, before the final
`if [[ $fail -ne 0 ]]` block:

```bash
# un-dockerize.service must not be ordered before a sysinit unit - that made
# systemd delete the hwdb update job on every boot. See CLAUDE.md.
if unsquashfs -no-xattrs -d "$DPKG_TMP/ud" "$SQSH" \
        etc/systemd/system/un-dockerize.service >/dev/null 2>&1; then
    if grep -q '^Before=systemd-hwdb-update' \
            "$DPKG_TMP/ud/etc/systemd/system/un-dockerize.service"; then
        echo "FAIL - un-dockerize.service reintroduces the hwdb ordering cycle"
        fail=1
    else
        echo "ok   - un-dockerize.service has no hwdb ordering cycle"
    fi
else
    echo "FAIL - could not extract un-dockerize.service"
    fail=1
fi
```

In `scripts/check-boot-smoke.sh`, alongside the other `unwant` calls:

```bash
unwant "no systemd ordering cycle" 'Found ordering cycle'
```

This is the assertion that would have caught both cycles years ago. Expect it
to fail until Task 6 has also landed, since that removes the other one — run
this task after Task 6, or accept a known-failing smoke assertion until then.

- [ ] **Step 6: Rebuild and verify both cycles are gone**

```bash
make OXULNK_DEB=<path> rootfs
make OXULNK_DEB=<path> qemu-smoke
grep -a "ordering cycle" artifacts/images/qemu-smoke.log | sed 's/\x1b\[[0-9;:]*m//g'
```

Expected: no output from the grep, and `check-boot-smoke.sh` passes including
the new assertion.

- [ ] **Step 7: Document**

In CLAUDE.md's Standing Constraints, extend the `ssh.socket` subsection (added
in Task 6) to cover this second instance, or add a short sibling subsection:
a unit wanted by `multi-user.target` must never declare `Before=` a
`sysinit.target` unit, with both real examples named.

- [ ] **Step 8: Commit**

```bash
git add overlay/etc/systemd/system/un-dockerize.service \
        containers/ubuntu/Dockerfile \
        test/integration/test-session-packages.sh \
        scripts/check-boot-smoke.sh CLAUDE.md
git commit -m "fix: remove the un-dockerize/hwdb ordering cycle

un-dockerize.service is WantedBy=multi-user.target and so implicitly ordered
after sysinit.target, but declared Before=systemd-hwdb-update.service, which
belongs to sysinit.target. systemd broke the cycle by deleting the hwdb
update job on every boot. The smoke test now fails on any ordering cycle."
```
