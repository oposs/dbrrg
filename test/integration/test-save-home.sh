#!/bin/bash
# Offline tests for dbrrg-save-home.
#
# The archive must come from tluser's home, whatever $HOME says. upgrade-image
# re-execs itself under sudo and then calls this script, and sudo's env_reset
# sets HOME to the target user's home: with no env_keep for HOME in
# /etc/sudoers, that is /root. A save triggered that way archived root's
# dotfiles over the machine's home.tar.gz, and because /root holds a .bashrc
# the result was a valid archive that the next boot's restore accepted,
# replacing the user's home and ~/.dbrrg-ssh-host-keys with no error anywhere.
#
# Runs without root: tar, curl, ping and sudo are stubbed and their calls
# recorded. Layout is redirected via DBRRG_HOME_DIR / DBRRG_STATE_DIR /
# DBRRG_CMDLINE.
#
# Usage: test/integration/test-save-home.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/overlay/usr/bin/dbrrg-save-home"

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

# tar records the directory it was invoked in, which is the whole point of
# these tests, and creates its output file so the script's later rm succeeds.
cat >"$STUBS/tar" <<'STUB'
#!/bin/bash
{ echo "tar $*"; echo "PWD=$PWD"; } >>"$DBRRG_TEST_TAR_LOG"
# Only the argument after a -f / -zcf style flag is an output file; --exclude=
# patterns also contain slashes and must not be created.
prev=""
for a in "$@"; do
    case "$prev" in
        -*f) [ "$a" = "-" ] || : >"$a" ;;
    esac
    prev="$a"
done
exit "${DBRRG_TEST_TAR_RC:-0}"
STUB

cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >>"$DBRRG_TEST_CURL_LOG"
exit 0
STUB

# The real mountpoint(1) needs a real mount. The test ESP is a plain directory;
# it counts as mounted only when it holds a .test-mounted marker.
cat >"$STUBS/mountpoint" <<'STUB'
#!/bin/bash
[ "$1" = "-q" ] && shift
[ -e "$1/.test-mounted" ]
STUB

cat >"$STUBS/ping" <<'STUB'
#!/bin/bash
exit 0
STUB

# sudo runs only the commands the USB branch uses to write the ESP (tar, gzip,
# mv, rm), resolved through PATH so the stubbed tar and gzip are used;
# without that the atomicity test would be vacuous. Everything else, such as
# dbrrg-ssh-hostkeys --stage, mount, dd and sync (a real sync would flush the
# shared host), is logged and swallowed because an
# unprivileged test may not perform it.
cat >"$STUBS/sudo" <<'STUB'
#!/bin/bash
echo "sudo $*" >>"$DBRRG_TEST_SUDO_LOG"
case "${1:-}" in
    tar|gzip|mv|rm) exec "$@" ;;
esac
exit 0
STUB

# Only -t (test) is used by the script. Report the archive as valid unless the
# test asked for a corrupt one.
cat >"$STUBS/gzip" <<'STUB'
#!/bin/bash
[ -n "${DBRRG_TEST_GZIP_FAIL:-}" ] && exit 1
exit 0
STUB

# The unreachable-server loop sleeps 1s per attempt; do not wait it out.
cat >"$STUBS/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB

chmod +x "$STUBS"/*

run_save_home() {
    # $1 = value for HOME, $2 = value for DBRRG_HOME_DIR
    DBRRG_TEST_TAR_LOG="$WORK/tar.log" \
    DBRRG_TEST_CURL_LOG="$WORK/curl.log" \
    DBRRG_TEST_SUDO_LOG="$WORK/sudo.log" \
    HOME="$1" \
    DBRRG_HOME_DIR="$2" \
    DBRRG_STATE_DIR="$WORK/state" \
    DBRRG_CMDLINE="$WORK/cmdline" \
    DBRRG_EFI_MOUNT="${DBRRG_EFI_MOUNT_OVERRIDE:-/run/dbrrg/storage/efi}" \
    DBRRG_EXCLUDE_DEFAULT="${DBRRG_EXCLUDE_DEFAULT_OVERRIDE:-/etc/dbrrg/save-home-exclude}" \
    DBRRG_TEST_GZIP_FAIL="${DBRRG_TEST_GZIP_FAIL:-}" \
    DBRRG_TEST_TAR_RC="${DBRRG_TEST_TAR_RC:-0}" \
    PATH="$STUBS:$PATH" \
        "$SCRIPT" </dev/null >"$WORK/out" 2>"$WORK/err"
    echo $?
}

setup() {
    rm -rf "$WORK/home" "$WORK/root" "$WORK/state" \
           "$WORK/tar.log" "$WORK/curl.log" "$WORK/sudo.log"
    mkdir -p "$WORK/home/tluser" "$WORK/root" "$WORK/state"
    echo "the user's wifi password" >"$WORK/home/tluser/.dbrrg-sessionrc"
    echo "root's shell config"      >"$WORK/root/.bashrc"
    # Netboot: a boot server in the cmdline selects the upload path, which
    # needs no block device and so runs unprivileged.
    echo "ro ramroot=http://boot.example/dbrrg/ramroot.sqsh quiet" \
        >"$WORK/cmdline"
}

# ---------------------------------------------------------------- test 1
setup
rc=$(run_save_home "$WORK/root" "$WORK/home/tluser")
archived=$(sed -n 's/^PWD=//p' "$WORK/tar.log" 2>/dev/null | head -1)
if [[ "$archived" == "$WORK/home/tluser" ]]; then
    ok "archives tluser's home when HOME points at /root"
else
    bad "archives tluser's home when HOME points at /root (archived '$archived', exit $rc)"
fi

# ---------------------------------------------------------------- test 2
setup
rc=$(run_save_home "$WORK/root" "$WORK/does-not-exist")
if [[ "$rc" != "0" ]] && [[ ! -s "$WORK/tar.log" ]] &&
   grep -q "refusing to save" "$WORK/err"; then
    ok "refuses to save when the resolved home is missing"
else
    bad "refuses to save when the resolved home is missing (exit $rc, tar log $(wc -c <"$WORK/tar.log" 2>/dev/null || echo 0) bytes)"
fi

# ---------------------------------------------------------------- test 3
# A USB boot records no boot-home-base: restore_home() writes it only on the
# netboot branch (dbrrg-lib.sh:323-357). Reading it under `set -e` with no
# `|| true` ended the script on its second line, so a USB machine saved
# nothing at logout and lost every change made that session.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
rc=$(run_save_home "$WORK/root" "$WORK/home/tluser")
if grep -q "dbrrg-ssh-hostkeys" "$WORK/sudo.log" 2>/dev/null; then
    ok "keeps going on a USB boot that recorded no boot-home-base"
else
    bad "keeps going on a USB boot that recorded no boot-home-base (exit $rc, stderr: $(head -1 "$WORK/err" 2>/dev/null))"
fi

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
# No boot server in the cmdline and no ESP mount: this machine has nowhere to
# put a home. It used to print "home saved" and exit 0 on this path.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/no-such-mount" \
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
# A stub cannot emulate an HTTP status, so the honest check is that curl is
# asked to fail on one (-f); without it a 413/500 reply exits 0.
if grep -qE '^curl (.* )?-f( |$)|^curl -[a-zA-Z]*f' "$WORK/curl.log"; then
    ok "netboot upload passes -f so an HTTP error fails the save"
else
    bad "curl was called without -f: $(cat "$WORK/curl.log")"
fi

# --------------------------------------------------------------- test 12
# The archive is unpacked synchronously by the initramfs on every boot, so an
# unfiltered home makes every startup slower. A 233MB Claude binary did this.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
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
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
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
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
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
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
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
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
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
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
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

# --------------------------------------------------------------- test 19
# GNU tar exits 1 for "file changed as we read it". A live home triggers that,
# so status 1 with a complete archive must still be a successful save.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" DBRRG_TEST_TAR_RC=1 \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "0" ]] && [[ -f "$WORK/esp/home.tar.gz" ]] &&
   [[ ! -e "$WORK/esp/home.tar.gz.new" ]]; then
    ok "tar exit 1 (file changed) still saves"
else
    bad "tar exit 1 broke the save (exit $rc)"
fi

# --------------------------------------------------------------- test 20
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
echo "THE GOOD OLD ARCHIVE" >"$WORK/esp/home.tar.gz"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" DBRRG_TEST_TAR_RC=2 \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "5" ]] && grep -q "THE GOOD OLD ARCHIVE" "$WORK/esp/home.tar.gz"; then
    ok "tar exit 2 is a failed save and keeps the old archive"
else
    bad "tar exit 2 gave exit $rc"
fi

# --------------------------------------------------------------- test 21
# The ESP directory exists but nothing is mounted on it (the initramfs creates
# it on every boot). The archive must not land in RAM and be called saved.
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
rm -rf "$WORK/esp"; mkdir -p "$WORK/esp"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "4" ]] && ! grep -q "home saved" "$WORK/out" &&
   [[ -z "$(ls -A "$WORK/esp")" ]]; then
    ok "an existing but unmounted ESP directory exits 4 and writes nothing"
else
    bad "unmounted ESP gave exit $rc, esp: $(ls -A "$WORK/esp")"
fi

# --------------------------------------------------------------- test 22
# Both branches archive as root. The netboot branch ran tar as tluser, so one
# file in the home that tluser cannot read (a root-owned 600 file) failed
# every netboot save with exit 5 while USB saved the same home.
setup
rc=$(run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "0" ]] && grep -q '^sudo tar ' "$WORK/sudo.log" 2>/dev/null; then
    ok "netboot save runs tar through sudo, like the USB save"
else
    bad "netboot tar did not go through sudo (exit $rc, sudo log: $(cat "$WORK/sudo.log" 2>/dev/null))"
fi
setup
echo "ro ramroot=tl/ramroot.sqsh quiet" >"$WORK/cmdline"
mkdir -p "$WORK/esp" && : >"$WORK/esp/.test-mounted"
rc=$(DBRRG_EFI_MOUNT_OVERRIDE="$WORK/esp" \
     run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "0" ]] && grep -q '^sudo tar ' "$WORK/sudo.log" 2>/dev/null; then
    ok "USB save runs tar through sudo"
else
    bad "USB tar did not go through sudo (exit $rc)"
fi

# --------------------------------------------------------------- test 23
# A netboot archive that tar could not write is exit 5 and is never uploaded.
setup
rc=$(DBRRG_TEST_TAR_RC=2 run_save_home "$WORK/root" "$WORK/home/tluser")
if [[ "$rc" == "5" ]] && [[ ! -s "$WORK/curl.log" ]]; then
    ok "netboot tar exit 2 is exit 5 and uploads nothing"
else
    bad "netboot tar exit 2 gave exit $rc, curl log: $(cat "$WORK/curl.log" 2>/dev/null)"
fi

exit $fail
