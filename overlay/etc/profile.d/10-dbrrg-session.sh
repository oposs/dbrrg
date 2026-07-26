# Start the Wayland session after autologin on the first VT.
#
# labwc -S runs the given command on startup and terminates when it exits,
# so the compositor's lifetime is exactly the session's lifetime.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec labwc -S /usr/local/bin/dbrrg-session
fi
