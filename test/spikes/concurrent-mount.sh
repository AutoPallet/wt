#!/bin/bash
# Regression spike: can two independent mount namespaces concurrently mount the SAME ZFS
# clone read-write and observe each other's writes consistently?
#
# NS1 mounts the clone and daemonizes a holder that keeps NS1 (and its mount) alive, mirroring
# ns-persist.sh. NS2 is then created independently, mounts the SAME clone RW, reads NS1's
# marker file, and writes its own marker. If NS1 can then see NS2's marker, both mounts
# observe one consistent underlying dataset — the precondition for running multiple
# concurrent `wt` sandbox connections against clones without silent divergence.
#
# Self-contained: creates its own throwaway snapshot+clone, its own scratch dir, and cleans
# both up on exit (even on failure).
set -uo pipefail

WT_DS_SRC=${WT_DS_SRC:-rpool/data/myrepo-src}
WT_DS_PARENT=${WT_DS_PARENT:-rpool/data/myrepo-wt}
SUFFIX=wt-spike-concurrent
SNAP="$WT_DS_SRC@$SUFFIX"
CLONE="$WT_DS_PARENT/$SUFFIX"

WORK=$(mktemp -d)
FIFO="$WORK/holdfifo"
PIDFILE="$WORK/holder.pid"
MNT1="$WORK/mnt1"
MNT2="$WORK/mnt2"

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
  zfs destroy "$SNAP" 2>/dev/null && echo "snapshot destroyed" || echo "snap destroy skipped"
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
# Daemonized holder: records its own pid, then blocks on a fifo so it stays a member of NS1
# (keeping the ZFS mount alive) until released.
FIFO="$1"; PIDFILE="$2"
echo $$ > "$PIDFILE"
exec 3<>"$FIFO"
read -u 3 _
EOF

cat > "$WORK/launcher.sh" <<'EOF'
#!/bin/bash
# Runs as the init process of NS1: mounts the throwaway clone, writes a marker, daemonizes
# the holder, then exits.
set -x
CLONE="$1"; FIFO="$2"; PIDFILE="$3"; HOLDER="$4"; MNT="$5"
mkdir -p "$MNT"
mount -t zfs "$CLONE" "$MNT"
echo "NS1: mount rc=$? ; sample: $(ls "$MNT" 2>/dev/null | head -3 | tr '\n' ' ')"
echo "hello-from-holder" > "$MNT/holder_wrote.txt"
sync
setsid bash "$HOLDER" "$FIFO" "$PIDFILE" </dev/null >/dev/null 2>&1 &
disown
EOF

cat > "$WORK/ns2.sh" <<'EOF'
#!/bin/bash
# Runs as the init process of NS2 (a second, independent `unshare --mount`). Concurrently
# mounts the SAME clone RW while NS1's holder still has it mounted.
set -x
CLONE="$1"; MNT="$2"
mkdir -p "$MNT"
if mount -t zfs "$CLONE" "$MNT"; then
  echo "NS2: concurrent mount of same clone OK"
else
  echo "NS2: concurrent mount FAILED rc=$?"
  exit 1
fi
echo "NS2: reads NS1's marker -> $(cat "$MNT/holder_wrote.txt" 2>&1)"
echo "ns2-wrote-this" > "$MNT/ns2_wrote.txt"
sync
echo "NS2: dir sample -> $(ls "$MNT" 2>/dev/null | head -3 | tr '\n' ' ')"
umount "$MNT"
echo "NS2: umount rc=$?"
EOF

echo
echo "=== NS1: launcher mounts clone, daemonizes holder, then EXITS ==="
sudo unshare --mount --propagation private -- \
  bash "$WORK/launcher.sh" "$CLONE" "$FIFO" "$PIDFILE" "$WORK/holder.sh" "$MNT1"

for _ in $(seq 1 500); do [ -s "$PIDFILE" ] && break; sleep 0.01; done
H=$(cat "$PIDFILE" 2>/dev/null || echo "")
alive=NO; [ -n "$H" ] && [ -e "/proc/$H" ] && alive=yes
echo "launcher returned. holder pid=$H alive=$alive"
[ "$alive" = yes ] || { echo "FAIL concurrent-mount: NS1 holder did not stay alive; aborting"; exit 1; }

echo
echo "=== NS2: a second namespace concurrently mounts the SAME clone RW ==="
sudo unshare --mount --propagation private -- bash "$WORK/ns2.sh" "$CLONE" "$MNT2"

echo
echo "=== consistency: does NS1 observe NS2's write? ==="
if sudo test -f "/proc/$H/root$MNT1/ns2_wrote.txt" 2>/dev/null; then
  echo "PASS concurrent-mount: NS1 sees NS2's write -> \"$(sudo cat "/proc/$H/root$MNT1/ns2_wrote.txt" 2>&1)\" (two RW mounts, one shared dataset)"
else
  echo "FAIL concurrent-mount: NS1 does not see NS2's write"
  exit 1
fi
