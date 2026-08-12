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

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - initramfs home helpers"
    exit 1
fi

echo ""
echo "PASSED - initramfs home helpers"
exit 0
