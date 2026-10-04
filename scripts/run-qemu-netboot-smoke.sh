#!/bin/bash
# Headless netboot smoke test: serve the rootfs artifacts over HTTP on the
# host, boot the kernel and initrd in QEMU with no disk and
# ramroot=http://_gateway:<port>/ramroot.sqsh, then judge the log.
#
# _gateway is a name, so the download goes through name resolution in the
# initramfs: curl -> /etc/resolv.conf -> the systemd-resolved stub. resolved
# answers _gateway itself with the default gateway, which on QEMU's user
# network is 10.0.2.2, the host. That proves a host-name ramroot URL resolves
# without depending on any DNS server outside this machine; it does not
# exercise forwarding to the DHCP-supplied DNS server.
#
# Usage: scripts/run-qemu-netboot-smoke.sh ROOTFS_DIR LOG TIMEOUT GRACE QEMU_ARGS...
#
# Beyond check-boot-smoke.sh, a netboot must show what only netboot does:
#   - the hostname is dbrrg-<last six hex digits of the boot MAC>;
#   - the initramfs asked the boot server for home.pkg under that MAC, which
#     proves /run/dbrrg/state/boot-mac was recorded. The server has no
#     archive, so the request is answered 404, the ordinary first-netboot case.

set -uo pipefail

ROOTFS_DIR="${1:?usage: run-qemu-netboot-smoke.sh ROOTFS_DIR LOG TIMEOUT GRACE QEMU_ARGS...}"
LOG="${2:?missing LOG}"
TIMEOUT="${3:?missing TIMEOUT}"
GRACE="${4:?missing GRACE}"
shift 4

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC=52:54:00:12:34:56
HOSTNAME_WANT=dbrrg-123456
HTTP_LOG="$LOG.http"

for f in vmlinuz initrd.img ramroot.sqsh; do
    [[ -f "$ROOTFS_DIR/$f" ]] || { echo "FAIL: $ROOTFS_DIR/$f missing" >&2; exit 1; }
done

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$ROOTFS_DIR" \
    >"$HTTP_LOG" 2>&1 &
srv=$!
trap 'kill "$srv" 2>/dev/null' EXIT INT TERM

# Do not boot before the server answers: a refused download is the failure
# this test exists to catch, and it must not be produced by the test itself.
for _ in $(seq 50); do
    curl -fsI "http://127.0.0.1:$port/ramroot.sqsh" >/dev/null 2>&1 && break
    sleep 0.1
done

"$HERE/run-qemu-smoke.sh" "$LOG" "$TIMEOUT" "$GRACE" -- \
    qemu-system-x86_64 "$@" \
    -netdev user,id=n0 -device "virtio-net-pci,netdev=n0,mac=$MAC" \
    -kernel "$ROOTFS_DIR/vmlinuz" -initrd "$ROOTFS_DIR/initrd.img" \
    -append "ramroot=http://_gateway:$port/ramroot.sqsh console=ttyS0,115200 systemd.unit=multi-user.target systemd.log_target=console systemd.mask=serial-getty@ttyS0.service" ||
    exit $?

kill "$srv" 2>/dev/null
wait "$srv" 2>/dev/null

"$HERE/check-boot-smoke.sh" "$LOG"
fail=$?

echo ""
echo "netboot:"
if grep -qaF "Hostname set to <$HOSTNAME_WANT>" "$LOG"; then
    echo "ok   - hostname is $HOSTNAME_WANT (last six hex digits of $MAC)"
else
    echo "FAIL - hostname is not $HOSTNAME_WANT ($(grep -aoE 'Hostname set to <[^>]*>' "$LOG" | tail -1))"
    fail=1
fi
if grep -qaF "dbrrg: network is up on " "$LOG"; then
    echo "ok   - the initramfs found the interface holding the DHCP lease"
else
    echo "FAIL - no 'dbrrg: network is up on' line"
    fail=1
fi
if grep -qaF "dbrrg: ramroot=http://_gateway:" "$LOG"; then
    echo "ok   - the cmdline hook's ramroot= line reached the console"
else
    echo "FAIL - the cmdline hook's 'dbrrg: ramroot=' line is not on the console"
    fail=1
fi
if grep -qF "GET /home.pkg?mac=$MAC " "$HTTP_LOG"; then
    echo "ok   - home.pkg was requested under the boot MAC"
else
    echo "FAIL - no home.pkg request for mac=$MAC (server log: $HTTP_LOG)"
    fail=1
fi

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - netboot smoke test (log: $LOG)"
    exit 1
fi
echo ""
echo "PASSED - netboot smoke test"
exit 0
