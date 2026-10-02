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
dbrrg_log() { :; }
die()  { echo "die: $*" >>"$WORK/deaths"; return 1; }
: >"$WORK/warnings"
: >"$WORK/deaths"

# dbrrg-lib.sh guards its body with "if [ -z "$_DBRRG_LIB_LOADED" ]", which
# under bash's `set -u` needs the variable to already exist (even unset) or
# referencing it aborts the script before the guard can even run.
_DBRRG_LIB_LOADED=""

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

# Valid gzip that is not a tar: decompresses cleanly, lists no members, and
# GNU tar exits 0 on it. Without an explicit member check this reports a
# successful restore having restored nothing - see the comment in
# dbrrg_restore_home_from_file for why that is worse than it sounds.
printf 'gzipped, but not a tar archive' | gzip > "$WORK/gz-not-tar.tar.gz"
mkdir -p "$WORK/newroot7/home/tluser"
echo "shipped-default" >"$WORK/newroot7/home/tluser/.bashrc"
if dbrrg_restore_home_from_file "$WORK/gz-not-tar.tar.gz" \
        "$WORK/newroot7/home/tluser" 2>/dev/null; then
    bad "restore_home_from_file reported success on a valid-gzip non-tar payload"
else
    ok "restore_home_from_file rejects a valid-gzip non-tar payload"
fi
if [[ "$(cat "$WORK/newroot7/home/tluser/.bashrc")" == "shipped-default" ]]; then
    ok "valid-gzip non-tar payload leaves the default home intact"
else
    bad "valid-gzip non-tar payload damaged the default home"
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
if [[ "$(cat "$WORK/usb/state/home-restore" 2>/dev/null)" == "ok" ]]; then
    ok "restore_home records 'ok' after a successful USB restore"
else
    bad "restore_home did not record 'ok' after a successful USB restore (got: $(cat "$WORK/usb/state/home-restore" 2>/dev/null))"
fi

# USB boot, corrupt archive: dbrrg-save-home must NOT be allowed to save
# over the good archive with this default home, so the marker is "failed",
# not "absent" - there WAS something at the archive path, it just did not
# restore.
mkdir -p "$WORK/usbcorrupt/efi" "$WORK/usbcorrupt/state" "$WORK/usbcorrupt/newroot/home/tluser"
echo "this is not a tarball" >"$WORK/usbcorrupt/efi/home.tar.gz"
if restore_home "$WORK/usbcorrupt/newroot" "$WORK/usbcorrupt/efi" \
        "$WORK/usbcorrupt/state" "tl/ramroot.sqsh"; then
    ok "restore_home returns 0 on a corrupt USB archive"
else
    bad "restore_home returned non-zero on a corrupt USB archive"
fi
if [[ "$(cat "$WORK/usbcorrupt/state/home-restore" 2>/dev/null)" == "failed" ]]; then
    ok "restore_home records 'failed' for a corrupt USB archive"
else
    bad "restore_home did not record 'failed' for a corrupt USB archive (got: $(cat "$WORK/usbcorrupt/state/home-restore" 2>/dev/null))"
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
if [[ "$(cat "$WORK/net/state/home-restore" 2>/dev/null)" == "ok" ]]; then
    ok "restore_home records 'ok' after a successful netboot restore"
else
    bad "restore_home did not record 'ok' after a successful netboot restore (got: $(cat "$WORK/net/state/home-restore" 2>/dev/null))"
fi

# Netboot, server 404s: the ordinary first-netboot case for a machine the
# server has never seen, not a fault - "absent", and saving at logout is
# correct.
mkdir -p "$WORK/net404/efi" "$WORK/net404/state" "$WORK/net404/newroot/home/tluser"
echo "de:ad:be:ef:00:02" >"$WORK/net404/state/boot-mac"
DBRRG_TEST_CURL_MODE=notfound
if restore_home "$WORK/net404/newroot" "$WORK/net404/efi" "$WORK/net404/state" \
        "http://boot.example.org/tl/ramroot.sqsh"; then
    ok "restore_home returns 0 on a netboot 404"
else
    bad "restore_home returned non-zero on a netboot 404"
fi
if [[ "$(cat "$WORK/net404/state/home-restore" 2>/dev/null)" == "absent" ]]; then
    ok "restore_home records 'absent' for a netboot 404"
else
    bad "restore_home did not record 'absent' for a netboot 404 (got: $(cat "$WORK/net404/state/home-restore" 2>/dev/null))"
fi

# Netboot, server times out: something was presumably there and it could not
# be fetched - "failed", so dbrrg-save-home must not overwrite it.
mkdir -p "$WORK/nettimeout/efi" "$WORK/nettimeout/state" "$WORK/nettimeout/newroot/home/tluser"
echo "de:ad:be:ef:00:03" >"$WORK/nettimeout/state/boot-mac"
DBRRG_TEST_CURL_MODE=timeout
if restore_home "$WORK/nettimeout/newroot" "$WORK/nettimeout/efi" \
        "$WORK/nettimeout/state" "http://boot.example.org/tl/ramroot.sqsh"; then
    ok "restore_home returns 0 on a netboot timeout"
else
    bad "restore_home returned non-zero on a netboot timeout"
fi
if [[ "$(cat "$WORK/nettimeout/state/home-restore" 2>/dev/null)" == "failed" ]]; then
    ok "restore_home records 'failed' for a netboot timeout"
else
    bad "restore_home did not record 'failed' for a netboot timeout (got: $(cat "$WORK/nettimeout/state/home-restore" 2>/dev/null))"
fi
DBRRG_TEST_CURL_MODE=ok

# Netboot with no recorded MAC: skip, do not guess. Guessing is exactly the
# failure this design removed - a wrong key means the home is posted where
# it will never be found again. No boot MAC is a fault in the boot itself,
# not a normal "nothing to restore", so the marker is "failed".
mkdir -p "$WORK/nomac/efi" "$WORK/nomac/state" "$WORK/nomac/newroot/home/tluser"
if restore_home "$WORK/nomac/newroot" "$WORK/nomac/efi" "$WORK/nomac/state" \
        "http://boot.example.org/tl/ramroot.sqsh"; then
    ok "restore_home returns 0 when no boot MAC was recorded"
else
    bad "restore_home returned non-zero with no boot MAC"
fi
if [[ "$(cat "$WORK/nomac/state/home-restore" 2>/dev/null)" == "failed" ]]; then
    ok "restore_home records 'failed' when no boot MAC was recorded"
else
    bad "restore_home did not record 'failed' with no boot MAC (got: $(cat "$WORK/nomac/state/home-restore" 2>/dev/null))"
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
if [[ "$(cat "$WORK/fail/state/home-restore" 2>/dev/null)" == "absent" ]]; then
    ok "restore_home records 'absent' when the USB archive is absent"
else
    bad "restore_home did not record 'absent' for a missing USB archive (got: $(cat "$WORK/fail/state/home-restore" 2>/dev/null))"
fi
DBRRG_TEST_CURL_MODE=ok

if [[ ! -s "$WORK/deaths" ]]; then
    ok "restore_home never calls die()"
else
    bad "restore_home called die(): $(cat "$WORK/deaths")"
fi

# --- install_local_network ---
WGUNIT=/usr/lib/systemd/system/wg-quick@.service

mkhome() {  # mkhome <name>: fake newroot with a home, prints its path
    mkdir -p "$WORK/$1/home/tluser"
    echo "$WORK/$1"
}

nr=$(mkhome net-both)
echo "network: {version: 2}" >"$nr/home/tluser/wifi.yaml"
echo "[Interface]" >"$nr/home/tluser/wg0.conf"
install_local_network "$nr"; rc=$?
[[ $rc -eq 0 ]] && ok "install_local_network returns 0 with both files"     || bad "install_local_network returned $rc with both files"
if cmp -s "$nr/home/tluser/wifi.yaml" "$nr/etc/netplan/wifi.yaml" \
        && [[ "$(stat -c%a "$nr/etc/netplan/wifi.yaml")" == 600 ]]; then
    ok "wifi.yaml copied to etc/netplan, mode 600"
else
    bad "wifi.yaml not copied intact with mode 600"
fi
[[ "$(stat -c%a "$nr/etc/wireguard" 2>/dev/null)" == 700 ]] \
    && ok "etc/wireguard is mode 700" || bad "etc/wireguard is not mode 700"
if cmp -s "$nr/home/tluser/wg0.conf" "$nr/etc/wireguard/wg0.conf" \
        && [[ "$(stat -c%a "$nr/etc/wireguard/wg0.conf")" == 600 ]]; then
    ok "wg0.conf copied to etc/wireguard, mode 600"
else
    bad "wg0.conf not copied intact with mode 600"
fi
wl="$nr/etc/systemd/system/multi-user.target.wants/wg-quick@wg0.service"
if [[ -L "$wl" && "$(readlink "$wl")" == "$WGUNIT" ]]; then
    ok "wg-quick@wg0 wants symlink points at the template unit"
else
    bad "wg-quick@wg0 wants symlink missing or wrong"
fi

nr=$(mkhome net-none)
install_local_network "$nr"; rc=$?
if [[ $rc -eq 0 && ! -e "$nr/etc/netplan/wifi.yaml" && ! -e "$nr/etc/wireguard" \
        && ! -L "$nr/etc/systemd/system/multi-user.target.wants/wg-quick@wg0.service" ]]; then
    ok "no files: returns 0 and creates nothing"
else
    bad "no files: rc=$rc or something was created"
fi

nr=$(mkhome net-wg)
echo "[Interface]" >"$nr/home/tluser/wg0.conf"
install_local_network "$nr"; rc=$?
if [[ $rc -eq 0 && ! -e "$nr/etc/netplan/wifi.yaml" \
        && -f "$nr/etc/wireguard/wg0.conf" \
        && -L "$nr/etc/systemd/system/multi-user.target.wants/wg-quick@wg0.service" ]]; then
    ok "wg0.conf alone installs the WireGuard half only"
else
    bad "wg0.conf alone: rc=$rc, wrong result"
fi

nr=$(mkhome net-symlink)
echo secret >"$WORK/target.yaml"
ln -s "$WORK/target.yaml" "$nr/home/tluser/wifi.yaml"
install_local_network "$nr"; rc=$?
if [[ $rc -eq 0 && ! -e "$nr/etc/netplan/wifi.yaml" ]]; then
    ok "symlinked wifi.yaml is rejected, returns 0"
else
    bad "symlinked wifi.yaml was installed or rc=$rc"
fi

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - initramfs home helpers"
    exit 1
fi

echo ""
echo "PASSED - initramfs home helpers"
exit 0
