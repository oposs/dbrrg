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
# DBRRG_SESSION_ATTEMPTED guards against recursion: the failure path below
# leaves a login shell on tty1, and a login shell re-sources this file. The
# marker is exported, so the guard survives into that shell and stops it
# starting the session again in a loop.
if [ -z "${WAYLAND_DISPLAY:-}" ] &&
   [ -z "${DBRRG_SESSION_ATTEMPTED:-}" ] &&
   [ "$(tty)" = "/dev/tty1" ]; then

    export DBRRG_SESSION_ATTEMPTED=1
    DBRRG_SESSION_LOG=/run/dbrrg-session.log

    # The compositor's stderr is the only record of why a session failed.
    # Without this redirection it lands on tty1 and is erased when getty
    # restarts the session seconds later.
    labwc -C /etc/dbrrg/labwc -S /usr/local/bin/dbrrg-session \
        >>"$DBRRG_SESSION_LOG" 2>&1
    DBRRG_SESSION_RC=$?

    if [ "$DBRRG_SESSION_RC" -eq 0 ]; then
        # Normal logout: exit so getty starts a fresh session.
        exit 0
    fi

    # Failure. Deliberately do NOT exit - getty would restart us and the
    # error would scroll past unread. Hold this shell on tty1 with the log
    # in view so the failure is diagnosable at the machine itself.
    #
    # NOTE: DEBUGGING AID, not production behaviour. This trades "retry the
    # client forever" for visibility: a crash-looping client now strands the
    # user at a shell prompt. Remove this block before fleet deployment.
    echo ""
    echo "=============================================================="
    echo " dbrrg: graphical session exited with status $DBRRG_SESSION_RC"
    echo ""
    echo " Last lines of $DBRRG_SESSION_LOG:"
    echo "--------------------------------------------------------------"
    tail -n 25 "$DBRRG_SESSION_LOG" 2>/dev/null
    echo "--------------------------------------------------------------"
    echo " Full log:    $DBRRG_SESSION_LOG"
    echo " Journal:     journalctl -b --no-pager"
    echo " DRM devices: ls -l /dev/dri/"
    echo " Seat/session: loginctl session-status"
    echo " Retry byhand: labwc -C /etc/dbrrg/labwc -S /usr/local/bin/dbrrg-session"
    echo "=============================================================="
    echo ""
fi
