#!/bin/bash
# Offline tests for format_bytes in scripts/lib/common.sh.
#
# make-bootable-image.sh printed "Bootable image created: 2GB" for the
# 3148873728-byte image (2.93 GiB), because the GB and MB branches divided
# as integers and dropped everything after the point.
#
# Usage: test/integration/test-format-bytes.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

expect() {
    local got
    got=$(bash -c 'source "$1"; format_bytes "$2"' _ "$REPO/scripts/lib/common.sh" "$1")
    if [[ "$got" == "$2" ]]; then
        ok "format_bytes $1 = $2"
    else
        bad "format_bytes $1: expected $2, got $got"
    fi
}

expect 3148873728 2.9GB   # the USB image with the 3000 MB ESP
expect 1073741824 1.0GB
expect 1020054732 972.8MB # a squashfs
expect 1048576 1.0MB
expect 1610612735 1.5GB   # rounds to nearest, not down
expect 5000 4KB
expect 512 512B

exit $fail
