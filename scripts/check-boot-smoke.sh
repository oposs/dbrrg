#!/bin/bash
# Assert that a headless QEMU boot log shows a healthy boot.
#
# Usage: scripts/check-boot-smoke.sh path/to/qemu-smoke.log

set -uo pipefail

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

want   "reached multi-user target"   'Reached target.*[Mm]ulti-[Uu]ser'
unwant "no i915 DMC firmware error"  'Failed to load DMC firmware'
unwant "no GuC firmware error"       'GuC firmware.*fetch failed'
unwant "GPU not wedged"              'declaring it wedged'
unwant "no dracut emergency shell"   'Entering emergency mode|dracut: FATAL'
unwant "no kernel panic"             'Kernel panic'

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - boot log shows problems (full log: $LOG)"
    exit 1
fi

echo ""
echo "PASSED - clean boot"
exit 0
