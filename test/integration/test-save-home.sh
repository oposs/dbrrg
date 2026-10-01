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
for a in "$@"; do
    case "$a" in
        -|*/*) [ "$a" = "-" ] || : >"$a" ;;
    esac
done
exit 0
STUB

cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >>"$DBRRG_TEST_CURL_LOG"
exit 0
STUB

cat >"$STUBS/ping" <<'STUB'
#!/bin/bash
exit 0
STUB

# sudo must not actually run anything here: the script calls it for
# dbrrg-ssh-hostkeys, mount and dd by absolute path, none of which an
# unprivileged test may perform.
cat >"$STUBS/sudo" <<'STUB'
#!/bin/bash
echo "sudo $*" >>"$DBRRG_TEST_SUDO_LOG"
cat >/dev/null 2>/dev/null || true
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

exit $fail
