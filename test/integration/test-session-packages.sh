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
present "session script"   'usr/local/bin/dbrrg-session$'
present "restore-home"     'usr/local/bin/dbrrg-restore-home$'
present "labwc rc.xml"     'home/tluser/\.config/labwc/rc\.xml$'
present "tty1 autologin"   'getty@tty1\.service\.d/autologin\.conf$'

absent  "Xorg server"      'usr/lib/xorg/Xorg$'
absent  "nodm"             'usr/sbin/nodm$'
absent  "wm2"              'usr/bin/wm2$'
absent  "lxterminal"       'usr/bin/lxterminal$'

# Guard the standing constraint: labwc must register no keybindings, because
# it does not implement zwp_keyboard_shortcuts_inhibit_manager_v1 and any
# binding it owns can never reach the remote ThinLinc session.
RC=$(mktemp -d)
trap 'rm -rf "$LIST" "$RC"' EXIT
if unsquashfs -q -f -d "$RC" "$SQSH" 'home/tluser/.config/labwc/rc.xml' >/dev/null 2>&1; then
    if grep -qE '<keybind|<default */>' "$RC/home/tluser/.config/labwc/rc.xml"; then
        echo "FAIL - rc.xml registers keybindings (breaks remote key passthrough)"
        fail=1
    else
        echo "ok   - rc.xml registers no keybindings"
    fi
else
    echo "FAIL - could not extract rc.xml from image"
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
