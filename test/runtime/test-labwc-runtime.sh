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

# Rootless Xwayland forwards XGrabKeyboard via
# zwp_xwayland_keyboard_grab_manager_v1. This only asserts that Xwayland
# *binds* that global (wl_registry.bind(..., "zwp_xwayland_keyboard_grab_
# manager_v1", ...)), not that a grab_keyboard request is ever sent. That
# weaker check is deliberate, not an oversight:
#
# Xwayland only installs its grab-forwarding hook
# (setup_keyboard_grab_handler(), which overrides ActivateGrab/
# DeactivateGrab on the master keyboard device - the path that eventually
# calls zwp_xwayland_keyboard_grab_manager_v1_grab_keyboard()) once
# xwl_seat->keyboard already exists (xwayland/xwayland-input.c,
# init_keyboard_grab(), ~L3091-3106). xwl_seat->keyboard is only created in
# the seat capabilities handler (~L1847-1859) in response to the compositor
# advertising WL_SEAT_CAPABILITY_KEYBOARD. This headless rig
# (WLR_BACKENDS=headless) provides zero input devices, so wl_seat stays at
# capabilities(0) for the entire run - confirmed in the WAYLAND_DEBUG output
# both before and after this patch. wlroots' headless backend has no public
# API to synthesize one either: wlr/backend/headless.h only exposes
# wlr_headless_add_output(), no wlr_headless_add_input_device() equivalent.
#
# So Xwayland never believes it has a keyboard to grab, and grab_keyboard
# can never fire here, regardless of whether our implementation is correct.
# Do not "fix" this back to grepping for grab_keyboard - it would just make
# the assertion unfalsifiable in this rig. Real XGrabKeyboard forwarding is
# unverified until tested on real hardware with a real keyboard attached.
GRAB_CONTAINER_NAME="dbrrg-runtime-test-grab-$$"

grab_out=$(timeout --kill-after=10 "$RUNTIME_TIMEOUT" podman run --rm --name "$GRAB_CONTAINER_NAME" \
    -e WLR_BACKENDS=headless \
    -e WLR_HEADLESS_OUTPUTS=2 \
    -e WLR_RENDERER=pixman \
    -e XDG_RUNTIME_DIR=/tmp/xdg \
    -e WAYLAND_DEBUG=1 \
    "$IMAGE" \
    sh -c 'mkdir -p /tmp/xdg && chmod 700 /tmp/xdg &&
           labwc -C /etc/dbrrg/labwc -S "python3 /usr/local/bin/x11-probe.py --grab"' 2>&1)
grab_rc=$?

if [[ $grab_rc -eq 124 || $grab_rc -eq 137 ]]; then
    echo "FAIL - podman run timed out after ${RUNTIME_TIMEOUT}s (labwc/Xwayland hang during startup)"
    echo "--- compositor output so far ---"
    echo "$grab_out"
    podman rm -f "$GRAB_CONTAINER_NAME" >/dev/null 2>&1
    exit 1
fi

# The interface/id separator in WAYLAND_DEBUG output changed between
# libwayland versions: 1.22 and earlier print "wl_registry@N", 1.24 (shipped
# in this image) prints "wl_registry#N". Accept either rather than pinning
# to whichever the base image currently ships.
if echo "$grab_out" | grep -Eq 'wl_registry[@#][0-9]+\.bind\([0-9]+, "zwp_xwayland_keyboard_grab_manager_v1"'; then
    echo "ok   - Xwayland bound the xwayland keyboard grab manager"
else
    echo "FAIL - labwc is not advertising the manager to Xwayland"
    echo "--- compositor output ---"
    echo "$grab_out"
    fail=1
fi

exit $fail
