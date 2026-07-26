# Start the Wayland session after autologin on the first VT.
#
# labwc -S runs the given command on startup and terminates when it exits,
# so the compositor's lifetime is exactly the session's lifetime.
#
# -C points labwc at a config directory outside $HOME. $HOME is captured
# wholesale into home.tar.gz by save-home and restored wholesale by
# dbrrg-restore-home on every login, with no excludes. A config file kept
# under $HOME would therefore be pinned forever on an already-deployed
# machine - including the rc.xml that enforces the zero-keybindings
# constraint - and a corrected file shipped in a future image would never
# reach it.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec labwc -C /etc/dbrrg/labwc -S /usr/local/bin/dbrrg-session
fi
