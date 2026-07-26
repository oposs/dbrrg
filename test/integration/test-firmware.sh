#!/bin/bash
# Regression test for the firmware-stripping bug.
#
# scripts/export-rootfs.sh used to run
#     find /usr/lib/firmware -type f -not -name "iwlwifi*" -delete
# immediately before mksquashfs. That deleted every firmware file except
# iwlwifi*, which left deployed clients without i915 GPU firmware (wedged
# GPU, no runtime power management) and without CPU microcode.
#
# Usage: test/integration/test-firmware.sh [path/to/ramroot.sqsh]

set -uo pipefail

SQSH="${1:-artifacts/rootfs/ramroot.sqsh}"

if [[ ! -f "$SQSH" ]]; then
    echo "FAIL: $SQSH not found - run 'make rootfs' first" >&2
    exit 1
fi

if ! command -v unsquashfs >/dev/null 2>&1; then
    echo "FAIL: unsquashfs not installed (apt install squashfs-tools)" >&2
    exit 1
fi

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

if ! unsquashfs -l "$SQSH" >"$LIST" 2>/dev/null; then
    echo "FAIL: cannot list $SQSH" >&2
    exit 1
fi

fail=0
check() {
    local desc="$1" pattern="$2"
    if grep -qE -- "$pattern" "$LIST"; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc (no match for: $pattern)"
        fail=1
    fi
}

# Alder Lake GPU firmware - the exact files the field dmesg reported missing.
# Files ship zstd-compressed, so the patterns intentionally omit any suffix.
check "i915 DMC firmware (adlp_dmc.bin)"     'usr/lib/firmware/i915/adlp_dmc\.bin'
check "i915 GuC firmware (adlp_guc_70.bin)"  'usr/lib/firmware/i915/adlp_guc_70\.bin'
# Deleted by the same bug: clients have never had microcode updates.
check "Intel CPU microcode"                  'usr/lib/firmware/intel-ucode/'
# On 26.04 the real iwlwifi files live under intel/iwlwifi/ with top-level
# compat symlinks; assert the real path.
check "Intel WiFi firmware"                  'usr/lib/firmware/intel/iwlwifi/iwlwifi-'
check "Intel SOF audio firmware"             'usr/lib/firmware/intel/sof/'
check "Realtek NIC firmware"                 'usr/lib/firmware/rtl_nic/'

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - shipped image is missing firmware"
    exit 1
fi

echo ""
echo "PASSED - all expected firmware present"
exit 0
