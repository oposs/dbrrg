#!/bin/bash
# Assert that a headless QEMU boot log shows a healthy boot.
#
# Usage: scripts/check-boot-smoke.sh path/to/qemu-smoke.log
#        scripts/check-boot-smoke.sh --reached path/to/qemu-smoke.log
#
# --reached only answers whether the boot has got as far as the multi-user
# target yet, silently, by exit status. scripts/run-qemu-smoke.sh polls it to
# stop the VM early; it uses the same test as the full check below, so the
# runner cannot stop a boot on a signal this check would then reject.

set -uo pipefail

# Boot completion is asserted against EITHER signal, because the first one is
# not reliably present.
#
# systemd writes "Reached target multi-user.target" to the console at the same
# moment serial-getty starts on that same console, and agetty opens with a
# terminal reset (ESC[!p ESC]104 ESC[?7h ESC[1G ESC[0J) that can overwrite the
# line mid-write. It is a race between two writers on one serial line, so the
# line is present on some boots and shredded on others - a false FAIL on a
# perfectly good image, observed once with the boot otherwise complete.
#
# "Startup finished in ..." is systemd's own completion message, emitted when
# the default target is reached, and is not subject to that race. Either one
# proves userspace came up; both are absent on a boot that genuinely hung, so
# this still fails closed.
reached_multi_user() {
    grep -qaE -- 'Reached target.*[Mm]ulti-[Uu]ser' "$1" ||
        grep -qaE -- 'Startup finished in' "$1"
}

if [[ "${1:-}" == "--reached" ]]; then
    [[ -s "${2:-}" ]] && reached_multi_user "$2"
    exit
fi

LOG="${1:?usage: check-boot-smoke.sh LOGFILE}"

if [[ ! -s "$LOG" ]]; then
    echo "FAIL: $LOG is empty - the VM produced no serial output" >&2
    exit 1
fi

fail=0

want() {
    if grep -qE -- "$2" "$LOG"; then
        echo "ok   - $1"
    else
        echo "FAIL - $1 (no match for: $2)"
        fail=1
    fi
}

unwant() {
    if grep -qE -- "$2" "$LOG"; then
        echo "FAIL - $1"
        grep -nE -- "$2" "$LOG" | head -3 | sed 's/^/         /'
        fail=1
    else
        echo "ok   - $1"
    fi
}

# See reached_multi_user() above for why either of two signals counts.
if reached_multi_user "$LOG"; then
    echo "ok   - reached multi-user target"
else
    echo "FAIL - reached multi-user target (no 'Reached target multi-user' and no 'Startup finished in')"
    fail=1
fi

unwant "no i915 DMC firmware error"  'Failed to load DMC firmware'
unwant "no GuC firmware error"       'GuC firmware.*fetch failed'
unwant "GPU not wedged"              'declaring it wedged'
unwant "no dracut emergency shell"   'Entering emergency mode|dracut: FATAL'
unwant "no kernel panic"             'Kernel panic'
unwant "no systemd ordering cycle"   'Found ordering cycle'

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - boot log shows problems (full log: $LOG)"
    exit 1
fi

echo ""
echo "PASSED - clean boot"
exit 0
