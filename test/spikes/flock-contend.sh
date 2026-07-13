#!/bin/bash
# Regression spike: does a POSIX advisory lock (like cargo's target/.cargo-lock) contend
# across two independent mount namespaces that each mount the SAME ZFS clone?
#
# NS_A mounts the clone and takes an exclusive flock on a file inside it, holding the lock
# open. NS_B mounts the SAME clone and tries to grab the same lock with a bounded wait: if it
# blocks out, cargo's build lock protects concurrent builds even under this design's
# per-connection mount namespaces. A control pass (NS_C) confirms the lock is grabbable again
# immediately after NS_A releases it.
#
# Self-contained: creates its own throwaway snapshot+clone, its own scratch dir, and cleans
# both up on exit (even on failure).
set -uo pipefail

WT_DS_SRC=${WT_DS_SRC:-rpool/data/myrepo-src}
WT_DS_PARENT=${WT_DS_PARENT:-rpool/data/myrepo-wt}
SUFFIX=wt-spike-flock
SNAP="$WT_DS_SRC@$SUFFIX"
CLONE="$WT_DS_PARENT/$SUFFIX"

WORK=$(mktemp -d)
FIFO="$WORK/flock.fifo"
READY="$WORK/flock.ready"
MNTA="$WORK/mntA"
MNTB="$WORK/mntB"
MNTC="$WORK/mntC"

cleanup() {
  echo "=== cleanup ==="
  # Open read-write (not plain '>'): a fifo already released (no reader left) would make a
  # write-only open block forever waiting for a reader that will never come.
  [ -p "$FIFO" ] && { ( exec 3<>"$FIFO"; echo x >&3 ) 2>/dev/null & }
  wait 2>/dev/null
  # Delayed retry: destroying the clone races ZFS's async release of the namespaces' mounts.
  for _ in $(seq 1 60); do zfs destroy "$CLONE" 2>/dev/null && break; sleep 0.5; done
  if zfs list "$CLONE" >/dev/null 2>&1; then echo "WARN: clone $CLONE still present"; else echo "clone destroyed"; fi
  zfs destroy "$SNAP" 2>/dev/null && echo "snapshot destroyed" || echo "snap destroy skipped"
  rm -rf "$WORK"
}
trap cleanup EXIT

# idempotent start: destroy any pre-existing same-named clone/snap from a prior failed run
zfs destroy "$CLONE" 2>/dev/null || true
zfs destroy "$SNAP"  2>/dev/null || true
rm -f "$FIFO" "$READY"; mkfifo "$FIFO"
zfs snapshot "$SNAP"
zfs clone -o mountpoint=legacy -o canmount=noauto "$SNAP" "$CLONE"
echo "clone: $(zfs list -H -o name "$CLONE")"

echo
echo "=== NS_A: mount clone, take EXCLUSIVE flock on buildlock, hold it ==="
sudo unshare --mount --propagation private -- bash -c '
  set -e
  CLONE="$1"; FIFO="$2"; READY="$3"; MNT="$4"
  mkdir -p "$MNT"; mount -t zfs "$CLONE" "$MNT"
  : > "$MNT/buildlock"
  exec 9>"$MNT/buildlock"
  flock -x 9                 # exclusive lock held while fd 9 stays open (this proc alive)
  touch "$READY"              # signal: lock acquired
  exec 4<>"$FIFO"; read -u4 _ # block until released
  exec 9>&-                  # close the lock fd first, or umount sees the mount as busy
  umount "$MNT"
' _ "$CLONE" "$FIFO" "$READY" "$MNTA" &
NSA=$!
for _ in $(seq 1 500); do [ -e "$READY" ] && break; sleep 0.01; done
echo "NS_A holds exclusive lock (bg pid $NSA)"

echo
echo "=== NS_B: mount SAME clone, try to grab the same lock (expect BLOCK) ==="
sudo unshare --mount --propagation private -- bash -c '
  CLONE="$1"; MNT="$2"
  mkdir -p "$MNT"; mount -t zfs "$CLONE" "$MNT"
  if flock -x -w 3 "$MNT/buildlock" -c "echo NS_B-ACQUIRED"; then
    echo "RESULT: NS_B acquired (rc=0) -> locks DO NOT contend across namespaces (cargo lock DEFEATED)"
    failed=1
  else
    echo "RESULT: NS_B blocked out, timeout -> locks CONTEND across namespaces (cargo lock EFFECTIVE)"
    failed=0
  fi
  umount "$MNT"
  exit "$failed"
' _ "$CLONE" "$MNTB"
ns_b_rc=$?

echo
echo "=== control: release NS_A, a fresh namespace should now grab it instantly ==="
echo x > "$FIFO"
for _ in $(seq 1 500); do [ -e "/proc/$NSA" ] || break; sleep 0.01; done   # uid-agnostic liveness
sudo unshare --mount --propagation private -- bash -c '
  CLONE="$1"; MNT="$2"
  mkdir -p "$MNT"; mount -t zfs "$CLONE" "$MNT"
  if flock -x -w 3 "$MNT/buildlock" -c true; then
    echo "  NS_C: acquired immediately after release (rc=0, expected)"
  else
    echo "  NS_C: did NOT acquire (rc=$?)"
  fi
  umount "$MNT"
' _ "$CLONE" "$MNTC"

echo
if [ "$ns_b_rc" -eq 0 ]; then
  echo "PASS flock-contend: NS_B contended (blocked) across namespaces on the shared clone"
else
  echo "FAIL flock-contend: NS_B was NOT blocked (lock did not contend across namespaces)"
  exit 1
fi
