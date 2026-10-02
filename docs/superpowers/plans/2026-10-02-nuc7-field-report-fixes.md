# NUC7i3BNK Field Report Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A NUC7i3BNK boots to a working graphical session with WiFi and
WireGuard up, and a logout saves a small, atomic home archive to the stick the
machine actually booted from.

**Architecture:** Five independent fixes, ordered by how badly they hurt. A new
oneshot waits for a real KMS driver before autologin, closing the race that
leaves tty1 at a failure shell. A second new oneshot installs per-machine
netplan and WireGuard config from the restored home before the netplan
generator runs, so the network no longer depends on the graphical session
starting. `dbrrg-save-home` gains an exclude list, an atomic write, and writes
to the ESP mount the initramfs already left in place. The session script
retries once on a GPU failure. The hostname stops being the build container's
ID.

**Tech Stack:** POSIX shell, systemd units, bash for the offline tests. No new
package: `wireguard`, `netplan.io` and `udevadm wait` are already in the image
(verified 2026-10-02 against `localhost/dbrrg-ubuntu:3.0.0`).

**Spec:** `docs/reports/2026-10-01-nuc7i3bnk-first-boot.md` — the field report,
with a verification table confirming every claim against the source tree. It
is the authority for this plan. `docs/superpowers/specs/2026-10-01-tile-menu-design.md`
remains the authority for the save-home exit codes, which Task 4 implements
because it is already rewriting that script.

## Global Constraints

- **Read `CLAUDE.md` "Standing Constraints" before touching any unit file.**
  There are eight. Two of them exist because this repo has **already shipped
  two ordering-cycle bugs**, and this plan adds two new units.
- **A unit that is `WantedBy=multi-user.target` must never declare `Before=`
  on a unit in `sysinit.target`.** Such a unit is implicitly ordered
  `After=basic.target`, which is after `sysinit.target`, so the `Before=`
  creates a cycle and systemd silently deletes a job on every boot. Both new
  units in this plan therefore use `DefaultDependencies=no` with explicit
  ordering, and `dbrrg-local-network.service` is `WantedBy=sysinit.target`,
  matching `netplan-configure.service`'s own shape.
- **`scripts/check-boot-smoke.sh` fails the smoke test on any
  `Found ordering cycle` line.** It is the gate for the constraint above. Run
  `make qemu-smoke` after every unit change.
- **Never resolve a user path from `$HOME`, `~` or `SUDO_USER`.** Use
  `getent passwd tluser | cut -d: -f6`. `sudo` on this image sets `HOME=/root`.
- **Every read of a file under `/run/dbrrg/state` ends in `|| true`.** `set -e`
  ends a script on `X=$(cat missing)`.
- **`/etc` is a RAM overlay reset on every boot.** Anything written there must
  be written on every boot, not once. This is why `un-dockerize.service`'s own
  `systemctl disable` of itself does not stick, and why it is the right place
  for a per-boot fix.
- **The boot ESP is mounted read-write at `/run/dbrrg/storage/efi` and stays
  mounted.** `mount-squashfs.sh:71` mounts it; `dbrrg-cleanup.sh` says in a
  comment not to unmount it. Do not mount
  `/dev/disk/by-partlabel/EFI-SYSTEM` a second time — every dbrrg stick
  carries that label, so with two sticks plugged in it can resolve to the
  wrong one.
- **Tests run unprivileged and offline.** `mount`, `umount`, `dd`, `sudo`,
  `curl`, `systemctl`, `install` and `netplan` are stubbed on `PATH`. `tar` and
  `gzip` are real.
- `dbrrg-save-home` exit codes, used verbatim by the later tile-menu plan:

  | code | meaning | kind |
  | --- | --- | --- |
  | `0` | home saved | success |
  | `1` | the resolved home directory is missing or is not a directory | refusal |
  | `2` | this boot's home restore failed | refusal |
  | `3` | the boot server is unreachable | refusal |
  | `4` | this machine has no known place to store a home | refusal |
  | `5` | the save was attempted and failed | failure |

- Exact values: idle/wait timeout `20` seconds for the KMS wait, polled every
  `0.2` s; netplan files installed `0600 root:root`; `/etc/wireguard` created
  `0700`; the exclude file is `~/.save-home-exclude` falling back to
  `/etc/dbrrg/save-home-exclude`, one `tar --exclude` pattern per line.

## Review Focus

Five conditions the report does not mention that this plan's code will meet.

- **A machine with no GPU at all, or only simpledrm** (a VM, serial console).
  The KMS wait must time out and let the login proceed, not block the boot
  forever. A thin client that never reaches a login because it has no Intel GPU
  is a worse bug than the one being fixed. → Task 1.
- **`~/wifi.yaml` exists but is malformed.** `netplan-configure` runs with
  `NETPLAN_PARSER_IGNORE_ERRORS=1`, so a broken file may be skipped silently —
  but a file installed with the wrong owner makes netplan refuse it with
  "Permissions for … are too open", which is exactly the shipped bug in §3.
  Expected: installed `0600 root:root` every time, and a malformed file does
  not stop the unit from installing the WireGuard half. → Task 2.
- **The home directory was never restored** (first boot, or a restore that
  failed). `/home/tluser/wifi.yaml` does not exist and the unit must succeed
  quietly rather than fail and be reported as a failed boot. → Task 2.
- **The exclude file itself is missing, empty, or has a pattern with a space
  in it.** A `tar --exclude` built by word-splitting a file breaks on a path
  containing a space, and an unquoted empty file yields `--exclude=` which
  matches nothing or everything depending on tar version. → Task 4.
- **The ESP is full.** The atomic write needs room for the new archive
  *alongside* the old one, so a stick that fits one copy but not two now fails
  where the truncating write "succeeded". Expected: the failure is reported, the
  `.new` file is removed, and the previous good `home.tar.gz` is left intact —
  which is the whole point. → Task 4.

---

## File Structure

| file | responsibility | change |
| --- | --- | --- |
| `overlay/usr/libexec/dbrrg/wait-kms` | block until a real KMS driver is bound | new |
| `overlay/etc/systemd/system/dbrrg-wait-kms.service` | run it before `getty@tty1` | new |
| `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf` | autologin ordering | add the wait to `After=`/`Wants=` |
| `overlay/usr/libexec/dbrrg/install-local-network` | install netplan/WireGuard from the home | new |
| `overlay/etc/systemd/system/dbrrg-local-network.service` | run it before the netplan generator | new |
| `overlay/etc/netplan/ethernet.yaml` | shipped ethernet config | mode `0600` |
| `overlay/home/tluser/.dbrrg-sessionrc` | per-machine session customisation | rewrite the NETWORK section |
| `overlay/usr/bin/dbrrg-save-home` | save the home at logout | excludes, atomic write, existing mount, exit codes |
| `overlay/etc/dbrrg/save-home-exclude` | default exclude patterns | new |
| `overlay/etc/profile.d/10-dbrrg-session.sh` | session launcher | retry once on a GPU failure |
| `overlay/etc/systemd/system/un-dockerize.service` | undo container artifacts | set the hostname |
| `scripts/export-rootfs.sh` | build the squashfs | stop packing podman's bind mounts |
| `containers/ubuntu/Dockerfile` | enable the new units | two `systemctl enable` lines |
| `test/integration/test-field-report.sh` | guard all of it | new |
| `test/integration/test-save-home.sh` | `dbrrg-save-home` offline | excludes, atomicity, exit codes |

---

### Task 1: Wait for a real KMS driver before autologin

**Files:**
- Create: `overlay/usr/libexec/dbrrg/wait-kms`
- Create: `overlay/etc/systemd/system/dbrrg-wait-kms.service`
- Modify: `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf`
- Modify: `containers/ubuntu/Dockerfile` — enable the new unit
- Test: `test/integration/test-field-report.sh` (new file, created here)

**Interfaces:**
- Consumes: nothing.
- Produces: `dbrrg-wait-kms.service`, ordered `Before=getty@tty1.service`. Task
  3 refers to it in a comment but does not depend on it.

**Why:** This is the fatal one. `i915` is in dracut's `--omit-drivers`
(`Dockerfile:294`), so it loads only from udev coldplug after switch-root.
Until then `card0` is simpledrm. When i915 binds it removes simpledrm's
`card0` and registers its own, and in the gap there is no usable `card0`.
Autologin is ordered only `After=plymouth-quit-wait.service`, which does not
cover that gap: on the reported boot the session started at 11.099 s and
i915's `card0` appeared at 11.372 s — 273 ms too late. labwc then failed with
`Found 0 GPUs`, and because `10-dbrrg-session.sh` holds a failure shell rather
than exiting, **the session is never retried and the boot is lost**.

`After=dev-dri-card0.device` does **not** work: simpledrm's `card0` satisfies
it immediately. `systemd-udev-settle.service` would work but is deprecated and
slow.

- [ ] **Step 1: Write the failing test**

Create `test/integration/test-field-report.sh`:

```bash
#!/bin/bash
# Guards the five defects found on a NUC7i3BNK on 2026-10-01.
# See docs/reports/2026-10-01-nuc7i3bnk-first-boot.md.
#
# Runs against the source tree: these are shipped files, and asserting on the
# source catches a regression before a 10-minute image build. The built-image
# assertions live in test/integration/test-session-packages.sh.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- 1. the KMS race -----------------------------------------------------

WAITKMS="overlay/usr/libexec/dbrrg/wait-kms"
UNIT="overlay/etc/systemd/system/dbrrg-wait-kms.service"
AUTOLOGIN="overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf"

if [[ -x "$WAITKMS" ]]; then
    ok "wait-kms exists and is executable"
else
    bad "wait-kms missing or not executable - the i915 race is still open"
fi

if [[ -f "$UNIT" ]]; then
    ok "dbrrg-wait-kms.service exists"
else
    bad "dbrrg-wait-kms.service missing"
fi

# A plain After=dev-dri-card0.device is satisfied by simpledrm's card0, so it
# does NOT fix the race. Using it would look like a fix and change nothing.
if ! grep -q 'dev-dri-card0.device' "$UNIT" 2>/dev/null; then
    ok "the unit does not rely on dev-dri-card0.device"
else
    bad "the unit waits on dev-dri-card0.device, which simpledrm satisfies at once"
fi

# systemd-udev-settle is deprecated and slow.
if ! grep -q 'udev-settle' "$UNIT" 2>/dev/null; then
    ok "the unit does not use the deprecated systemd-udev-settle"
else
    bad "the unit uses systemd-udev-settle"
fi

if grep -q 'Before=getty@tty1.service' "$UNIT" 2>/dev/null; then
    ok "the unit is ordered before getty@tty1"
else
    bad "the unit is not ordered before getty@tty1 - it would not cover the gap"
fi

if grep -q 'dbrrg-wait-kms' "$AUTOLOGIN" 2>/dev/null; then
    ok "the autologin drop-in pulls in dbrrg-wait-kms"
else
    bad "the autologin drop-in does not reference dbrrg-wait-kms"
fi

# The reason for the whole constraints section in CLAUDE.md: this repo has
# shipped two ordering-cycle bugs. A unit before getty@tty1 (which is in
# multi-user.target) must not also be after something that comes later.
if ! grep -qE '^After=.*(multi-user|basic)\.target' "$UNIT" 2>/dev/null; then
    ok "the unit is not ordered after multi-user.target or basic.target"
else
    bad "the unit is After= a target that comes after getty@tty1 - ordering cycle"
fi

# A machine with no GPU, or only simpledrm, must still reach a login. A wait
# that can block forever is a worse bug than the race it fixes.
if grep -qE 'exit 0' "$WAITKMS" 2>/dev/null; then
    ok "wait-kms exits 0 on timeout so a simpledrm-only machine still logs in"
else
    bad "wait-kms has no exit 0 timeout path - a GPU-less machine would never log in"
fi

# Drive the real script against a fake /sys. It must return promptly when a
# non-simpledrm driver is already bound.
mkdir -p "$WORK/sys/card0/device"
ln -s /fake/drivers/i915 "$WORK/sys/card0/device/driver"
mkdir -p "$WORK/stubs"
cat >"$WORK/stubs/udevadm" <<'STUB'
#!/bin/bash
echo "udevadm $*" >>"$DBRRG_TEST_UDEV_LOG"
exit 0
STUB
chmod +x "$WORK/stubs/udevadm"

start=$(date +%s)
DBRRG_TEST_UDEV_LOG="$WORK/udev.log" \
DBRRG_DRM_GLOB="$WORK/sys/card[0-9]*" \
PATH="$WORK/stubs:$PATH" \
    "$WAITKMS" >"$WORK/out" 2>"$WORK/err"
rc=$?
elapsed=$(( $(date +%s) - start ))
if [[ "$rc" == "0" ]] && [[ "$elapsed" -lt 5 ]] &&
   grep -q 'udevadm wait' "$WORK/udev.log" 2>/dev/null; then
    ok "wait-kms returns at once and calls udevadm wait when i915 is bound"
else
    bad "wait-kms with i915 bound: exit $rc after ${elapsed}s, udev log: $(cat "$WORK/udev.log" 2>/dev/null)"
fi

# simpledrm alone must NOT satisfy it - that is the whole bug.
mkdir -p "$WORK/sys2/card0/device"
ln -s /fake/drivers/simpledrm "$WORK/sys2/card0/device/driver"
: >"$WORK/udev2.log"
start=$(date +%s)
DBRRG_TEST_UDEV_LOG="$WORK/udev2.log" \
DBRRG_DRM_GLOB="$WORK/sys2/card[0-9]*" \
DBRRG_KMS_TIMEOUT=1 \
PATH="$WORK/stubs:$PATH" \
    "$WAITKMS" >"$WORK/out2" 2>"$WORK/err2"
rc=$?
elapsed=$(( $(date +%s) - start ))
if [[ "$rc" == "0" ]] && [[ ! -s "$WORK/udev2.log" ]] &&
   grep -q 'no KMS driver' "$WORK/err2"; then
    ok "simpledrm alone does not satisfy wait-kms, and it still exits 0"
else
    bad "simpledrm case: exit $rc after ${elapsed}s, stderr: $(cat "$WORK/err2")"
fi

exit $fail
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-field-report.sh`
Expected: FAIL on every assertion — none of the files exist yet.

- [ ] **Step 3: Write the wait script**

Create `overlay/usr/libexec/dbrrg/wait-kms`:

```sh
#!/bin/sh
# Wait until a DRM card is driven by something other than simpledrm, and until
# udev has finished with it, so logind can hand it to labwc.
#
# Why this exists: i915 is in dracut's --omit-drivers (containers/ubuntu/
# Dockerfile), so it loads only from udev coldplug after switch-root. Until
# then /dev/dri/card0 is simpledrm. When i915 binds it REMOVES simpledrm's
# card0 and registers its own, and in the gap there is no usable card0 at all.
#
# Measured on a NUC7i3BNK: the tluser session started at 11.099s and i915's
# card0 appeared at 11.372s. labwc failed with "Found 0 GPUs", and because
# 10-dbrrg-session.sh holds a failure shell rather than exiting, the session
# was never retried and the whole boot was lost.
#
# `After=dev-dri-card0.device` does NOT fix this: simpledrm's card0 satisfies
# it immediately. systemd-udev-settle.service would, but it is deprecated and
# slow.
#
# This script NEVER fails the boot. A machine with no KMS driver - a VM, a
# serial-console machine, genuinely simpledrm-only hardware - must still reach
# a login, so the timeout path exits 0.

# Overridable so test/integration/test-field-report.sh can drive this against
# a fake /sys without root or real hardware.
DBRRG_DRM_GLOB="${DBRRG_DRM_GLOB:-/sys/class/drm/card[0-9]*}"
DBRRG_KMS_TIMEOUT="${DBRRG_KMS_TIMEOUT:-20}"

# 0.2s per poll, so the loop count is five times the timeout in seconds.
_wk_max=$(( DBRRG_KMS_TIMEOUT * 5 ))
_wk_i=0

while [ "$_wk_i" -lt "$_wk_max" ]; do
    for _wk_c in $DBRRG_DRM_GLOB; do
        [ -e "$_wk_c" ] || continue
        _wk_drv=$(readlink "$_wk_c/device/driver" 2>/dev/null)
        case "$_wk_drv" in
            ''|*simpledrm*|*simple-framebuffer*)
                ;;
            *)
                # A real driver is bound. Wait for udev to tag the device and
                # apply its uaccess ACLs, or logind's TakeDevice still fails.
                exec udevadm wait --timeout=5 "/dev/dri/${_wk_c##*/}"
                ;;
        esac
    done
    sleep 0.2
    _wk_i=$(( _wk_i + 1 ))
done

echo "wait-kms: no KMS driver after ${DBRRG_KMS_TIMEOUT}s, continuing with what there is" >&2
exit 0
```

Make it executable: `chmod 755 overlay/usr/libexec/dbrrg/wait-kms`

- [ ] **Step 4: Write the unit**

Create `overlay/etc/systemd/system/dbrrg-wait-kms.service`:

```ini
# Hold the tty1 autologin until a real KMS driver is bound.
#
# See /usr/libexec/dbrrg/wait-kms for the race this closes and the measurement
# behind it. DefaultDependencies=no is deliberate: a unit ordered
# Before=getty@tty1.service must not also be implicitly ordered
# After=basic.target, because getty@tty1 is pulled in by multi-user.target
# which comes after basic.target - that is both before and after the same
# chain, and systemd resolves such a cycle by silently deleting a job on every
# boot. This repository has shipped that bug twice; see CLAUDE.md's
# "A multi-user.target unit must never declare Before= on a sysinit.target
# unit".
[Unit]
Description=Wait for a real KMS driver before the tty1 session
DefaultDependencies=no
Conflicts=shutdown.target
Before=shutdown.target
After=systemd-udev-trigger.service
Before=getty@tty1.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/dbrrg/wait-kms
# The script's own timeout is 20s. This is the backstop for a script that
# somehow cannot reach it; it must not be shorter, or it cuts the wait short.
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: Order autologin after it**

In `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf`, find the
existing `After=plymouth-quit-wait.service` line and replace it with:

```ini
# Do not start the session until a real KMS driver is bound either. i915 is
# omitted from the initrd, so it loads from udev coldplug after switch-root,
# and labwc could start in the gap where simpledrm's card0 has been removed
# and i915's does not exist yet - "Found 0 GPUs", a failure shell, and no
# retry. Measured 273ms of exposure on a NUC7i3BNK.
After=plymouth-quit-wait.service dbrrg-wait-kms.service
Wants=dbrrg-wait-kms.service
```

Keep the existing comment above it about plymouth holding DRM master, and keep
`StartLimitIntervalSec=0`.

- [ ] **Step 6: Enable the unit in the build**

In `containers/ubuntu/Dockerfile`, next to the other `systemctl enable` calls
(around line 272), add:

```dockerfile
    systemctl enable dbrrg-wait-kms.service && \
```

Read the surrounding lines first and match their continuation style exactly —
that block is a single `RUN` with `&& \` joins, and a missing backslash breaks
the build.

- [ ] **Step 7: Run the test to verify it passes**

Run: `test/integration/test-field-report.sh`
Expected: PASS, all 10 assertions in section 1.

- [ ] **Step 8: Commit**

```bash
git add overlay/usr/libexec/dbrrg/wait-kms \
        overlay/etc/systemd/system/dbrrg-wait-kms.service \
        overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf \
        containers/ubuntu/Dockerfile \
        test/integration/test-field-report.sh
git commit -m "fix: stop the graphical session losing a race against the GPU

A NUC7i3BNK booted to a failure shell on tty1 with no graphical session
at all. The session log showed labwc exiting with \"Found 0 GPUs, cannot
create backend\" after logind refused /dev/dri/card0 with ENODEV.

i915 is omitted from the initrd, so it loads from udev coldplug after
switch-root. Until then card0 is simpledrm, and when i915 binds it
removes simpledrm's card0 before registering its own - leaving a gap
with no usable card0. Autologin was ordered only after
plymouth-quit-wait.service, which does not cover that gap: the session
started at 11.099s and i915's card0 appeared at 11.372s, 273ms later.
Because 10-dbrrg-session.sh holds a failure shell rather than exiting,
nothing retried and the entire boot was lost rather than delayed.

dbrrg-wait-kms.service now holds the autologin until a card is driven by
something other than simpledrm and udevadm has finished with it, so
logind can hand it over. After=dev-dri-card0.device would not have
worked - simpledrm's card0 satisfies it at once - and
systemd-udev-settle.service is deprecated and slow.

The wait exits 0 after 20s whatever it found, so a VM or genuinely
simpledrm-only machine still reaches a login. The unit uses
DefaultDependencies=no: ordered Before=getty@tty1.service, an implicit
After=basic.target would have been a cycle, which this repository has
shipped twice before.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Install per-machine network config outside the session

**Files:**
- Create: `overlay/usr/libexec/dbrrg/install-local-network`
- Create: `overlay/etc/systemd/system/dbrrg-local-network.service`
- Modify: `overlay/etc/netplan/ethernet.yaml` — mode `0600`
- Modify: `overlay/home/tluser/.dbrrg-sessionrc` — rewrite the NETWORK section
- Modify: `containers/ubuntu/Dockerfile` — enable the new unit
- Test: `test/integration/test-field-report.sh`

**Interfaces:**
- Consumes: the home directory, already restored by the initramfs before
  `multi-user.target` — the same guarantee `dbrrg-ssh-hostkeys.service` relies
  on.
- Produces: `/etc/netplan/wifi.yaml` and `/etc/wireguard/wg0.conf`, both
  `0600 root:root`, written before `netplan-configure.service` runs.

**Why:** On the X11 image `~/.xsessionrc` copied `~/wifi.yaml` into
`/etc/netplan` and `~/wg0.conf` into `/etc/wireguard` on every boot, because
`/etc` is a fresh RAM overlay. `~/.dbrrg-sessionrc` is the working replacement
and is sourced by `dbrrg-session:39-40`, but its NETWORK section presents those
commands as a one-off recipe rather than as lines to keep, so the reporter
never found them.

The defect that survives a wording fix is the coupling: config applied from
the session is absent on a machine whose session failed to start. That is
exactly what happened here — Task 1's bug killed the session, which killed the
network, which removed any way to diagnose Task 1's bug remotely. Decided with
the user on 2026-10-02: move it to a system unit, keep `~/.dbrrg-sessionrc`
for display configuration.

Running before `netplan-configure.service` means the generator's output already
includes the WiFi, so no `netplan apply` is needed and the interface associates
during boot rather than 11 s in.

`netplan-configure.service`'s own shape, read from the image on 2026-10-02, is
the template to match:

```
DefaultDependencies=no
Before=shutdown.target network-pre.target
Before=systemd-networkd.service NetworkManager.service
After=local-fs.target systemd-sysusers.service systemd-udevd-control.socket
[Install] WantedBy=sysinit.target
```

- [ ] **Step 1: Write the failing test**

Append to `test/integration/test-field-report.sh`, before the final `exit $fail`:

```bash
# --- 2. per-machine network config outside the session -------------------

NETSCRIPT="overlay/usr/libexec/dbrrg/install-local-network"
NETUNIT="overlay/etc/systemd/system/dbrrg-local-network.service"

if [[ -x "$NETSCRIPT" ]]; then
    ok "install-local-network exists and is executable"
else
    bad "install-local-network missing - WiFi still depends on the session"
fi

if grep -q 'Before=.*netplan-configure.service' "$NETUNIT" 2>/dev/null; then
    ok "the unit runs before the netplan generator"
else
    bad "the unit is not before netplan-configure.service - WiFi would need netplan apply"
fi

# Same shape as netplan-configure.service itself. A WantedBy=multi-user.target
# unit with Before= on a sysinit.target unit is the ordering cycle this repo
# has shipped twice.
if grep -q 'DefaultDependencies=no' "$NETUNIT" 2>/dev/null &&
   grep -q 'WantedBy=sysinit.target' "$NETUNIT" 2>/dev/null; then
    ok "the unit uses the netplan-configure shape (no default deps, sysinit)"
else
    bad "the unit does not match netplan-configure's ordering shape"
fi

# Netplan refuses a config file others can read: "Permissions for ... are too
# open". That is the shipped bug in report section 3.
if grep -qE '0?600' "$NETSCRIPT" 2>/dev/null; then
    ok "the script installs netplan config mode 600"
else
    bad "the script does not install mode 600 - netplan would refuse the file"
fi

# Report section 3: the shipped file is world-readable.
mode=$(stat -c%a overlay/etc/netplan/ethernet.yaml 2>/dev/null)
if [[ "$mode" == "600" ]]; then
    ok "ethernet.yaml ships mode 600"
else
    bad "ethernet.yaml ships mode $mode - netplan logs 'Permissions ... too open'"
fi

# The template must stop presenting the netplan commands as a one-off recipe.
if ! grep -q 'sudo netplan apply' overlay/home/tluser/.dbrrg-sessionrc; then
    ok "the sessionrc template no longer tells the user to run netplan apply"
else
    bad "the sessionrc template still shows the manual one-off netplan recipe"
fi

if grep -q 'dbrrg-local-network' overlay/home/tluser/.dbrrg-sessionrc; then
    ok "the sessionrc template points at the system unit instead"
else
    bad "the sessionrc template does not mention the new mechanism"
fi

# Drive the real script against a fake root.
mkdir -p "$WORK/h" "$WORK/etc/netplan" "$WORK/stubs"
printf 'network:\n  version: 2\n' >"$WORK/h/wifi.yaml"
printf '[Interface]\nPrivateKey=x\n'  >"$WORK/h/wg0.conf"
cat >"$WORK/stubs/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$DBRRG_TEST_SYSTEMCTL_LOG"
exit 0
STUB
chmod +x "$WORK/stubs/systemctl"

DBRRG_TEST_SYSTEMCTL_LOG="$WORK/systemctl.log" \
DBRRG_HOME_DIR="$WORK/h" \
DBRRG_ETC="$WORK/etc" \
PATH="$WORK/stubs:$PATH" \
    "$NETSCRIPT" >"$WORK/nout" 2>"$WORK/nerr"
rc=$?
if [[ "$rc" == "0" ]] && [[ -f "$WORK/etc/netplan/wifi.yaml" ]] &&
   [[ "$(stat -c%a "$WORK/etc/netplan/wifi.yaml")" == "600" ]]; then
    ok "installs wifi.yaml mode 600 from the restored home"
else
    bad "wifi.yaml install failed (exit $rc, mode $(stat -c%a "$WORK/etc/netplan/wifi.yaml" 2>/dev/null))"
fi

if [[ -f "$WORK/etc/wireguard/wg0.conf" ]] &&
   [[ "$(stat -c%a "$WORK/etc/wireguard")" == "700" ]] &&
   grep -q 'wg-quick@wg0' "$WORK/systemctl.log"; then
    ok "installs wg0.conf into a 0700 /etc/wireguard and enables wg-quick@wg0"
else
    bad "wg0.conf install failed (dir mode $(stat -c%a "$WORK/etc/wireguard" 2>/dev/null), systemctl: $(cat "$WORK/systemctl.log"))"
fi

# A first boot, or a failed restore, leaves no files. The unit must succeed
# quietly rather than fail and be reported as a failed boot.
mkdir -p "$WORK/h2" "$WORK/etc2"
DBRRG_TEST_SYSTEMCTL_LOG="$WORK/systemctl2.log" \
DBRRG_HOME_DIR="$WORK/h2" \
DBRRG_ETC="$WORK/etc2" \
PATH="$WORK/stubs:$PATH" \
    "$NETSCRIPT" >/dev/null 2>&1
if [[ "$?" == "0" ]]; then
    ok "succeeds quietly when the home has no network config"
else
    bad "failed on a home with no wifi.yaml - that is a normal first boot"
fi

# One broken half must not take the other down.
mkdir -p "$WORK/h3" "$WORK/etc3"
printf '[Interface]\nPrivateKey=x\n' >"$WORK/h3/wg0.conf"
DBRRG_TEST_SYSTEMCTL_LOG="$WORK/systemctl3.log" \
DBRRG_HOME_DIR="$WORK/h3" \
DBRRG_ETC="$WORK/etc3" \
PATH="$WORK/stubs:$PATH" \
    "$NETSCRIPT" >/dev/null 2>&1
if [[ -f "$WORK/etc3/wireguard/wg0.conf" ]]; then
    ok "installs WireGuard even when there is no wifi.yaml"
else
    bad "a missing wifi.yaml stopped the WireGuard half"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-field-report.sh`
Expected: section 1 PASSes, every section 2 assertion FAILs.

- [ ] **Step 3: Write the install script**

Create `overlay/usr/libexec/dbrrg/install-local-network`:

```sh
#!/bin/sh
# Install per-machine network configuration from the restored home directory.
#
# /etc is a RAM overlay reset on every boot, so this has to run on every boot.
# On the X11 image ~/.xsessionrc did it; the Wayland replacement
# ~/.dbrrg-sessionrc could, but config applied from the session is absent on a
# machine whose session failed to start - and that is not hypothetical: an
# i915 race left a NUC7i3BNK at a failure shell with no network, so the one
# thing needed to diagnose the failure remotely was the thing the failure took
# away. See docs/reports/2026-10-01-nuc7i3bnk-first-boot.md.
#
# Runs before netplan-configure.service, so the generator's output already
# contains the WiFi and the interface associates during boot. No netplan apply.
#
# Never fails the boot: a first boot, or a boot whose home restore failed, has
# none of these files and that is normal.

# Overridable for test/integration/test-field-report.sh.
DBRRG_ETC="${DBRRG_ETC:-/etc}"
# Never $HOME: this runs as root from systemd, where HOME is /root.
DBRRG_HOME_DIR="${DBRRG_HOME_DIR:-$(getent passwd tluser | cut -d: -f6)}"
: "${DBRRG_HOME_DIR:=/home/tluser}"

# Netplan refuses a file others can read - "Permissions for ... are too open" -
# and then ignores it, so a mode slip here looks like a WiFi config that was
# never written.
if [ -r "$DBRRG_HOME_DIR/wifi.yaml" ]; then
    install -d -m 755 "$DBRRG_ETC/netplan"
    if install -m 600 -o root -g root \
            "$DBRRG_HOME_DIR/wifi.yaml" "$DBRRG_ETC/netplan/wifi.yaml"; then
        echo "dbrrg: installed $DBRRG_ETC/netplan/wifi.yaml"
    else
        echo "dbrrg: could not install wifi.yaml" >&2
    fi
fi

# Kept independent of the block above on purpose: a machine with a broken or
# absent wifi.yaml must still get its VPN, because the VPN is how it is
# reached.
if [ -r "$DBRRG_HOME_DIR/wg0.conf" ]; then
    install -d -m 700 "$DBRRG_ETC/wireguard"
    if install -m 600 -o root -g root \
            "$DBRRG_HOME_DIR/wg0.conf" "$DBRRG_ETC/wireguard/wg0.conf"; then
        echo "dbrrg: installed $DBRRG_ETC/wireguard/wg0.conf"
        # --runtime writes the symlink into /run, so nothing lingers in the
        # overlay and a removed wg0.conf does not leave an enabled unit behind.
        systemctl enable --runtime wg-quick@wg0.service || \
            echo "dbrrg: could not enable wg-quick@wg0" >&2
    else
        echo "dbrrg: could not install wg0.conf" >&2
    fi
fi

exit 0
```

Make it executable: `chmod 755 overlay/usr/libexec/dbrrg/install-local-network`

Note `install -o root -g root` fails for an unprivileged test user. The test
drives the script as the invoking user, so if `install -o root` errors there,
drop `-o root -g root` and rely on the script running as root from systemd
(root owns what root creates). Decide this when the test runs: if it fails on
ownership, remove those two flags and add a comment saying why.

- [ ] **Step 4: Write the unit**

Create `overlay/etc/systemd/system/dbrrg-local-network.service`:

```ini
# Install per-machine netplan and WireGuard config from the restored home,
# before the netplan generator reads /etc/netplan.
#
# The ordering shape is copied from netplan-configure.service itself, read out
# of the built image on 2026-10-02. DefaultDependencies=no matters: a unit
# that is WantedBy=multi-user.target and declares Before= on something in
# sysinit.target is ordered both before and after the same chain, and systemd
# resolves that by silently deleting a job on every boot. This repository has
# shipped that bug twice - see CLAUDE.md, "A multi-user.target unit must never
# declare Before= on a sysinit.target unit".
#
# The home directory is already on disk here: the initramfs restores it before
# multi-user.target, which is the same guarantee dbrrg-ssh-hostkeys.service
# depends on.
[Unit]
Description=Install per-machine netplan/WireGuard config from the restored home
DefaultDependencies=no
Conflicts=shutdown.target
Before=shutdown.target
After=local-fs.target systemd-sysusers.service
Before=netplan-configure.service systemd-networkd.service network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/dbrrg/install-local-network

[Install]
WantedBy=sysinit.target
```

- [ ] **Step 5: Fix the shipped ethernet.yaml permissions**

Run: `chmod 600 overlay/etc/netplan/ethernet.yaml`

The overlay is applied with `tar cf - | tar xf -`, which preserves modes, so
the file's mode in git is the mode in the image. This is report section 3:
netplan logged "Permissions for /etc/netplan/ethernet.yaml are too open.
Netplan configuration should NOT be accessible by others."

- [ ] **Step 6: Rewrite the sessionrc NETWORK section**

In `overlay/home/tluser/.dbrrg-sessionrc`, replace the whole NETWORK block:

```
# ---------------------------------------------------------------------------
# NETWORK
# ---------------------------------------------------------------------------
# WiFi, as in the old setup - edit ~/wifi.yaml first, then:
#
#   sudo cp wifi.yaml /etc/netplan/
#   sudo chown root /etc/netplan/*
#   sudo chmod 400 /etc/netplan/*
#   sudo netplan apply
#
```

with:

```
# ---------------------------------------------------------------------------
# NETWORK - nothing to do here any more
# ---------------------------------------------------------------------------
# WiFi and WireGuard are set up during boot, before the network starts, by
# dbrrg-local-network.service. You do not need to run anything from this file.
#
# Just put the files in your home directory:
#
#   ~/wifi.yaml   a netplan config for your wireless interface
#   ~/wg0.conf    a WireGuard config, started as wg-quick@wg0
#
# They are saved with your home when you quit the ThinLinc client, restored on
# the next boot, and installed into /etc before the network comes up. Check
# what happened with:
#
#   systemctl status dbrrg-local-network
#   journalctl -u dbrrg-local-network
#
# This deliberately does NOT run from this file. Network configuration applied
# from the session is gone on a machine whose session failed to start - which
# is when you most need to reach it.
#
```

- [ ] **Step 7: Enable the unit in the build**

In `containers/ubuntu/Dockerfile`, beside the line added in Task 1:

```dockerfile
    systemctl enable dbrrg-local-network.service && \
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `test/integration/test-field-report.sh`
Expected: PASS, both sections.

- [ ] **Step 9: Commit**

```bash
git add overlay/usr/libexec/dbrrg/install-local-network \
        overlay/etc/systemd/system/dbrrg-local-network.service \
        overlay/etc/netplan/ethernet.yaml \
        overlay/home/tluser/.dbrrg-sessionrc \
        containers/ubuntu/Dockerfile \
        test/integration/test-field-report.sh
git commit -m "fix: bring up WiFi and WireGuard without the graphical session

A NUC7i3BNK came up with its wireless interface unconfigured and no wg0,
although wifi.yaml and wg0.conf were both restored in the home
directory. On the X11 image ~/.xsessionrc copied them into /etc on every
boot, because /etc is a fresh RAM overlay. Nothing in the image did that
job any more.

~/.dbrrg-sessionrc is the replacement for ~/.xsessionrc and is sourced
on every session, so it could have, but its NETWORK section showed the
netplan commands as a one-off recipe rather than as lines to keep - the
reporter read them as something to type once and never found that
putting them in the file would make them run each boot.

Moving it to the session would not have been enough anyway. The same
machine's session did not start, which is how it lost the network, which
is why the session failure could not be diagnosed remotely: the one
thing needed to reach the machine was the thing the fault removed.

dbrrg-local-network.service now installs both files before
netplan-configure.service, so the generator's output already contains
the WiFi and the interface associates during boot rather than eleven
seconds in, with no netplan apply over a live network and no sudo. The
two halves are independent: a machine with a broken wifi.yaml still gets
its VPN. A home with neither file is a normal first boot and the unit
says nothing.

The unit copies netplan-configure.service's own ordering shape -
DefaultDependencies=no, WantedBy=sysinit.target - because a
multi-user.target unit declaring Before= on a sysinit.target unit is the
ordering cycle this repository has shipped twice.

Also ships /etc/netplan/ethernet.yaml mode 600. Netplan logged
\"Permissions for /etc/netplan/ethernet.yaml are too open\" and ignored
it, and the install script writes its own files 600 for the same reason.
The sessionrc NETWORK section now says there is nothing to do there.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Retry the session once when the GPU was not ready

**Files:**
- Modify: `overlay/etc/profile.d/10-dbrrg-session.sh`
- Test: `test/integration/test-field-report.sh`

**Interfaces:**
- Consumes: `/usr/libexec/dbrrg/wait-kms` from Task 1.
- Produces: nothing.

**Why:** Task 1 closes the known race. This covers the rest of the class — a
late hotplug, a GPU that resets, a machine slower than the 20 s budget — and
costs almost nothing. Today a labwc that cannot open DRM lands in the failure
shell and **is never retried**, which is what turned a 273 ms timing problem
into a lost boot. The reporter's own workaround did exactly this from
`~/.profile`.

Note the existing trap recorded in `CLAUDE.md`: **labwc always exits 0**,
whatever its `-S` command returned, so `DBRRG_SESSION_RC` is 0 on a failed
`tlclient` and non-zero only when labwc itself could not start — which is
precisely this case. The retry therefore keys on a non-zero status from labwc,
which is reliable here even though it is useless for session-body failures.

- [ ] **Step 1: Read the current failure path**

Run: `sed -n '100,140p' overlay/etc/profile.d/10-dbrrg-session.sh`
Expected: the block that captures `DBRRG_SESSION_RC` and holds the failure
shell. Read it before editing — the retry goes between those two.

- [ ] **Step 2: Write the failing test**

Append to `test/integration/test-field-report.sh` before the final `exit $fail`:

```bash
# --- 3. retry the session once on a GPU failure --------------------------

PROFILE="overlay/etc/profile.d/10-dbrrg-session.sh"

if grep -q 'DBRRG_SESSION_RETRIED' "$PROFILE"; then
    ok "the session script guards its retry with DBRRG_SESSION_RETRIED"
else
    bad "no retry guard - a GPU not ready at login still loses the whole boot"
fi

if grep -q 'wait-kms' "$PROFILE"; then
    ok "the retry waits for a KMS driver before trying again"
else
    bad "the retry does not wait for a KMS driver, so it would fail the same way"
fi

# Exactly one retry. A loop here spins forever on a machine with no GPU and
# fills the journal.
retries=$(grep -c 'DBRRG_SESSION_RETRIED' "$PROFILE")
if [[ "$retries" -ge 2 ]]; then
    ok "the guard is both set and tested ($retries references)"
else
    bad "DBRRG_SESSION_RETRIED appears $retries time(s) - it must be set and tested"
fi
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `test/integration/test-field-report.sh`
Expected: section 3 FAILs.

- [ ] **Step 4: Add the retry**

In `overlay/etc/profile.d/10-dbrrg-session.sh`, immediately after the line
that captures labwc's exit status into `DBRRG_SESSION_RC` and before the
failure-shell block, insert:

```sh
    # Retry once if labwc itself could not start.
    #
    # labwc always exits 0 whatever its -S command returned, so a non-zero
    # status here means labwc could not come up at all - almost always no
    # usable DRM device. dbrrg-wait-kms.service covers the known i915 coldplug
    # race before login; this covers what it cannot: a late hotplug, a GPU
    # reset, or hardware slower than its 20s budget.
    #
    # Exactly once, guarded by an exported variable, because a loop on a
    # machine with no GPU would spin forever and fill the journal. Before the
    # fix that added this, a 273ms timing miss on a NUC7i3BNK cost the entire
    # boot: the failure shell below is held, never exited, and nothing
    # retried.
    if [ "$DBRRG_SESSION_RC" -ne 0 ] && [ -z "${DBRRG_SESSION_RETRIED:-}" ]; then
        echo "dbrrg: the compositor did not start (status $DBRRG_SESSION_RC)."
        echo "dbrrg: waiting for a graphics driver and trying once more..."
        /usr/libexec/dbrrg/wait-kms || true
        DBRRG_SESSION_RETRIED=1
        export DBRRG_SESSION_RETRIED
        . /etc/profile.d/10-dbrrg-session.sh
        return 0 2>/dev/null || exit 0
    fi
```

Match the surrounding indentation exactly — that block is inside an `if`.

- [ ] **Step 5: Check the re-source terminates**

Read the top of the file. The script must not re-enter the retry on the second
pass: `DBRRG_SESSION_RETRIED` is exported before the re-source, and the guard
tests it, so the second pass falls through to the failure shell. Confirm by
reading, then:

Run: `sh -n overlay/etc/profile.d/10-dbrrg-session.sh && echo "syntax ok"`
Expected: `syntax ok`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `test/integration/test-field-report.sh`
Expected: PASS, all three sections.

- [ ] **Step 7: Commit**

```bash
git add overlay/etc/profile.d/10-dbrrg-session.sh \
        test/integration/test-field-report.sh
git commit -m "fix: retry the session once instead of losing the boot

A compositor that could not open a DRM device left tty1 at the failure
shell, and because that shell is held rather than exited, nothing ever
retried. A 273ms timing miss against i915 coldplug therefore cost a
NUC7i3BNK its entire boot rather than a moment's delay.

The session now waits for a KMS driver and starts once more before
falling through to the failure shell. dbrrg-wait-kms.service already
closes the known coldplug race; this covers what ordering cannot - a
late hotplug, a GPU reset, hardware slower than that unit's 20s budget.

Exactly one retry, guarded by an exported variable, because a loop on a
machine with genuinely no GPU would spin forever and fill the journal.

This keys on labwc's own exit status, which is reliable for exactly this
failure: labwc always exits 0 whatever its -S command returned, so a
non-zero status means labwc itself could not start.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Make the home save small, atomic, and aimed at the right stick

**Files:**
- Modify: `overlay/usr/bin/dbrrg-save-home`
- Create: `overlay/etc/dbrrg/save-home-exclude`
- Test: `test/integration/test-save-home.sh`

**Interfaces:**
- Consumes: `/run/dbrrg/storage/efi`, the ESP mount the initramfs leaves in
  place.
- Produces: the exit-code table in Global Constraints. The later tile-menu
  plan switches on these.

**Why, three defects in one script:**

1. **No exclude list.** It tars all of the home. On the reported machine that
   included a ~233 MB Claude Code binary in `~/.local/share/claude/versions`
   plus `~/.cache`, turning a ~22 MB archive into several hundred MB — and
   `restore_home()` unpacks it **synchronously in the initramfs**, so every
   boot pays for it. The previous image's script read an exclude file.
2. **Non-atomic overwrite.** `tar zcf - . | sudo dd of=/boot/efi/home.tar.gz`
   truncates the only copy first. A power cut or a full ESP mid-write leaves a
   broken archive and the next boot comes up with an empty home: no SSH host
   keys, no WireGuard key.
3. **A second mount of the already-mounted ESP.** It mounts
   `/dev/disk/by-partlabel/EFI-SYSTEM` on `/boot/efi` although the boot ESP is
   mounted at `/run/dbrrg/storage/efi`. Every dbrrg stick carries that
   partlabel, so with a second stick plugged in the home can be written to the
   wrong one.

Plus the exit codes, folded in here rather than in a separate pass because
this task is already rewriting the same lines.

Also note `/bin/sh` has **no `pipefail`**, so `tar … | dd` tests only `dd`'s
status. Writing `tar -f <file>` directly instead of piping removes that hole
along with the atomicity problem.

- [ ] **Step 1: Write the default exclude file**

Create `overlay/etc/dbrrg/save-home-exclude`:

```
# Default tar --exclude patterns for dbrrg-save-home, one per line.
# Blank lines and lines starting with # are ignored.
#
# A user can override this wholesale with ~/.save-home-exclude.
#
# Why this file exists: the home archive is unpacked SYNCHRONOUSLY by the
# initramfs on every boot, so anything in it is paid for at every startup. A
# NUC7i3BNK's home held a 233 MB Claude Code binary and a large ~/.cache,
# turning a 22 MB archive into several hundred MB.
./.cache
./.local/share/claude/versions
./.local/share/Trash
./.thumbnails
./.npm/_cacache
./.cargo/registry
./.mozilla/firefox/*/cache2
```

- [ ] **Step 2: Write the failing tests**

Append to `test/integration/test-save-home.sh` before the final `exit $fail`.
First extend the stub set and the runner, after the existing `sudo` stub:

```bash
cat >"$STUBS/gzip" <<'STUB'
#!/bin/bash
# Only -t (test) is used by the script. Report the archive as valid unless the
# test asked for a corrupt one.
[ -n "${DBRRG_TEST_GZIP_FAIL:-}" ] && exit 1
exit 0
STUB
chmod +x "$STUBS/gzip"
```

and extend `run_save_home` with the two new seams:

```bash
    DBRRG_EFI_MOUNT="${DBRRG_EFI_MOUNT_OVERRIDE:-/run/dbrrg/storage/efi}" \
    DBRRG_EXCLUDE_DEFAULT="${DBRRG_EXCLUDE_DEFAULT_OVERRIDE:-/etc/dbrrg/save-home-exclude}" \
```

Then the assertions:

```bash
# --------------------------------------------------------------- test 12
# The archive is unpacked synchronously by the initramfs on every boot, so an
# unfiltered home makes every startup slower. A 233MB Claude binary did this.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp"
printf './.cache\n./.local/share/claude/versions\n' >"$WORK/exclude-default"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" \
     DBRRG_EXCLUDE_DEFAULT_OVERRIDE="$WORK/exclude-default" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if grep -q 'exclude' "$WORK/tar.log" 2>/dev/null; then
    ok "passes exclude patterns to tar"
else
    bad "no --exclude reached tar (exit $rc, tar log: $(cat "$WORK/tar.log" 2>/dev/null))"
fi

# --------------------------------------------------------------- test 13
# A user file replaces the shipped defaults.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp"
printf './my-own-junk\n' >"$WORK/home/tluser/.save-home-exclude"
printf './.cache\n' >"$WORK/exclude-default"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" \
     DBRRG_EXCLUDE_DEFAULT_OVERRIDE="$WORK/exclude-default" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if grep -q 'my-own-junk' "$WORK/tar.log" 2>/dev/null; then
    ok "~/.save-home-exclude takes precedence over the shipped defaults"
else
    bad "the user's exclude file was ignored (tar log: $(cat "$WORK/tar.log"))"
fi

# --------------------------------------------------------------- test 14
# A pattern containing a space must stay one pattern. Word-splitting a line
# into tar arguments breaks every path with a space in it.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp"
printf './My Documents/big\n' >"$WORK/home/tluser/.save-home-exclude"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if grep -q 'exclude=./My Documents/big' "$WORK/tar.log" 2>/dev/null; then
    ok "an exclude pattern containing a space survives as one pattern"
else
    bad "a pattern with a space was split (tar log: $(cat "$WORK/tar.log"))"
fi

# --------------------------------------------------------------- test 15
# A missing or empty exclude file must not produce a bare --exclude=, which
# matches nothing or everything depending on the tar version.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp"
: >"$WORK/home/tluser/.save-home-exclude"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" \
     DBRRG_EXCLUDE_DEFAULT_OVERRIDE="$WORK/nonexistent" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "0" ]] && ! grep -qE 'exclude=($|[[:space:]])' "$WORK/tar.log"; then
    ok "an empty exclude file produces no bare --exclude="
else
    bad "empty exclude file produced '$(grep -o 'exclude=[^ ]*' "$WORK/tar.log" | head -3)' (exit $rc)"
fi

# --------------------------------------------------------------- test 16
# Atomicity. The previous archive must survive a failed write - it is the only
# copy of the user's home and the machine's SSH identity.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp"
echo "THE GOOD OLD ARCHIVE" >"$WORK/esp/home.tar.gz"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" \
     DBRRG_TEST_GZIP_FAIL=1 \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "5" ]] &&
   grep -q "THE GOOD OLD ARCHIVE" "$WORK/esp/home.tar.gz" &&
   [[ ! -e "$WORK/esp/home.tar.gz.new" ]]; then
    ok "a corrupt new archive is discarded and the old one survives"
else
    bad "atomicity broken: exit $rc, old archive $(head -c40 "$WORK/esp/home.tar.gz" 2>/dev/null), .new $([[ -e "$WORK/esp/home.tar.gz.new" ]] && echo present || echo absent)"
fi

# --------------------------------------------------------------- test 17
# It must write to the ESP the initramfs already mounted, never mount
# by-partlabel again: every dbrrg stick carries that label, so with two sticks
# plugged in the home can land on the wrong one.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "0" ]] && [[ -f "$WORK/esp/home.tar.gz" ]] &&
   ! grep -q 'mount' "$WORK/sudo.log" 2>/dev/null; then
    ok "writes to the existing ESP mount without mounting anything"
else
    bad "did not use the existing mount (exit $rc, sudo log: $(cat "$WORK/sudo.log" 2>/dev/null))"
fi

# --------------------------------------------------------------- test 18
# And the whole script must no longer name that symlink at all.
if ! grep -q 'by-partlabel' "$SCRIPT"; then
    ok "dbrrg-save-home no longer mentions /dev/disk/by-partlabel"
else
    bad "dbrrg-save-home still references by-partlabel: $(grep -n by-partlabel "$SCRIPT")"
fi
```

Also add the four exit-code assertions (tests 7-11) from
`docs/superpowers/plans/2026-10-02-home-copy-and-save-contract.md` Task 3
Step 1 — they are unchanged and still apply. Copy them verbatim from that
file, except **test 9**, whose no-target branch now triggers when there is
neither a boot server nor an ESP mount:

```bash
# ---------------------------------------------------------------- test 9
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/no-such-mount" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "4" ]] && ! grep -q "home saved" "$WORK/out"; then
    ok "exit 4 with no 'home saved' when there is nowhere to store the home"
else
    bad "no-target branch exited $rc (wanted 4), stdout: $(cat "$WORK/out")"
fi
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `test/integration/test-save-home.sh`
Expected: the three pre-existing assertions PASS; every new one FAILs.

- [ ] **Step 4: Rewrite the script**

The three existing defects and the exit codes land together. Replace
`overlay/usr/bin/dbrrg-save-home` from the `BOOT_SRV` line down. Keep lines
1-60 (the shebang, `set -e`, the `DBRRG_HOME_DIR` resolution with its comment,
`BASE_PATH`, `MAC_ADDR`) exactly as they are — they were fixed in `cfe7aa0`
and their comments record why.

Add to the overridable block near the top:

```sh
# The ESP the initramfs mounted and deliberately left mounted. mount-squashfs.sh
# mounts it read-write and dbrrg-cleanup.sh says, in a comment, not to unmount
# it. It is by construction the partition this boot read, so writing here means
# the save and the restore cannot disagree.
#
# The old code mounted /dev/disk/by-partlabel/EFI-SYSTEM on /boot/efi instead.
# Every dbrrg stick carries that partlabel, so with a second stick plugged in
# the symlink could resolve to the OTHER stick and the user's home was written
# there. It also mounted the same vfat filesystem a second time.
DBRRG_EFI_MOUNT="${DBRRG_EFI_MOUNT:-/run/dbrrg/storage/efi}"
DBRRG_EXCLUDE_DEFAULT="${DBRRG_EXCLUDE_DEFAULT:-/etc/dbrrg/save-home-exclude}"

# Exit codes, read by dbrrg-menu to tell the user what happened:
#
#   0  home saved
#   1  the resolved home directory is missing or is not a directory
#   2  this boot's home restore failed, so saving would destroy the good copy
#   3  the boot server is unreachable
#   4  this machine has no known place to store a home
#   5  the save was attempted and failed
#
# Everything except 1 used to be 0, and the no-target branch printed "home
# saved" while storing nothing.
```

Then, after the `cd "$DBRRG_HOME_DIR"` line, build the exclude argument list:

```sh
# Build the tar exclude list.
#
# The archive is unpacked SYNCHRONOUSLY by the initramfs on every boot, so
# everything in it is paid for at every startup. A NUC7i3BNK's home held a
# 233MB Claude Code binary and a large ~/.cache: a 22MB archive became several
# hundred MB and every boot got slower.
#
# `set --` builds a real argument list rather than a string, so a pattern
# containing a space stays one pattern. A string split by the shell would
# break every path with a space in it.
EXCLUDE_FILE="$DBRRG_HOME_DIR/.save-home-exclude"
[ -r "$EXCLUDE_FILE" ] || EXCLUDE_FILE="$DBRRG_EXCLUDE_DEFAULT"
set --
if [ -r "$EXCLUDE_FILE" ]; then
  while IFS= read -r _dsh_pat || [ -n "$_dsh_pat" ]; do
    # Skip blanks and comments. An empty pattern would become a bare
    # --exclude=, which matches nothing or everything depending on tar
    # version - either way not what the file says.
    case "$_dsh_pat" in
      ''|'#'*) continue ;;
    esac
    set -- "$@" "--exclude=$_dsh_pat"
  done <"$EXCLUDE_FILE"
fi
```

Replace the netboot upload branch:

```sh
if [ "" != "$BOOT_SRV" ]; then
  # ... keep the existing bounded ping loop unchanged, but exit 3 on failure
  if [ "$_dsh_reachable" -ne 1 ]; then
    echo "dbrrg: boot server $BOOT_SRV unreachable after ${_dsh_waited}s -" >&2
    echo "       refusing to save. An upload that cannot reach its target" >&2
    echo "       cannot work; retry once the network is back." >&2
    exit 3
  fi
  if ! tar "$@" -zcf "/tmp/$$.tar.gz" .; then
    rm -f "/tmp/$$.tar.gz"
    echo "dbrrg: could not archive $DBRRG_HOME_DIR - nothing was uploaded." >&2
    exit 5
  fi
  if ! curl -F "data=@/tmp/$$.tar.gz" "${BASE_PATH}/home.pkg?mac=${MAC_ADDR}"; then
    rm -f "/tmp/$$.tar.gz"
    echo "dbrrg: upload to ${BASE_PATH} failed - your home was NOT saved." >&2
    exit 5
  fi
  rm -f "/tmp/$$.tar.gz"
```

Replace the USB branch entirely:

```sh
elif [ -d "$DBRRG_EFI_MOUNT" ]; then
  # Write beside the live archive and rename over it only once the new one is
  # known good.
  #
  # The old code was `tar zcf - . | sudo dd of=/boot/efi/home.tar.gz`, which
  # truncates the only copy of the user's home BEFORE writing a byte. A power
  # cut or a full ESP mid-write left a broken archive, and the next boot came
  # up with an empty home: no SSH host keys, no WireGuard key, no settings.
  #
  # Writing tar -f directly also removes a second hole: /bin/sh has no
  # pipefail, so `tar | dd` only ever tested dd's status, and a tar that died
  # mid-stream still looked like a successful save.
  _dsh_new="$DBRRG_EFI_MOUNT/home.tar.gz.new"
  rm -f "$_dsh_new"
  if ! tar "$@" -zcf "$_dsh_new" .; then
    rm -f "$_dsh_new"
    echo "dbrrg: could not write the archive - your home was NOT saved, and" >&2
    echo "       the previous one is untouched." >&2
    exit 5
  fi
  # Verify before committing. A truncated gzip is exactly what a full ESP
  # produces, and restore_home would accept a file that merely exists.
  if ! gzip -t "$_dsh_new"; then
    rm -f "$_dsh_new"
    echo "dbrrg: the new archive is corrupt - your home was NOT saved, and" >&2
    echo "       the previous one is untouched." >&2
    exit 5
  fi
  if ! mv -f "$_dsh_new" "$DBRRG_EFI_MOUNT/home.tar.gz"; then
    rm -f "$_dsh_new"
    echo "dbrrg: could not replace the stored archive - your home was NOT" >&2
    echo "       saved, and the previous one is untouched." >&2
    exit 5
  fi
  sync
```

Replace the final branch and trailing echo:

```sh
else
  echo "dbrrg: this machine has no boot server and no mounted EFI partition," >&2
  echo "       so there is nowhere to store your home directory. Nothing was" >&2
  echo "       saved." >&2
  exit 4
fi
echo "home saved"
```

Keep the restore-failed gate where it is, changing its `exit 0` to `exit 2`.

Note `mv` within one filesystem is a rename and therefore atomic. `vfat`
supports rename-over-existing, so this is a real atomic replace on the ESP,
not a copy.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `test/integration/test-save-home.sh`
Expected: PASS, all assertions.

- [ ] **Step 6: Check the archive shape did not change**

`restore_home()` unpacks into the home directory, so members must stay
relative. Verify with the real tar:

```bash
cd /scratch/oetiker/claude-tmp && rm -rf savecheck && mkdir -p savecheck/h/.cache && \
  echo keep > savecheck/h/.dbrrg-sessionrc && echo junk > savecheck/h/.cache/x && \
  tar --exclude=./.cache -zcf savecheck/a.tar.gz -C savecheck/h . && \
  tar tzf savecheck/a.tar.gz
```
Expected: `./` and `./.dbrrg-sessionrc` present, nothing under `./.cache`.

- [ ] **Step 7: Commit**

```bash
git add overlay/usr/bin/dbrrg-save-home overlay/etc/dbrrg/save-home-exclude \
        test/integration/test-save-home.sh
git commit -m "fix: save a small home archive atomically to the right stick

Three defects in one script, all reported from a NUC7i3BNK.

It archived the whole home directory with no exclude list. That machine
held a 233 MB Claude Code binary and a large cache, so a 22 MB archive
became several hundred MB - and the initramfs unpacks it synchronously
on every boot, so every startup paid for it. dbrrg-save-home now reads
~/.save-home-exclude, falling back to /etc/dbrrg/save-home-exclude, one
tar pattern per line. The patterns go into a real argument list, so a
path containing a space stays one pattern, and a blank line no longer
becomes a bare --exclude= that matches nothing or everything depending
on the tar version.

It overwrote the stored archive in place: tar piped into dd truncated
the only copy of the user's home before writing a byte, so a power cut
or a full ESP left a broken file and the next boot came up with an empty
home - no SSH host keys, no WireGuard key. It now writes home.tar.gz.new,
checks it with gzip -t, and renames it over the old one, which on vfat is
atomic. A failure at any step removes the new file and leaves the
previous archive untouched. Writing tar -f directly also closes a second
hole: /bin/sh has no pipefail, so the old pipeline only ever tested dd's
status and a tar that died mid-stream still looked successful.

It mounted /dev/disk/by-partlabel/EFI-SYSTEM on /boot/efi, although the
boot ESP is already mounted at /run/dbrrg/storage/efi - mount-squashfs.sh
mounts it read-write and dbrrg-cleanup.sh says in a comment not to
unmount it. Every dbrrg stick carries that partlabel, so with a second
one plugged in the home could be written to the wrong stick. The save now
writes to the existing mount, which is by construction the partition the
restore read, and the script no longer names that symlink at all.

Folded in rather than touching the same lines twice: each outcome gets
its own exit code. 2 for a boot whose restore failed, 3 for an
unreachable boot server, 4 for a machine with nowhere to store a home,
5 for an attempted save that failed, 0 only when an archive was written.
The no-target branch previously printed \"home saved\" and exited 0 while
storing nothing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Stop the hostname being the build container's ID

**Files:**
- Modify: `scripts/export-rootfs.sh`
- Modify: `overlay/etc/systemd/system/un-dockerize.service`
- Test: `test/integration/test-field-report.sh`

**Interfaces:**
- Consumes: `/etc/machine-id`, persisted to `/config/machine-id` on the ESP by
  the initramfs.
- Produces: nothing.

**Why:** `hostname` returns `fa0ad0f31bfa` on every machine booting this image.
`mksquashfs /` runs inside the build container, where podman has bind-mounted
`/etc/hostname`, `/etc/hosts` and `/etc/resolv.conf`, so mksquashfs reads
through those mounts and packs the container's runtime files rather than the
image's own.

`un-dockerize.service` is the right place for the runtime half, and it does run
on every boot — not just the first, despite its `ExecStartPost=systemctl
disable`: that disable writes into the RAM overlay and is lost at reboot, so
the unit is enabled again next boot. It already rewrites `/etc/hosts` from
`/etc/hosts.in` and substitutes `%H`; it simply never set the hostname itself.

Deriving the name from the machine-id gives every machine a stable, unique
hostname, because `/config/machine-id` on the ESP already persists across
reboots.

- [ ] **Step 1: Write the failing test**

Append to `test/integration/test-field-report.sh` before the final `exit $fail`:

```bash
# --- 5. the hostname -----------------------------------------------------

EXPORT="scripts/export-rootfs.sh"
UNDOCK="overlay/etc/systemd/system/un-dockerize.service"

# podman bind-mounts these three files, so mksquashfs packs the container's
# copies - which is how every machine ended up named after the build container.
if grep -qE 'etc/hostname' "$EXPORT"; then
    ok "the squashfs build handles /etc/hostname"
else
    bad "export-rootfs.sh still packs podman's bind-mounted /etc/hostname"
fi

if grep -q 'set-hostname\|/etc/hostname' "$UNDOCK"; then
    ok "un-dockerize sets the hostname"
else
    bad "un-dockerize never sets the hostname - it stays the container ID"
fi

if grep -q 'machine-id' "$UNDOCK"; then
    ok "the hostname is derived from the persisted machine-id"
else
    bad "the hostname is not derived from machine-id, so it is not unique per machine"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `test/integration/test-field-report.sh`
Expected: section 5 FAILs.

- [ ] **Step 3: Stop packing the bind mounts**

In `scripts/export-rootfs.sh`, the cleanup step already removes
`/etc/machine-id`. Extend it so the container's own identity files do not reach
the squashfs, and say why:

```bash
# Cleanup
log_step "Cleaning up rootfs..."
rm -rf /boot/* /.dockerenv /etc/machine-id /var/lib/dbus/machine-id /var/log/* /tmp/* /var/tmp/*
log_success "Cleanup complete"
```

Then add `etc/hostname` and `etc/resolv.conf` to the mksquashfs exclude list:

```bash
mksquashfs / "$SQSH_OUTPUT" \
    -comp "$SQUASHFS_COMP" \
    -Xcompression-level "$SQUASHFS_COMP_LEVEL" \
    -b 1M \
    -processors "$BUILD_JOBS" \
    -noappend \
    -no-progress \
    -e boot tmp var/tmp artifacts proc sys dev run \
       etc/hostname etc/resolv.conf || die "mksquashfs failed"
```

Why these two and not `/etc/hosts`: podman bind-mounts all three, so
mksquashfs reads the container's copies rather than the image's. `/etc/hosts`
is already handled — the overlay ships `/etc/hosts.in` and
`un-dockerize.service` moves it into place on every boot, so the packed copy
is overwritten anyway. `/etc/resolv.conf` is likewise replaced by
`un-dockerize` with a symlink to systemd-resolved's stub. `/etc/hostname` was
the only one nothing replaced.

With `/etc/hostname` absent, systemd falls back to its compiled default until
`un-dockerize` sets the real one. That is a worse early-boot name than a good
hostname and a better one than another machine's container ID.

- [ ] **Step 4: Set the hostname in un-dockerize**

In `overlay/etc/systemd/system/un-dockerize.service`, add before the existing
`/etc/hosts` lines:

```ini
# Give the machine a stable, unique name.
#
# mksquashfs runs inside the build container, where podman bind-mounts
# /etc/hostname, so the image used to ship the build container's ID and every
# machine in the field answered to the same name - fa0ad0f31bfa. The file is
# now excluded from the squashfs and set here instead.
#
# machine-id is the right source: the initramfs persists it to
# /config/machine-id on the EFI partition, so this name is stable across
# reboots and different on every machine. Twelve hex characters is what
# systemd itself uses for a container name.
ExecStart=/bin/sh -c '/bin/hostnamectl set-hostname "dbrrg-$(cut -c1-6 /etc/machine-id)" || true'
```

Note the existing `/etc/hosts` lines run after this and substitute `%H`, which
systemd expands at unit-load time — **before** this `ExecStart` has run. So on
the first boot of a given machine `/etc/hosts` still carries the old name.
Replace the `sed` line so it reads the live hostname instead:

```ini
ExecStart=/bin/mv /etc/hosts.in /etc/hosts
ExecStart=/bin/sh -c '/bin/sed -i "s/HOSTNAME/$(/bin/hostname)/g" /etc/hosts'
```

This is a real behaviour change, not a cosmetic one: `%H` would have pinned
`/etc/hosts` to whatever the hostname was when systemd loaded the unit.

- [ ] **Step 5: Run the test to verify it passes**

Run: `test/integration/test-field-report.sh`
Expected: PASS, every section.

- [ ] **Step 6: Commit**

```bash
git add scripts/export-rootfs.sh \
        overlay/etc/systemd/system/un-dockerize.service \
        test/integration/test-field-report.sh
git commit -m "fix: give each machine its own hostname

Every machine booting this image answered to fa0ad0f31bfa, the build
container's ID, and /etc/hosts carried 127.0.1.1 for that name too.

mksquashfs runs inside the build container, where podman bind-mounts
/etc/hostname, /etc/hosts and /etc/resolv.conf. mksquashfs reads through
those mounts, so it packed the container's runtime files instead of the
image's own. /etc/hosts and /etc/resolv.conf were already replaced on
every boot by un-dockerize.service; /etc/hostname was the one nothing
replaced.

It is now excluded from the squashfs, and un-dockerize sets the hostname
from the machine-id, which the initramfs persists to /config/machine-id
on the EFI partition - so the name is stable across reboots and
different on every machine.

The /etc/hosts substitution changed with it. It used systemd's %H
specifier, which systemd expands when it loads the unit - before the new
hostname is set - so /etc/hosts would have been pinned to the old name.
It now reads the live hostname at the time the line runs.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Wire it into the suites and boot it

**Files:**
- Modify: `Makefile` — run the new suite
- Modify: `test/integration/test-session-packages.sh` — built-image assertions
- Test: both

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: nothing.

- [ ] **Step 1: Add the suite to make test**

In `Makefile`, add to the `test:` target after the existing lines:

```makefile
	@test/integration/test-field-report.sh
```

- [ ] **Step 2: Write the built-image assertions**

Append to `test/integration/test-session-packages.sh` before its final exit.
**Two traps recorded in `CLAUDE.md`, both live bugs in this file before:**
`unsquashfs -l … | grep -q` reports failure on success under `pipefail` because
`grep -q` exits at the first match and `unsquashfs` dies of SIGPIPE — grep the
listing the test already computed into `$LIST`. And `unsquashfs` exits 0 for a
path it did not find, so an extraction check needs an explicit `[[ -f … ]]`
after it, or the assertion passes vacuously.

```bash
# --- the NUC7i3BNK field report, in the built image ----------------------

for f in usr/libexec/dbrrg/wait-kms \
         usr/libexec/dbrrg/install-local-network \
         etc/systemd/system/dbrrg-wait-kms.service \
         etc/systemd/system/dbrrg-local-network.service \
         etc/dbrrg/save-home-exclude; do
    if grep -q " $f\$\| /$f\$" <<<"$LIST"; then
        ok "$f is in the image"
    else
        bad "$f is missing from the image"
    fi
done

# Both new units must actually be enabled, or they are decoration.
for u in dbrrg-wait-kms dbrrg-local-network; do
    if [[ -L "$EXTRACT/etc/systemd/system/multi-user.target.wants/$u.service" ]] ||
       [[ -L "$EXTRACT/etc/systemd/system/sysinit.target.wants/$u.service" ]]; then
        ok "$u.service is enabled"
    else
        bad "$u.service is not enabled - it would never run"
    fi
done

if [[ "$(stat -c%a "$EXTRACT/etc/netplan/ethernet.yaml")" == "600" ]]; then
    ok "ethernet.yaml is mode 600 in the image"
else
    bad "ethernet.yaml is mode $(stat -c%a "$EXTRACT/etc/netplan/ethernet.yaml") in the image"
fi

if [[ ! -e "$EXTRACT/etc/hostname" ]]; then
    ok "the image ships no /etc/hostname, so no container ID is baked in"
else
    bad "the image ships /etc/hostname containing '$(cat "$EXTRACT/etc/hostname")'"
fi

if ! grep -q 'by-partlabel' "$EXTRACT/usr/bin/dbrrg-save-home"; then
    ok "dbrrg-save-home does not reach the ESP through by-partlabel"
else
    bad "dbrrg-save-home still uses by-partlabel - it can hit the wrong stick"
fi

if grep -q 'home.tar.gz.new' "$EXTRACT/usr/bin/dbrrg-save-home"; then
    ok "dbrrg-save-home writes the archive atomically"
else
    bad "dbrrg-save-home has no .new file - a failed write destroys the only copy"
fi

if grep -q 'dbrrg-wait-kms' \
        "$EXTRACT/etc/systemd/system/getty@tty1.service.d/autologin.conf"; then
    ok "autologin waits for a KMS driver"
else
    bad "autologin does not wait for a KMS driver - the i915 race is open"
fi
```

- [ ] **Step 3: Check artifacts/ is free, then build**

**`artifacts/` is a symlink to `/home/oetiker/scratch/dbrrg-artifacts`, shared
with every other checkout of this project**, so two concurrent builds corrupt
each other.

Run: `ls -l artifacts && pgrep -c -f 'podman build' || true`
Expected: no concurrent build. If there is one, stop and wait.

Run: `make test` with `timeout: 600000`
Expected: PASS, 10 suites. The rootfs build takes minutes.

- [ ] **Step 4: Boot it**

Run: `make qemu-smoke` with `timeout: 600000`
Expected: a clean boot. `scripts/check-boot-smoke.sh` fails on any
`Found ordering cycle` line, which is the gate for the two new units.

Then check the new units did their job:

Run: `grep -iE 'wait-kms|local-network|ordering cycle|Found 0 GPUs' artifacts/images/qemu-smoke.log`
Expected: no ordering cycle, no `Found 0 GPUs`. `wait-kms` will report
`no KMS driver after 20s` under QEMU and exit 0 — that is the designed
behaviour on a machine with no real GPU, and it proves the timeout path works.

Run: `grep -c 'Started getty@tty1' artifacts/images/qemu-smoke.log`
Expected: `1`. More than one means the autologin is restarting, which is how a
broken session shows up (`RestartSec=5`, `StartLimitIntervalSec=0`).

- [ ] **Step 5: Commit**

```bash
git add Makefile test/integration/test-session-packages.sh
git commit -m "test: assert the field-report fixes reach the built image

The new suite checks the source tree, which catches a regression in a
second. These assertions check the squashfs and the enabled units, which
is the gap that once let a stale .ubuntu-container stamp report green
against an old binary.

Covers both new scripts and units present and enabled, ethernet.yaml at
mode 600, no /etc/hostname baked in, dbrrg-save-home free of
by-partlabel and writing through a .new file, and autologin ordered
after the KMS wait.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Verification

```bash
test/integration/test-field-report.sh    # source-tree assertions, instant
test/integration/test-save-home.sh       # offline, instant
make test                                 # 10 suites, builds the rootfs
make qemu-smoke                           # clean boot, no ordering cycle
```

**What this cannot verify, and the hardware steps that can.** QEMU has no i915
and no second USB stick, so the two faults this plan exists to fix cannot be
reproduced in it. On the NUC7i3BNK:

1. **The KMS race.** Boot the new image. The session must come up. Check
   `journalctl -b -u dbrrg-wait-kms` shows it waited and `grep 'Found 0 GPUs'
   $XDG_RUNTIME_DIR/dbrrg-session.log` is empty. Boot it several times — the
   original fault was timing-dependent and won most of the time.
2. **The network.** With `~/wifi.yaml` and `~/wg0.conf` in the home, the
   wireless interface must be configured and `wg0` up **before** the session
   starts. Verify `systemctl status dbrrg-local-network` and that
   `/etc/netplan/wifi.yaml` is `0600 root:root`. Then break the session on
   purpose (rename `/usr/bin/labwc`) and confirm the machine is still
   reachable over the VPN — that is the coupling this task removes.
3. **The archive size.** Log out and check `ls -l
   /run/dbrrg/storage/efi/home.tar.gz`. It should be tens of MB, not hundreds.
   Confirm the next boot is faster.
4. **Atomicity.** Fill the ESP, log out, and confirm the save reports a failure
   and the previous `home.tar.gz` is still intact and still restores.
5. **The hostname.** `hostname` must be `dbrrg-` plus six hex characters, and
   different on a second machine. `grep 127.0.1.1 /etc/hosts` must name it.
6. **Remove the reporter's workarounds** from `$HOME` once 1-4 are confirmed:
   `~/bin/session-setup.sh`, `~/.config/systemd/user/dbrrg-local-setup.service`,
   the retry block at the end of `~/.profile`, and `~/bin/save-home`. Keep
   `~/.save-home-exclude` — the new script reads it.
