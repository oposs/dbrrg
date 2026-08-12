#!/bin/bash
# Asserts the Wayland session stack shipped and the X11 stack did not.
#
# Usage: test/integration/test-session-packages.sh [path/to/ramroot.sqsh]

set -uo pipefail

SQSH="${1:-artifacts/rootfs/ramroot.sqsh}"

if [[ ! -f "$SQSH" ]]; then
    echo "FAIL: $SQSH not found - run 'make rootfs' first" >&2
    exit 1
fi

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
unsquashfs -l "$SQSH" >"$LIST" 2>/dev/null || { echo "FAIL: cannot list $SQSH" >&2; exit 1; }

fail=0
present() {
    if grep -qE -- "$2" "$LIST"; then
        echo "ok   - $1 present"
    else
        echo "FAIL - $1 missing (no match for: $2)"
        fail=1
    fi
}
absent() {
    if grep -qE -- "$2" "$LIST"; then
        echo "FAIL - $1 should have been removed (matched: $2)"
        fail=1
    else
        echo "ok   - $1 absent"
    fi
}

present "labwc"            'usr/bin/labwc$'
present "Xwayland"         'usr/bin/Xwayland$'
present "foot"             'usr/bin/foot$'
present "grim"             'usr/bin/grim$'
present "slurp"            'usr/bin/slurp$'
present "wl-copy"          'usr/bin/wl-copy$'
present "waybar"           'usr/bin/waybar$'
present "waybar config"    'etc/dbrrg/waybar/config\.jsonc$'
present "waybar style"     'etc/dbrrg/waybar/style\.css$'
absent  "waybar user unit enabled" 'systemd/user/graphical-session\.target\.wants/waybar\.service$'
present "session script"    'usr/bin/dbrrg-session$'
present "save-home"         'usr/bin/dbrrg-save-home$'
present "labwc config merge" 'usr/bin/dbrrg-compose-labwc-config$'
absent  "restore-home script" 'usr/local/bin/dbrrg-restore-home$'
absent  "old save-home path"  'opt/thinlinc/bin/save-home$'
present "labwc rc.xml"     'etc/dbrrg/labwc/rc\.xml$'
present "tty1 autologin"   'getty@tty1\.service\.d/autologin\.conf$'
present "ssh host key helper" 'usr/bin/dbrrg-ssh-hostkeys$'
present "ssh host key unit"   'dbrrg-ssh-hostkeys\.service$'
absent  "old regenerate unit" 'regenerate_ssh_host_keys\.service$'

absent  "Xorg server"      'usr/lib/xorg/Xorg$'
absent  "nodm"             'usr/sbin/nodm$'
absent  "wm2"              'usr/bin/wm2$'
absent  "lxterminal"       'usr/bin/lxterminal$'

# Guard the standing constraint: labwc must register no keybindings. Rootless
# Xwayland never requests zwp_keyboard_shortcuts_inhibit_manager_v1 (that was
# this repo's earlier, disproved explanation); the mechanism that matters is
# zwp_xwayland_keyboard_grab_manager_v1, which our labwc now implements but
# which remains unverified on real hardware - so any binding it owns can
# still never reach the remote ThinLinc session. See CLAUDE.md's "labwc must
# have zero keybindings".
RC=$(mktemp -d)
trap 'chmod -R u+rwX "$RC" 2>/dev/null; rm -rf "$LIST" "$RC"' EXIT
unsquashfs -q -f -d "$RC" "$SQSH" 'etc/dbrrg/labwc/rc.xml' >/dev/null 2>&1
# Test for the extracted FILE, not unsquashfs's exit code: extracting a path
# that does not exist in the image still exits 0 (it simply extracts nothing).
# Trusting that exit code made this guard pass vacuously - grep on a missing
# file exits 2, the inner test went false, and the suite printed
# "rc.xml registers no keybindings" for an image that had no rc.xml at all.
if [[ ! -f "$RC/etc/dbrrg/labwc/rc.xml" ]]; then
    echo "FAIL - rc.xml is not present in the image at all"
    fail=1
elif grep -qE '<keybind|<default */>' "$RC/etc/dbrrg/labwc/rc.xml"; then
    echo "FAIL - rc.xml registers keybindings (breaks remote key passthrough)"
    fail=1
else
    echo "ok   - rc.xml registers no keybindings"
fi

# The labwc in the image must be our local rebuild, not the archive version.
# Guards against the labwc-build stage silently dropping out of the image.
DPKG_TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$RC" "$DPKG_TMP" 2>/dev/null; rm -f "$LIST"; rm -rf "$RC" "$DPKG_TMP"' EXIT
if unsquashfs -no-xattrs -d "$DPKG_TMP/x" "$SQSH" var/lib/dpkg/status >/dev/null 2>&1; then
    labwc_version=$(awk '/^Package: labwc$/{f=1} f&&/^Version:/{print $2; exit}' \
        "$DPKG_TMP/x/var/lib/dpkg/status")
    if [[ "$labwc_version" == *"+dbrrg1" ]]; then
        echo "ok   - labwc is the local rebuild ($labwc_version)"
    else
        echo "FAIL - labwc is '$labwc_version', expected a +dbrrg1 rebuild"
        fail=1
    fi
else
    echo "FAIL - cannot extract var/lib/dpkg/status from $SQSH"
    fail=1
fi

present "fullscreen span enabled in labwc environment" \
        "etc/dbrrg/labwc/environment"
if unsquashfs -no-xattrs -d "$DPKG_TMP/env" "$SQSH" \
        etc/dbrrg/labwc/environment >/dev/null 2>&1 &&
   grep -q '^LABWC_FULLSCREEN_SPAN_OUTPUTS=1' \
        "$DPKG_TMP/env/etc/dbrrg/labwc/environment"; then
    echo "ok   - LABWC_FULLSCREEN_SPAN_OUTPUTS is set"
else
    echo "FAIL - LABWC_FULLSCREEN_SPAN_OUTPUTS not set in the shipped environment"
    fail=1
fi

# Rootless Xwayland forwards X11 keyboard grabs via
# zwp_xwayland_keyboard_grab_manager_v1; without it a compositor never learns
# about an XGrabKeyboard call at all. Confirm the shipped binary implements
# the protocol (a static string check, not proof it works - test-runtime's
# headless rig only proves Xwayland binds the manager global, since it has
# no input devices to generate a real grab; see the comment in
# test/runtime/test-labwc-runtime.sh for why a grab_keyboard assertion isn't
# possible there).
if unsquashfs -no-xattrs -d "$DPKG_TMP/bin" "$SQSH" usr/bin/labwc >/dev/null 2>&1 &&
   grep -aq 'zwp_xwayland_keyboard_grab_manager_v1' "$DPKG_TMP/bin/usr/bin/labwc"; then
    echo "ok   - labwc implements zwp_xwayland_keyboard_grab_manager_v1"
else
    echo "FAIL - shipped labwc has no xwayland keyboard grab support"
    fail=1
fi

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

# Masking alone is not enough to prove sshd can still start: Ubuntu's
# ssh.socket declares RequiredBy=ssh.service, so if that requires-symlink
# is still present, ssh.service fails outright with "Unit ssh.socket is
# masked" - a mask-only check would pass on a broken image. ssh.socket must
# be *disabled* (which removes this symlink) before it is masked.
# Anchored to etc/systemd/system deliberately. An unanchored check also
# matches var/lib/systemd/deb-systemd-helper-enabled/ssh.service.requires/
# ssh.socket, which is dpkg's own record of what it once enabled - not live
# systemd config. It survives `systemctl disable` by design and must not
# fail this test. (An earlier version of this check extracted the live path
# with `unsquashfs -d`, which is just as wrong a different way: extracting a
# single nonexistent path still exits 0, so the check always "passed"
# extraction and reported FAIL regardless of whether the file existed.)
#
# What this asserts is the thing that decides whether sshd can start at all:
# ssh.socket declares RequiredBy=ssh.service, so if enabling it left
# etc/systemd/system/ssh.service.requires/ssh.socket behind, masking the
# socket makes ssh.service fail with "Unit ssh.socket is masked" and the
# image has no sshd. Checking only that the mask exists would pass on
# exactly that broken image.
if unsquashfs -l "$SQSH" 2>/dev/null | \
        grep -qE '^squashfs-root/etc/systemd/system/ssh\.service\.requires/ssh\.socket$'; then
    echo "FAIL - etc/systemd/system/ssh.service.requires/ssh.socket survives; ssh.service cannot start"
    fail=1
else
    echo "ok   - ssh.service has no Requires on the masked ssh.socket"
fi

# sshd-keygen.service ships Wants=-enabled from BOTH ssh.socket.wants/ and
# ssh.service.wants/; disabling ssh.socket only removes the first symlink.
# Left unmasked it races dbrrg-ssh-hostkeys.service on a genuine first boot
# and can win, leaving generated keys unstaged and lost on the next reboot.
if unsquashfs -no-xattrs -d "$DPKG_TMP/keygen" "$SQSH" \
        etc/systemd/system/sshd-keygen.service >/dev/null 2>&1 &&
   [[ -L "$DPKG_TMP/keygen/etc/systemd/system/sshd-keygen.service" ]] &&
   [[ "$(readlink "$DPKG_TMP/keygen/etc/systemd/system/sshd-keygen.service")" == "/dev/null" ]]; then
    echo "ok   - sshd-keygen.service is masked"
else
    echo "FAIL - sshd-keygen.service is not masked - it can race dbrrg-ssh-hostkeys.service on first boot"
    fail=1
fi

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

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - session stack is not as expected"
    exit 1
fi

echo ""
echo "PASSED - Wayland session stack correct"
exit 0
