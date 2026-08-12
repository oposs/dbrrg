#!/bin/bash
# Offline tests for dbrrg-ssh-hostkeys.
#
# Host keys persist inside the home directory, which is already saved to the
# EFI partition or the boot server. That removes the need for a separate EFI
# file or a hostkeys.pkg endpoint, but it means the keys arrive tluser-owned
# and must be forced to root:root 0600 before sshd will use them - the exact
# opposite of the home restore, which must PRESERVE uid 1000.
#
# Runs without root: chown is stubbed and its invocations are recorded, so
# the ownership fix can be asserted without actually being able to perform
# it. Directory layout is redirected via DBRRG_SSH_DIR / DBRRG_HOME_DIR.
#
# Usage: test/integration/test-ssh-hostkeys.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/overlay/usr/bin/dbrrg-ssh-hostkeys"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# chown cannot work as an unprivileged user. Record the calls instead so the
# ownership fix is still assertable.
cat >"$STUBS/chown" <<'STUB'
#!/bin/bash
echo "chown $*" >>"$DBRRG_TEST_CHOWN_LOG"
exit 0
STUB
chmod +x "$STUBS/chown"

# ssh-keygen -A normally writes into /etc/ssh; honour DBRRG_SSH_DIR instead.
cat >"$STUBS/ssh-keygen" <<'STUB'
#!/bin/bash
echo "ssh-keygen $*" >>"$DBRRG_TEST_KEYGEN_LOG"
for t in rsa ecdsa ed25519; do
    echo "PRIVATE-$t" >"$DBRRG_SSH_DIR/ssh_host_${t}_key"
    echo "PUBLIC-$t"  >"$DBRRG_SSH_DIR/ssh_host_${t}_key.pub"
done
exit 0
STUB
chmod +x "$STUBS/ssh-keygen"

export PATH="$STUBS:$PATH"

# fresh_case <name> -> sets DBRRG_SSH_DIR, DBRRG_HOME_DIR, logs
fresh_case() {
    CASE="$WORK/$1"
    export DBRRG_SSH_DIR="$CASE/etc-ssh"
    export DBRRG_HOME_DIR="$CASE/home"
    export DBRRG_TEST_CHOWN_LOG="$CASE/chown.log"
    export DBRRG_TEST_KEYGEN_LOG="$CASE/keygen.log"
    mkdir -p "$DBRRG_SSH_DIR" "$DBRRG_HOME_DIR"
    : >"$DBRRG_TEST_CHOWN_LOG"
    : >"$DBRRG_TEST_KEYGEN_LOG"
}

# --- keys present in the home keystore -> installed into /etc/ssh --------

fresh_case restore
mkdir -p "$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys"
echo "PRIVATE-ed25519" >"$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key"
echo "PUBLIC-ed25519"  >"$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key.pub"
chmod 644 "$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key"

"$SCRIPT" >/dev/null 2>&1

if [[ -f "$DBRRG_SSH_DIR/ssh_host_ed25519_key" ]]; then
    ok "keystore keys are installed into the ssh dir"
else
    bad "keystore keys were not installed"
fi

if [[ ! -s "$DBRRG_TEST_KEYGEN_LOG" ]]; then
    ok "no regeneration when the keystore already has keys"
else
    bad "ssh-keygen ran even though the keystore had keys"
fi

# sshd refuses to start on a private key that is not 0600.
perm=$(stat -c %a "$DBRRG_SSH_DIR/ssh_host_ed25519_key")
if [[ "$perm" == "600" ]]; then
    ok "installed private key is chmod 600"
else
    bad "installed private key is $perm, expected 600 (it was 644 in the archive)"
fi

perm=$(stat -c %a "$DBRRG_SSH_DIR/ssh_host_ed25519_key.pub")
if [[ "$perm" == "644" ]]; then
    ok "installed public key is chmod 644"
else
    bad "installed public key is $perm, expected 644"
fi

if grep -q "chown root:root" "$DBRRG_TEST_CHOWN_LOG"; then
    ok "installed keys are chowned to root:root"
else
    bad "no chown to root:root - keys arrive tluser-owned and sshd will refuse them"
fi

# --- nothing anywhere -> generate, then stage into the keystore ----------

fresh_case generate
"$SCRIPT" >/dev/null 2>&1

if grep -q -- "-A" "$DBRRG_TEST_KEYGEN_LOG"; then
    ok "ssh-keygen -A runs when no keys exist anywhere"
else
    bad "ssh-keygen -A did not run with no keys present"
fi

if [[ -f "$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key" ]]; then
    ok "generated keys are staged into the home keystore"
else
    bad "generated keys were not staged into the keystore - they would not persist"
fi

if grep -q "chown -R tluser:tluser" "$DBRRG_TEST_CHOWN_LOG"; then
    ok "staged keystore is chowned back to tluser"
else
    bad "staged keystore not chowned to tluser - save-home could not read it"
fi

# --- keys already live, keystore empty -> do nothing ---------------------

fresh_case already
echo "EXISTING" >"$DBRRG_SSH_DIR/ssh_host_ed25519_key"
"$SCRIPT" >/dev/null 2>&1

if [[ "$(cat "$DBRRG_SSH_DIR/ssh_host_ed25519_key")" == "EXISTING" ]]; then
    ok "existing live keys are left untouched"
else
    bad "existing live keys were overwritten"
fi

if [[ ! -s "$DBRRG_TEST_KEYGEN_LOG" ]]; then
    ok "no regeneration when live keys already exist"
else
    bad "ssh-keygen ran despite live keys existing"
fi

# --- --stage copies live keys into the keystore --------------------------

fresh_case stage
echo "LIVE" >"$DBRRG_SSH_DIR/ssh_host_ed25519_key"
echo "LIVEPUB" >"$DBRRG_SSH_DIR/ssh_host_ed25519_key.pub"
"$SCRIPT" --stage >/dev/null 2>&1

if [[ "$(cat "$DBRRG_HOME_DIR/.dbrrg-ssh-host-keys/ssh_host_ed25519_key" 2>/dev/null)" == "LIVE" ]]; then
    ok "--stage copies the live keys into the keystore"
else
    bad "--stage did not copy the live keys into the keystore"
fi

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - SSH host key persistence"
    exit 1
fi

echo ""
echo "PASSED - SSH host key persistence"
exit 0
