#!/bin/bash
# Regression spike: does a daemonized holder process keep a mount namespace's ZFS mount
# alive after the foreground process that created it exits?
#
# A fresh `unshare --mount` namespace (NS1) mounts a throwaway ZFS clone, writes a marker,
# daemonizes a holder that blocks on a fifo (pinning the namespace open), then the launching
# process exits. If the mount is still visible via the holder's /proc/<pid>/mountinfo
# afterward, the namespace + mount survived the launcher's exit — this is the mechanism `wt`
# relies on to keep a sandbox's mount alive across ephemeral per-connection processes.
#
# Self-contained: creates its own throwaway snapshot+clone, its own scratch dir, and cleans
# both up on exit (even on failure).
set -uo pipefail

WT_DS_SRC=${WT_DS_SRC:-rpool/data/myrepo-src}
WT_DS_PARENT=${WT_DS_PARENT:-rpool/data/myrepo-wt}
SUFFIX=wt-spike-nspersist
SNAP="$WT_DS_SRC@$SUFFIX"
CLONE="$WT_DS_PARENT/$SUFFIX"

WORK=$(mktemp -d)
FIFO="$WORK/holdfifo"
PIDFILE="$WORK/holder.pid"
MNT="$WORK/mnt"

cleanup() {
  echo "=== cleanup ==="
  # read-write open (not a plain `>`): writing to a FIFO whose reader already exited would block
  # the backgrounded subshell forever; `3<>` never blocks regardless of reader presence.
  [ -p "$FIFO" ] && { ( exec 3<>"$FIFO"; echo x >&3 ) 2>/dev/null & }   # release the holder if still blocked
  if [ -s "$PIDFILE" ]; then
    H=$(cat "$PIDFILE")
    # [ -e /proc/<pid> ] (not kill -0): the holder runs as root under sudo, so a plain kill -0
    # from this non-root shell would EPERM (false "dead") even while it's alive.
    for _ in $(seq 1 200); do [ -e "/proc/$H" ] || break; sleep 0.05; done
  fi
  # Delayed retry: destroying the clone races ZFS's async release of the namespace's mount.
  for _ in $(seq 1 60); do zfs destroy "$CLONE" 2>/dev/null && break; sleep 0.5; done
  if zfs list "$CLONE" >/dev/null 2>&1; then echo "WARN: clone $CLONE still present"; else echo "clone destroyed"; fi
  zfs destroy "$SNAP" 2>/dev/null && echo "snapshot destroyed" || echo "snapshot destroy skipped/failed"
  rm -rf "$WORK"
}
trap cleanup EXIT

# idempotent start: destroy any pre-existing same-named clone/snap from a prior failed run
zfs destroy "$CLONE" 2>/dev/null || true
zfs destroy "$SNAP"  2>/dev/null || true
rm -f "$FIFO" "$PIDFILE"; mkfifo "$FIFO"

echo "=== create throwaway snapshot + clone ==="
zfs snapshot "$SNAP"
zfs clone -o mountpoint=legacy -o canmount=noauto "$SNAP" "$CLONE"
echo "clone: $(zfs list -H -o name "$CLONE" 2>&1)"

cat > "$WORK/holder.sh" <<'EOF'
#!/bin/bash
# Daemonized holder: records its own pid, then blocks on a fifo so it stays a member of the
# launching mount namespace (keeping the ZFS mount alive) until released.
FIFO="$1"; PIDFILE="$2"
echo $$ > "$PIDFILE"
exec 3<>"$FIFO"   # <> so open() doesn't block waiting for a writer
read -u 3 _       # blocks (no CPU spin) until the orchestrator writes to the fifo
EOF

cat > "$WORK/launcher.sh" <<'EOF'
#!/bin/bash
# Runs as the init process of a fresh `unshare --mount` namespace: mounts the throwaway
# clone, writes a marker, daemonizes the holder, then exits. If the mount survives this
# process exiting, it's because the daemonized holder still pins the namespace.
set -x
CLONE="$1"; FIFO="$2"; PIDFILE="$3"; HOLDER="$4"; MNT="$5"
mkdir -p "$MNT"
mount -t zfs "$CLONE" "$MNT"
echo "NS1: mount rc=$? ; sample: $(ls "$MNT" 2>/dev/null | head -3 | tr '\n' ' ')"
echo "hello-from-holder" > "$MNT/holder_wrote.txt"
sync
setsid bash "$HOLDER" "$FIFO" "$PIDFILE" </dev/null >/dev/null 2>&1 &
disown
# launcher now exits; unshare returns to the orchestrator.
EOF

echo
echo "=== NS1: launcher mounts clone, daemonizes holder, then EXITS ==="
sudo unshare --mount --propagation private -- \
  bash "$WORK/launcher.sh" "$CLONE" "$FIFO" "$PIDFILE" "$WORK/holder.sh" "$MNT"

for _ in $(seq 1 500); do [ -s "$PIDFILE" ] && break; sleep 0.01; done
H=$(cat "$PIDFILE" 2>/dev/null || echo "")
alive=NO; [ -n "$H" ] && [ -e "/proc/$H" ] && alive=yes
echo "launcher returned. holder pid=$H alive=$alive"

echo
echo "=== ns-persist: mount persistence after launcher exit ==="
if [ -n "$H" ] && sudo grep -qF "$SUFFIX" "/proc/$H/mountinfo" 2>/dev/null; then
  echo "PASS ns-persist: clone still mounted in NS1 after launcher exited (pinned by daemonized holder)"
else
  echo "FAIL ns-persist: clone NOT mounted in NS1 (namespace/mount died with the launcher)"
  exit 1
fi

marker=$(sudo cat "/proc/$H/root$MNT/holder_wrote.txt" 2>&1)
if [ "$marker" = "hello-from-holder" ]; then
  echo "PASS ns-persist-marker: NS1's marker file readable through /proc/$H/root -> \"$marker\""
else
  echo "FAIL ns-persist-marker: could not read marker through the surviving namespace (got: $marker)"
  exit 1
fi
