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

# When udevadm times out (slow /dev node creation), wait-kms must still exit 0,
# never failing the boot.
mkdir -p "$WORK/sys3/card0/device"
ln -s /fake/drivers/i915 "$WORK/sys3/card0/device/driver"
cat >"$WORK/stubs/udevadm-fail" <<'STUB'
#!/bin/bash
echo "udevadm $*" >>"$DBRRG_TEST_UDEV_LOG"
exit 1
STUB
chmod +x "$WORK/stubs/udevadm-fail"
mv "$WORK/stubs/udevadm" "$WORK/stubs/udevadm-success"
ln -s udevadm-fail "$WORK/stubs/udevadm"

DBRRG_TEST_UDEV_LOG="$WORK/udev3.log" \
DBRRG_DRM_GLOB="$WORK/sys3/card[0-9]*" \
PATH="$WORK/stubs:$PATH" \
    "$WAITKMS" >"$WORK/out3" 2>"$WORK/err3"
rc=$?
if [[ "$rc" == "0" ]] && grep -q 'udev did not finish' "$WORK/err3"; then
    ok "udevadm timeout does not fail wait-kms, and it reports the timeout"
else
    bad "udevadm failure case: exit $rc, stderr: $(cat "$WORK/err3")"
fi

# --- 2. per-machine network config outside the session ---
SO=overlay/usr/lib/dracut/modules.d/90dbrrg/setup-overlay.sh
l_restore=$(grep -n 'restore_home' "$SO" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
l_net=$(grep -n 'install_local_network' "$SO" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
if [[ -n "$l_restore" && -n "$l_net" && "$l_net" -gt "$l_restore" ]]; then
    ok "setup-overlay.sh calls install_local_network after restore_home"
else
    bad "setup-overlay.sh must call install_local_network after restore_home (restore=$l_restore net=$l_net)"
fi

# git cannot carry mode 0600, so assert the Dockerfile sets it; the mode of
# the built image is checked in test-session-packages.sh.
if grep -Eq 'chmod 600 /etc/netplan/\*\.yaml' containers/ubuntu/Dockerfile; then
    ok "Dockerfile sets /etc/netplan/*.yaml to mode 600"
else
    bad "Dockerfile must chmod 600 /etc/netplan/*.yaml (netplan: permissions too open)"
fi

RC=overlay/home/tluser/.dbrrg-sessionrc
if ! grep -q 'sudo netplan apply' "$RC"; then
    ok ".dbrrg-sessionrc no longer tells the user to run netplan apply"
else
    bad ".dbrrg-sessionrc still contains sudo netplan apply"
fi
if grep -q 'wifi.yaml' "$RC" && grep -q 'wg0.conf' "$RC"; then
    ok ".dbrrg-sessionrc mentions wifi.yaml and wg0.conf"
else
    bad ".dbrrg-sessionrc must mention wifi.yaml and wg0.conf"
fi

# A unit that copies the files cannot work: the netplan systemd generator
# emits netplan-wpa-<iface>.service when systemd starts, before any unit
# runs, so files installed later get .network files but no WPA unit.
if [[ ! -e overlay/etc/systemd/system/dbrrg-local-network.service ]]; then
    ok "no dbrrg-local-network.service (the copy belongs in the initramfs)"
else
    bad "dbrrg-local-network.service exists; it runs too late for the netplan generator"
fi

exit $fail
