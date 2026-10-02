#!/bin/bash
# Offline: the exit-status contract between dbrrg-menu and dbrrg-session,
# and the restart limit in session-verdict. No image, no compositor; the
# menu and foot are stubs, and a save stub records any call: since
# 2026-10-02 the menu saves before it exits, so the session must never save.
#
# Usage: test/integration/test-session-lifecycle.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SESSION="$ROOT/overlay/usr/bin/dbrrg-session"
VERDICT="$ROOT/overlay/usr/libexec/dbrrg/session-verdict"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; fail=1; }

mkdir -p "$WORK/bin" "$WORK/home"
# foot records its arguments instead of opening a window.
cat >"$WORK/bin/foot" <<STUB
#!/bin/sh
echo "\$@" >"$WORK/foot.args"
STUB
# A save stub named like the real one, first on PATH, and also reachable
# through DBRRG_SAVE_HOME: a call by name or through the variable is
# recorded. (dbrrg-session reads neither; the stub exists so the "never
# saves" assertions are able to fail if someone adds a call.)
cat >"$WORK/bin/dbrrg-save-home" <<STUB
#!/bin/sh
echo called >>"$WORK/saved"
STUB
chmod 755 "$WORK/bin/foot" "$WORK/bin/dbrrg-save-home"
# The session also starts these helpers when they exist; on a dev host they
# might, so stub them rather than launch the real ones.
for h in waybar swayidle wlopm; do
    printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/$h"
    chmod 755 "$WORK/bin/$h"
done

# Run dbrrg-session with a menu stub that runs $1 as shell code.
run_session() {
    rm -f "$WORK/saved" "$WORK/foot.args" "$WORK/status" "$WORK/dbrrg-session.status"
    printf '#!/bin/sh\n%s\n' "$1" >"$WORK/bin/menu"
    chmod 755 "$WORK/bin/menu"
    env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" \
        XDG_RUNTIME_DIR="$WORK" \
        DBRRG_MENU="$WORK/bin/menu" DBRRG_SAVE_HOME="$WORK/bin/dbrrg-save-home" \
        DBRRG_SESSION_LOG="$WORK/log" \
        sh "$SESSION" >/dev/null 2>&1
}

run_session 'exit 0'
rc=$?
[[ $rc -eq 0 ]] && ok "logout: session exits 0" || bad "logout: session exited $rc"
[[ ! -e "$WORK/saved" ]] && ok "logout: the session does not save again" || bad "logout: the session saved after the menu"
[[ "$(cat "$WORK/dbrrg-session.status" 2>/dev/null)" == 0 ]] && ok "logout: status 0 recorded" || bad "logout: status file wrong"
[[ ! -e "$WORK/foot.args" ]] && ok "logout: no failure window" || bad "logout: failure window shown"

for code in 1 101 127; do
    run_session "exit $code"
    rc=$?
    [[ $rc -eq $code ]] && ok "menu exit $code: session exits $code" || bad "menu exit $code: session exited $rc"
    [[ ! -e "$WORK/saved" ]] && ok "menu exit $code: home NOT saved" || bad "menu exit $code: home was saved"
    [[ "$(cat "$WORK/dbrrg-session.status" 2>/dev/null)" == "$code" ]] && ok "menu exit $code: status recorded" \
        || bad "menu exit $code: status file wrong"
    grep -q -- "-- sh -c" "$WORK/foot.args" 2>/dev/null && grep -q " $code " "$WORK/foot.args" \
        && ok "menu exit $code: failure window names the status" || bad "menu exit $code: no failure window"
done

# The stub does not catch an absolute /usr/bin/dbrrg-save-home, so check
# the code as well.
if grep -v '^[[:space:]]*#' "$SESSION" | grep -q 'dbrrg-save-home'; then
    bad "dbrrg-session still calls dbrrg-save-home; the menu saves before it exits"
else
    ok "dbrrg-session never calls dbrrg-save-home"
fi

# Killed by a signal: the shell reports 128+N. Still a failure, still no save.
run_session 'kill -9 $$'
rc=$?
[[ $rc -eq 137 && ! -e "$WORK/saved" ]] && ok "menu killed: no save, status 137" \
    || bad "menu killed: rc=$rc saved=$([[ -e $WORK/saved ]] && echo yes || echo no)"

# --- session-verdict ---------------------------------------------------
S="$WORK/vstatus"
C="$WORK/vcount"
rm -f "$S" "$C"
"$VERDICT" "$S" "$C" >/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok "verdict: no status file restarts" || bad "verdict: no status file gave $rc"
echo 0 >"$S"; echo 2 >"$C"
"$VERDICT" "$S" "$C" >/dev/null; rc=$?
[[ $rc -eq 0 && ! -e "$C" ]] && ok "verdict: clean logout resets the count" || bad "verdict: clean logout rc=$rc"
echo 101 >"$S"; rm -f "$C"
"$VERDICT" "$S" "$C" >/dev/null; r1=$?
"$VERDICT" "$S" "$C" >/dev/null; r2=$?
out=$("$VERDICT" "$S" "$C"); r3=$?
[[ $r1 -eq 0 && $r2 -eq 0 && $r3 -eq 1 && "$out" == 101 ]] \
    && ok "verdict: third consecutive failure stops the restarts and names 101" \
    || bad "verdict: got $r1 $r2 $r3 '$out'"
[[ ! -e "$C" ]] && ok "verdict: count cleared after stopping" || bad "verdict: count left behind"
echo garbage >"$C"
"$VERDICT" "$S" "$C" >/dev/null; rc=$?
[[ $rc -eq 0 && "$(cat "$C")" == 1 ]] && ok "verdict: a corrupt count starts again at 1" || bad "verdict: corrupt count rc=$rc"

# --- 10-dbrrg-session.sh stops restarting after repeated failures ----
PROFILE="$ROOT/overlay/etc/profile.d/10-dbrrg-session.sh"
mkdir -p "$WORK/ps/bin" "$WORK/ps/home" "$WORK/ps/run"
printf '#!/bin/sh\necho /dev/tty1\n' >"$WORK/ps/bin/tty"
# labwc runs the session, which records the menu's status, and exits 0 as
# the real one always does.
printf '#!/bin/sh\necho "$STUB_MENU_RC" >"$DBRRG_SESSION_STATUS"\nexit 0\n' >"$WORK/ps/bin/labwc"
chmod 755 "$WORK/ps/bin/tty" "$WORK/ps/bin/labwc"
run_profile() {
    env -i PATH="$WORK/ps/bin:/usr/bin:/bin" HOME="$WORK/ps/home" \
        XDG_RUNTIME_DIR="$WORK/ps/run" STUB_MENU_RC="$1" \
        DBRRG_SESSION_VERDICT="$VERDICT" DBRRG_SESSION_FAILURES="$WORK/ps/failures" \
        sh "$PROFILE" >"$WORK/ps/out" 2>&1
    ps_rc=$?
}
run_profile 101
r1=$ps_rc; o1=$(cat "$WORK/ps/out")
run_profile 101
r2=$ps_rc
run_profile 101
if [[ $r1 -eq 0 && $r2 -eq 0 && "$o1" != *"graphical session exited"* ]] &&
   grep -q 'graphical session exited with status 101' "$WORK/ps/out"; then
    ok "profile: two failed menus restart, the third shows the failure screen"
else
    bad "profile: r1=$r1 r2=$r2 out=$(cat "$WORK/ps/out")"
fi
run_profile 0
if [[ $ps_rc -eq 0 && ! -e "$WORK/ps/failures" ]] && ! grep -q 'graphical session exited' "$WORK/ps/out"; then
    ok "profile: a clean logout ends the session and clears the count"
else
    bad "profile: clean logout rc=$ps_rc out=$(cat "$WORK/ps/out")"
fi

exit $fail
