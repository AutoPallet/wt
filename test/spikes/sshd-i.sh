#!/bin/bash
# Regression spike: inetd-mode `sshd -i` speaking SSH over a stdio pipe (as
# `docker exec -i ... sshd -i` would), key-auth, then ForceCommand wrapping the client's
# command ($SSH_ORIGINAL_COMMAND). This is the same sshd stdio path `wt-ssh proxy` drives via
# `docker exec -u0 -i <cid> wt ssh-serve <name>` — this spike's ProxyCommand is a LOCAL
# `sudo sshd -i`, identical to that path minus docker.
#
# Runs the handshake against a throwaway system account this spike creates itself (NOT the
# real login user, which this spike must not touch). That account is left LOCKED (a fresh
# `useradd`'s default "!" shadow password) on purpose: the real login account is also
# locked, and this spike proves the production auth path works anyway. It does, because
# `UsePAM yes` (what `wt ssh-setup` generates) routes account validation through PAM and
# bypasses sshd's own locked-shadow rejection, so pubkey auth succeeds for a locked account.
# (Under `UsePAM no`, sshd's `allowed_user()` refuses every method for a locked account:
# "User X not allowed because account is locked" — which is exactly why the config is UsePAM yes.)
#
# Self-contained: builds its own throwaway keypair, sshd_config, ForceCommand script, and
# system account under a scratch dir, and removes all of it on exit (even on failure).
# No ZFS involved.
set -uo pipefail

TESTUSER=wt-spike-sshd
WORK=$(mktemp -d)
chmod 755 "$WORK"

cleanup() {
  echo "=== cleanup ==="
  sudo userdel -r "$TESTUSER" 2>/dev/null && echo "test account removed" || echo "test account removal skipped/failed"
  rm -rf "$WORK" && echo "spike dir removed"
}
trap cleanup EXIT

# idempotent start: remove a leftover same-named account from a prior failed run
sudo userdel -r "$TESTUSER" 2>/dev/null || true

echo "=== privsep prereqs ==="
sudo mkdir -p /run/sshd && sudo chmod 0755 /run/sshd && echo "/run/sshd ready"
getent passwd sshd >/dev/null && echo "privsep user 'sshd' exists" || echo "WARN: no 'sshd' user"

echo "=== throwaway system account, left LOCKED to mirror a real login account ==="
sudo useradd -m -s /bin/bash "$TESTUSER"        # default shadow password is "!" (locked) — kept that way
echo "account: $(getent passwd "$TESTUSER") shadow=[$(sudo getent shadow "$TESTUSER" | cut -d: -f2)]"

echo "=== throwaway client keypair + authorized_keys ==="
ssh-keygen -q -t ed25519 -f "$WORK/id" -N '' -C wt-spike
cp "$WORK/id.pub" "$WORK/authorized_keys"; chmod 644 "$WORK/authorized_keys"

cat > "$WORK/forcecmd.sh" <<'EOF'
#!/bin/bash
# Stand-in for the real ForceCommand. In production this execs:
#   wt enter "$WT_SANDBOX" -- ${SSH_ORIGINAL_COMMAND:-bash -l}
# Here it just proves it runs as the right user and can see/wrap the IDE's command.
echo "FORCECOMMAND ran: uid=$(id -u) user=$(whoami)"
echo "WT_SANDBOX=[${WT_SANDBOX:-<unset>}]"
echo "SSH_ORIGINAL_COMMAND=[${SSH_ORIGINAL_COMMAND:-<none>}]"
echo "would exec: wt enter \"${WT_SANDBOX:-<name>}\" -- ${SSH_ORIGINAL_COMMAND:-bash -l}"
EOF
chmod 755 "$WORK/forcecmd.sh"

# StrictModes no is spike-only: authorized_keys lives under a world-writable /tmp mktemp dir,
# which default StrictModes would reject. Production satisfies default StrictModes via a 0700
# ~/.wt-ssh, so `wt ssh-setup`'s generated config keeps StrictModes at its default.
cat > "$WORK/sshd_config" <<EOF
HostKey /etc/ssh/ssh_host_ed25519_key
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM yes
StrictModes no
PermitRootLogin no
AllowUsers $TESTUSER
AuthorizedKeysFile $WORK/authorized_keys
AcceptEnv WT_SANDBOX
SetEnv WT_SANDBOX=scan
ForceCommand $WORK/forcecmd.sh
LogLevel ERROR
EOF

echo "=== validate config ==="
sudo /usr/sbin/sshd -t -f "$WORK/sshd_config" && echo "config OK"

echo "=== connect: client -> ProxyCommand(sudo sshd -i) -> ForceCommand ==="
out=$(ssh -F /dev/null \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o "ProxyCommand=sudo /usr/sbin/sshd -i -f $WORK/sshd_config" \
    -i "$WORK/id" \
    "$TESTUSER@wt-sandbox" "code-server-bootstrap --start-server" 2>"$WORK/ssh.err")
rc=$?
echo "--- client stdout ---"
echo "$out"
echo "--- client exit rc=$rc ---"
[ -s "$WORK/ssh.err" ] && { echo "--- ssh stderr ---"; cat "$WORK/ssh.err"; }

if [ "$rc" -eq 0 ] \
  && [[ "$out" == *"FORCECOMMAND ran: uid="*" user=$TESTUSER"* ]] \
  && [[ "$out" == *"WT_SANDBOX=[scan]"* ]] \
  && [[ "$out" == *"SSH_ORIGINAL_COMMAND=[code-server-bootstrap --start-server]"* ]]; then
  echo "PASS sshd-i: key auth + ForceCommand over the sshd -i stdio pipe, env + original command forwarded correctly"
else
  echo "FAIL sshd-i: handshake/ForceCommand did not behave as expected (rc=$rc)"
  exit 1
fi
