#!/usr/bin/env bash
# Fast, hermetic unit tests for wt's session-marker liveness + per-sandbox locking.
# No ZFS, no sudo, no real sandbox — `wt` is SOURCED (its dispatch is guarded), so these
# exercise the real helpers rather than a copy of them.
#
# Why this matters: `wt rm` refuses to destroy a sandbox that is "in use", and the ONLY honest
# signal of in-use is a held flock. A marker file's mere existence proves nothing — the EXIT
# trap never runs on SIGKILL (OOM killer, `docker kill`, host crash), so a dead session leaves
# its marker behind. If a stale marker read as live, that sandbox could never be removed again;
# if a live one read as stale, `wt rm` would yank the clone out from under a running session.
set -uo pipefail
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WT="$DIR/../wt"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

T=$(mktemp -d)
cleanup() { pkill -9 -f "wt-marker-test:$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/active" "$T/locks" "$T/pids"

# Run helpers from the REAL wt, in a clean shell. WT_CONFIG= skips any installed config file.
h() { WT_CONFIG= WT_HOME="$T" bash -c "source '$WT'; $*"; }

# A live session: holds an exclusive flock on its marker until killed. stdio detached so it
# never holds this script's pipes open. The marker is the lock — exactly as wt_enter does it.
start_session() {  # start_session <name> <tag> -> pid
  local name=$1 tag=$2
  setsid bash -c "
    exec 9>\"$T/active/$name.\$\$\"
    flock -n 9 || exit 1
    echo \$\$ > \"$T/pids/$tag\"
    exec sleep 60   # wt-marker-test:$T
  " </dev/null >/dev/null 2>&1 &
  disown
  local _
  for _ in $(seq 40); do [ -s "$T/pids/$tag" ] && break; sleep 0.05; done
  cat "$T/pids/$tag"
}

echo "== validate_name rejects names ZFS would choke on =="
# A leading dash would be taken as a flag by zfs, aborting `wt new` AFTER the snapshot and
# worktree exist — leaving both to be cleaned up by hand.
for bad in -foo - -- -rf 'a b' 'a/b' ''; do
  h "validate_name '$bad'" 2>/dev/null && no "accepted '$bad'" || ok "rejects '$bad'"
done
h "validate_name 'good-name_1'" 2>/dev/null && ok "still accepts 'good-name_1'" || no "rejected a valid name"

echo "== a live session's marker reads as active =="
pid=$(start_session alpha a1)
kill -0 "$pid" 2>/dev/null && ok "session $pid is running" || no "session did not start"
h "name_active alpha" && ok "name_active sees the live session" || no "live session not seen"
h "prune_stale_markers alpha"
ls "$T/active"/alpha.* >/dev/null 2>&1 && ok "prune keeps a LIVE marker" || no "prune deleted a live marker"

echo "== SIGKILL (the EXIT trap never runs) leaves a marker that must read as STALE =="
kill -9 "$pid"; sleep 0.3
ls "$T/active"/alpha.* >/dev/null 2>&1 && ok "marker file survives SIGKILL" || no "marker vanished"
h "name_active alpha" \
  && no "stale marker still reads active -> that sandbox could never be rm'd again" \
  || ok "stale marker reads inactive (the kernel released the flock with the process)"
h "prune_stale_markers alpha"
ls "$T/active"/alpha.* >/dev/null 2>&1 && no "stale marker not pruned" || ok "prune reaps the stale marker"

echo "== with N sessions, only the last one out ends the sandbox =="
# This is what makes the EXIT-trap teardown fire exactly once (see test-hooks-unit.sh).
p1=$(start_session beta b1); p2=$(start_session beta b2)
[ "$(ls "$T/active"/beta.* 2>/dev/null | wc -l)" = 2 ] && ok "two markers for beta" || no "expected 2 markers"
kill -9 "$p1"; sleep 0.3
h "name_active beta" && ok "still active while the second session lives" || no "went inactive too early"
kill -9 "$p2"; sleep 0.3
h "name_active beta" && no "still active after both died" || ok "inactive once both sessions are gone"

echo "== the per-sandbox lock is exclusive, so rm cannot race enter =="
setsid bash -c "WT_CONFIG= WT_HOME=$T; source '$WT'; lock_name gamma; exec sleep 5  # wt-marker-test:$T" \
  </dev/null >/dev/null 2>&1 & holder=$!
disown        # else bash prints a "Killed" job-control line when we kill -9 it below
sleep 0.5
h "exec 8>$T/locks/gamma.lock; flock -w 1 8" 2>/dev/null; rc=$?
[ "$rc" != 0 ] && ok "a contender blocks, then times out" || no "the lock was NOT exclusive"
kill -9 "$holder" 2>/dev/null; sleep 0.3
h "exec 8>$T/locks/gamma.lock; flock -w 1 8" 2>/dev/null \
  && ok "lock is released when its holder is SIGKILLed" || no "lock stuck after its holder died"

echo "== but a different sandbox's lock does not block =="
setsid bash -c "WT_CONFIG= WT_HOME=$T; source '$WT'; lock_name delta; exec sleep 3  # wt-marker-test:$T" \
  </dev/null >/dev/null 2>&1 & h2=$!
disown
sleep 0.4
h "exec 8>$T/locks/epsilon.lock; flock -w 1 8" 2>/dev/null \
  && ok "locks are per-sandbox" || no "epsilon blocked on delta's lock"
kill -9 "$h2" 2>/dev/null

echo
echo "wt-marker-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
