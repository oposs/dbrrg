#!/bin/bash
# Runs labwc headless with two 1280x720 outputs and asserts that a fullscreen
# X11 client is given the union of both (2560x720), not a single output.
#
# Not part of 'make test': it needs network (python3-xlib) and runs a
# compositor. Use 'make test-runtime'.

set -uo pipefail

IMAGE="${1:-localhost/dbrrg-runtime-test:latest}"
fail=0

# labwc -S only bounds the case where the probe runs and then exits or
# crashes. If labwc or Xwayland hangs during startup - before the session
# command ever executes - 'podman run' blocks forever and so does this
# script. Cap it so that failure mode is loud instead of silent. The whole
# rig normally completes in seconds; this bound is generous on purpose.
RUNTIME_TIMEOUT=180
CONTAINER_NAME="dbrrg-runtime-test-$$"

out=$(timeout --kill-after=10 "$RUNTIME_TIMEOUT" podman run --rm --name "$CONTAINER_NAME" \
    -e WLR_BACKENDS=headless \
    -e WLR_HEADLESS_OUTPUTS=2 \
    -e WLR_RENDERER=pixman \
    -e XDG_RUNTIME_DIR=/tmp/xdg \
    "$IMAGE" \
    sh -c 'mkdir -p /tmp/xdg && chmod 700 /tmp/xdg &&
           labwc -C /etc/dbrrg/labwc -S "python3 /usr/local/bin/x11-probe.py"' 2>&1)
rc=$?

# timeout(1) exits 124 when it kills the command with the default TERM. But
# 'podman run' does not always die from TERM alone (observed: it can take
# longer than a 10s --kill-after grace period to notice), in which case
# timeout escalates to KILL and the exit status is 128+9=137 instead. Treat
# both as "timed out". Report that distinctly from a wrong-but-present
# geometry - a hang and a bad geometry mean very different things to whoever
# reads the failure - and clean up the container explicitly, since a killed
# 'podman run' may not get to run its own --rm cleanup.
if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "FAIL - podman run timed out after ${RUNTIME_TIMEOUT}s (labwc/Xwayland hang during startup)"
    echo "--- compositor output so far ---"
    echo "$out"
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    exit 1
fi

geom=$(echo "$out" | grep -o 'GEOMETRY [0-9]*x[0-9]*' | tail -1 | cut -d' ' -f2)

if [[ "$geom" == "2560x720" ]]; then
    echo "ok   - fullscreen X11 window spans both outputs ($geom)"
else
    echo "FAIL - fullscreen X11 window is $geom, expected 2560x720"
    echo "--- compositor output ---"
    echo "$out"
    fail=1
fi

exit $fail
