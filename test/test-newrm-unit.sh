#!/usr/bin/env bash
# Fast, hermetic unit tests for `wt new` and `wt rm` — the paths that CREATE and DESTROY a user's
# data (no ZFS/root/docker needed).
#
# These two subcommands went untested for a long time, and the cost was invisible: you could
# delete `wt rm`'s in-use guard, or drop the provenance stamp from `wt new`, and every other suite
# stayed green. Both are silent catastrophes — the first destroys the clone out from under a
# running session; the second leaves every snapshot untagged, so `wt gc` reaps nothing, forever,
# while telling the user their own snapshots are "not wt-managed".
#
# `zfs` is a stub that models real semantics (a `list` of something that doesn't exist FAILS) and
# records its own argv, so assertions can be made about what wt actually asked ZFS to do. `git`
# is REAL, against a throwaway repo: the worktree registration and the branch archiving are the
# behaviour under test, and a git mock would only prove it agrees with itself.
set -uo pipefail
# Scrub inherited WT_* first. wt resolves config as env > file > default, so WT_CONFIG= closes the
# FILE channel but says nothing about the environment — and every `wt enter` exports a WT_* bundle.
# Run this suite inside a sandbox and it would quietly test that sandbox's real config.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WT="$DIR/../wt"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export ZFS_STATE="$T/zfs"; mkdir -p "$T/bin" "$ZFS_STATE"

DS_SRC="fakepool/src"
DS_PARENT="fakepool/wt"
PROP="com.example:managed"     # NOT the default: a hardcoded property name must fail these tests

# --- fake zfs ------------------------------------------------------------------------------
# Models the semantics wt actually depends on:
#   list <thing>        -> exits 1 if it does not exist (the real thing does; a stub that always
#                          succeeds would hide every existence check wt makes)
#   snapshot -o k=v     -> creates it, records the properties, and records whether the sandbox's
#                          tree already existed at that moment (see the ordering test below)
#   clone <snap> <ds>   -> creates it, remembers its origin, so `get clones` can answer truthfully
#   destroy <thing>     -> removes it and appends to destroy.log, in order
cat > "$T/bin/zfs" <<'STUB'
#!/usr/bin/env bash
S=$ZFS_STATE
printf '%s\n' "$*" >> "$S/argv.log"
touch "$S/datasets" "$S/snapshots" "$S/props" "$S/origins" "$S/destroy.log"
sub=$1; shift || true
case "$sub" in
  list)
    snap=0 recurse=0 target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -H) ;;
        -o) shift ;;
        -t) shift; [ "${1:-}" = snapshot ] && snap=1 ;;
        -d) shift; recurse=1 ;;
        -r) recurse=1 ;;
        *)  target=$1 ;;
      esac
      shift
    done
    if [ "$snap" -eq 1 ]; then
      case "$target" in
        *@*) grep -qxF "$target" "$S/snapshots" || exit 1; printf '%s\n' "$target" ;;
        *)   grep -F "$target@" "$S/snapshots" || true ;;
      esac
    else
      grep -qxF "$target" "$S/datasets" || exit 1
      if [ "$recurse" -eq 1 ]; then
        grep -E "^${target}(/[^/]+)?$" "$S/datasets"
      else
        printf '%s\n' "$target"
      fi
    fi
    ;;
  snapshot)
    props=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) shift; props="$props $1" ;;
        *)  target=$1 ;;
      esac
      shift
    done
    printf '%s\n' "$target" >> "$S/snapshots"
    for kv in $props; do printf '%s\t%s\n' "$target" "$kv" >> "$S/props"; done
    # Did the sandbox's worktree already exist when the snapshot was taken? `wt gc` relies on it
    # (a tagged, clone-less snapshot whose tree exists is a `wt new` in flight, not an orphan).
    name=${target#*@wt-}; name=${name%-*-*}
    if [ -d "$WT_HOME/trees/$name" ]; then printf 'tree_existed\n' >> "$S/snap_order"
    else printf 'no_tree\n' >> "$S/snap_order"; fi
    ;;
  clone)
    origin="" target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) shift ;;
        *)  if [ -z "$origin" ]; then origin=$1; else target=$1; fi ;;
      esac
      shift
    done
    printf '%s\n' "$target" >> "$S/datasets"
    printf '%s\t%s\n' "$target" "$origin" >> "$S/origins"
    ;;
  destroy)
    printf '%s\n' "$1" >> "$S/destroy.log"
    grep -vxF "$1" "$S/datasets"  > "$S/.d" 2>/dev/null || true; mv "$S/.d" "$S/datasets"
    grep -vxF "$1" "$S/snapshots" > "$S/.s" 2>/dev/null || true; mv "$S/.s" "$S/snapshots"
    ;;
  get)
    prop="" target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -H) ;;
        -o) shift ;;
        *)  if [ -z "$prop" ]; then prop=$1; else target=$1; fi ;;
      esac
      shift
    done
    case "$prop" in
      clones)
        c=$(awk -F'\t' -v s="$target" '$2==s{printf "%s%s", sep, $1; sep=","}' "$S/origins")
        printf '%s\n' "${c:--}" ;;
      used) printf '%s\n' "1.00M" ;;
      *)    v=$(awk -F'\t' -v s="$target" -v p="$prop" '$1==s{split($2,a,"="); if (a[1]==p) print a[2]}' "$S/props")
            printf '%s\n' "${v:--}" ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$T/bin/zfs"

# --- the canonical checkout: a real git repo ------------------------------------------------
CANON="$T/canonical"
mkdir -p "$CANON"
git -C "$CANON" init -q -b main
git -C "$CANON" config user.email t@t; git -C "$CANON" config user.name t
echo hello > "$CANON/file.txt"
git -C "$CANON" add -A; git -C "$CANON" commit -qm first

export WT_HOME="$T/home"
HOOK_LOG="$T/hook.log"; : > "$HOOK_LOG"
cat > "$T/bin/hook-log" <<'EOF'
#!/bin/bash
n=$(wc -l < "$ZFS_STATE/destroy.log" 2>/dev/null || echo 0)
printf '%s %s destroys=%s\n' "${WT_SANDBOX:-<unset>}" "${1:-<noverb>}" "$n" >> "$HOOK_LOG"
EOF
chmod +x "$T/bin/hook-log"

printf '%s\n' "$DS_SRC" "$DS_PARENT" > "$ZFS_STATE/datasets"

wt() {
  env PATH="$T/bin:$PATH" WT_CONFIG= ZFS_STATE="$ZFS_STATE" HOOK_LOG="$HOOK_LOG" \
      WT_HOME="$WT_HOME" WT_CANONICAL="$CANON" \
      WT_DS_SRC="$DS_SRC" WT_DS_PARENT="$DS_PARENT" WT_ZFS_PROP="$PROP" \
      WT_HOOK_TEARDOWN="hook-log teardown" \
      bash "$WT" "$@"
}
argv() { cat "$ZFS_STATE/argv.log"; }

echo "== wt new =="
wt new alpha >"$T/new.out" 2>"$T/new.err"; rc=$?
[ "$rc" -eq 0 ] && ok "wt new succeeds" || no "wt new failed (rc=$rc): $(cat "$T/new.err")"

# THE provenance stamp. gc's whole filter reads this property; if `wt new` stops writing it, gc
# reaps nothing ever again and the pool fills in silence. Asserted against a NON-default property
# name, so hardcoding com.wt:managed fails here too.
argv | grep -q "^snapshot .*-o $PROP=1 " \
  && ok "wt new stamps the provenance property on its snapshot" \
  || no "snapshot was not stamped with $PROP=1: $(argv | grep '^snapshot' || echo '<no snapshot taken>')"

# Non-recursive, or the WT_SNAPSHOT_EXCLUDE child datasets would be captured — and the whole
# point of them is that they never reach a clone.
argv | grep '^snapshot' | grep -qv -- ' -r' \
  && ok "the snapshot is non-recursive (exclude children stay out)" \
  || no "wt new took a RECURSIVE snapshot"

argv | grep -q '^clone .*mountpoint=legacy.*canmount=noauto\|^clone .*canmount=noauto.*mountpoint=legacy' \
  && ok "the clone is created legacy+noauto (wt owns the mount lifecycle)" \
  || no "clone properties wrong: $(argv | grep '^clone')"

# The worktree must be registered BEFORE the snapshot. `wt gc` depends on exactly this: a tagged,
# clone-less snapshot whose trees/<name> exists is a `wt new` mid-flight, not an orphan to reap.
[ "$(cat "$ZFS_STATE/snap_order" 2>/dev/null)" = "tree_existed" ] \
  && ok "the worktree is registered BEFORE the snapshot is taken" \
  || no "snapshot preceded the worktree — gc cannot tell an in-flight 'new' from an orphan"

git -C "$CANON" show-ref --verify --quiet refs/heads/wt/alpha \
  && ok "wt new creates the sandbox branch (wt/alpha)" || no "branch wt/alpha not created"
[ -d "$WT_HOME/trees/alpha" ] && [ -s "$WT_HOME/meta/alpha/clone" ] \
  && ok "wt new records the tree and the clone metadata" || no "tree/meta missing"

wt new alpha >/dev/null 2>&1 \
  && no "a duplicate 'wt new alpha' was allowed" || ok "a duplicate sandbox name is refused"
wt new ../escape >/dev/null 2>&1 \
  && no "an invalid sandbox name was accepted" || ok "an invalid sandbox name is refused"

# From inside a sandbox (WT_SANDBOX set), `wt new` would build a hybrid: main's snapshot bytes
# under the calling sandbox's HEAD. It must refuse before creating anything.
out=$(env PATH="$T/bin:$PATH" WT_CONFIG= ZFS_STATE="$ZFS_STATE" WT_HOME="$WT_HOME" \
      WT_CANONICAL="$CANON" WT_DS_SRC="$DS_SRC" WT_DS_PARENT="$DS_PARENT" WT_ZFS_PROP="$PROP" \
      WT_SANDBOX=outer bash "$WT" new nested 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *sandbox* ]] && [ ! -d "$WT_HOME/trees/nested" ]; } \
  && ok "wt new refuses to run inside a sandbox, creating nothing" \
  || no "wt new nested inside a sandbox (rc=$rc): $out"

echo "== wt gc must not reap a sandbox that is being born =="
# A tagged, clone-less snapshot whose tree exists: precisely the window inside `wt new` between
# `zfs snapshot` and `zfs clone`. gc must leave it alone. (Regression guard: gc used to reap it,
# which killed a concurrent `wt new` and left a half-registered worktree behind.)
inflight="$DS_SRC@wt-newborn-20260101-000000"
mkdir -p "$WT_HOME/trees/newborn"
printf '%s\n' "$inflight" >> "$ZFS_STATE/snapshots"
printf '%s\t%s=1\n' "$inflight" "$PROP" >> "$ZFS_STATE/props"
wt gc >/dev/null 2>&1
grep -qxF "$inflight" "$ZFS_STATE/destroy.log" \
  && no "gc destroyed the snapshot of an in-flight 'wt new'" \
  || ok "gc spares a tagged, clone-less snapshot whose sandbox tree exists"
rm -rf "$WT_HOME/trees/newborn"

echo "== wt rm refuses a sandbox that is in use =="
# THE guard. A live session holds an flock on its marker; wt rm must refuse rather than yank the
# clone out from under it. Deleting this check used to leave every suite green.
mkdir -p "$WT_HOME/active"
marker="$WT_HOME/active/alpha.$$"
touch "$marker"
# The holder must own the locked fd ITSELF. `flock -c 'sleep 30'` would hand the fd to sleep, and
# killing flock would leave sleep holding the lock — the same fd-inheritance trap wt closes with
# `9>&-` when it enters a sandbox.
bash -c 'exec 9>"$1"; flock -x 9; while :; do sleep 0.2; done' _ "$marker" &
holder=$!
for _ in $(seq 100); do flock -n "$marker" true 2>/dev/null || break; sleep 0.05; done
flock -n "$marker" true 2>/dev/null && { echo "  SETUP FAILED: holder never took the lock"; exit 1; }

: > "$ZFS_STATE/destroy.log"
wt rm alpha >"$T/rm.out" 2>"$T/rm.err"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'in use' "$T/rm.err" \
  && ok "wt rm REFUSES a sandbox with a live session, and says why" \
  || no "wt rm did not refuse a live sandbox (rc=$rc): $(cat "$T/rm.err")"
[ ! -s "$ZFS_STATE/destroy.log" ] \
  && ok "...and destroyed nothing while refusing" \
  || no "wt rm destroyed something despite refusing: $(cat "$ZFS_STATE/destroy.log")"
[ -d "$WT_HOME/trees/alpha" ] \
  && ok "...and left the sandbox tree intact" || no "wt rm removed the tree of a live sandbox"

# Kill the session and wait for the kernel to actually release the lock. The marker FILE stays
# behind — exactly what a SIGKILLed session leaves — so the removal below also exercises
# prune_stale_markers deciding that a marker with no lock holder is dead.
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
for _ in $(seq 100); do flock -n "$marker" true 2>/dev/null && break; sleep 0.05; done

echo "== wt rm tears down, destroys, and preserves the work =="
: > "$ZFS_STATE/destroy.log"; : > "$HOOK_LOG"
snap_before=$(cat "$WT_HOME/meta/alpha/snapshot")
wt rm alpha >"$T/rm2.out" 2>"$T/rm2.err"; rc=$?
[ "$rc" -eq 0 ] && ok "wt rm succeeds once the session is gone" \
  || no "wt rm failed (rc=$rc): $(cat "$T/rm2.err")"

# Clone first, then snapshot: the snapshot is the clone's origin, so ZFS refuses the reverse.
[ "$(sed -n 1p "$ZFS_STATE/destroy.log")" = "$DS_PARENT/alpha" ] \
  && [ "$(sed -n 2p "$ZFS_STATE/destroy.log")" = "$snap_before" ] \
  && ok "destroys the clone first, then its origin snapshot" \
  || no "wrong destroy order: $(tr '\n' ' ' < "$ZFS_STATE/destroy.log")"

# Teardown must fire BEFORE the destroy: a daemon the enter hook left running pins the clone's
# mount, and a pinned dataset cannot be destroyed.
grep -q 'alpha teardown destroys=0' "$HOOK_LOG" \
  && ok "fires the teardown hook BEFORE destroying the clone" \
  || no "teardown did not precede the destroy: $(cat "$HOOK_LOG")"

# Unmerged work must survive: the branch is renamed, never deleted.
git -C "$CANON" show-ref --verify --quiet refs/heads/wt-archive/alpha \
  && ok "the sandbox branch is ARCHIVED (wt-archive/alpha), not deleted" \
  || no "branch was not archived: $(git -C "$CANON" branch --list 'wt*' | tr '\n' ' ')"
git -C "$CANON" show-ref --verify --quiet refs/heads/wt/alpha \
  && no "the original branch is still there — it should have been renamed" \
  || ok "...and the original wt/alpha is gone (renamed, not copied)"

[ ! -d "$WT_HOME/trees/alpha" ] && [ ! -d "$WT_HOME/meta/alpha" ] \
  && ok "the tree and metadata are gone" || no "tree/meta survived wt rm"

echo "== wt rm on a sandbox that never existed =="
wt rm ghost >/dev/null 2>"$T/ghost.err"; rc=$?
[ "$rc" -ne 0 ] \
  && ok "wt rm <typo> FAILS instead of reporting success" \
  || no "wt rm reported success for a sandbox that never existed"

echo "== wt rm refuses a clone with user-made dependents =="
wt new beta >/dev/null 2>&1 || { echo "  SETUP FAILED: wt new beta"; exit 1; }
# A user-made snapshot of the clone plus a child dataset inside it: `zfs destroy` would fail on
# every retry, so wt rm must refuse up front — naming both, destroying nothing, touching nothing.
printf '%s\n' "$DS_PARENT/beta@keepme" >> "$ZFS_STATE/snapshots"
printf '%s\n' "$DS_PARENT/beta/inner" >> "$ZFS_STATE/datasets"
: > "$ZFS_STATE/destroy.log"
wt rm beta >/dev/null 2>"$T/deps.err"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'dependents' "$T/deps.err" \
  && grep -q "$DS_PARENT/beta@keepme" "$T/deps.err" \
  && grep -q "$DS_PARENT/beta/inner" "$T/deps.err"; } \
  && ok "wt rm refuses a clone with dependents, and names them" \
  || no "wt rm dependents refusal (rc=$rc): $(cat "$T/deps.err")"
[ ! -s "$ZFS_STATE/destroy.log" ] && [ -d "$WT_HOME/trees/beta" ] \
  && git -C "$CANON" show-ref --verify --quiet refs/heads/wt/beta \
  && ok "...destroying nothing and leaving the sandbox intact" \
  || no "wt rm touched state while refusing: destroys=[$(tr '\n' ' ' < "$ZFS_STATE/destroy.log")]"
# Clear the dependents; the same rm must now succeed.
grep -vxF "$DS_PARENT/beta@keepme" "$ZFS_STATE/snapshots" > "$ZFS_STATE/.s"; mv "$ZFS_STATE/.s" "$ZFS_STATE/snapshots"
grep -vxF "$DS_PARENT/beta/inner" "$ZFS_STATE/datasets" > "$ZFS_STATE/.d"; mv "$ZFS_STATE/.d" "$ZFS_STATE/datasets"
wt rm beta >/dev/null 2>"$T/deps2.err"; rc=$?
[ "$rc" -eq 0 ] && [ ! -d "$WT_HOME/trees/beta" ] \
  && ok "...and succeeds once the dependents are gone" \
  || no "wt rm after clearing dependents failed (rc=$rc): $(cat "$T/deps2.err")"

echo "== the datasets must be disjoint, in both directions =="
# With the SOURCE nested under the PARENT, gc's clone sweep enumerates the source dataset and its
# WT_SNAPSHOT_EXCLUDE children as "orphan clones" and destroys them — and an exclude child holds
# the ONLY, never-snapshotted copy of its data. Unrecoverable. Both nestings are refused, and
# nothing may be destroyed on the way to refusing.
: > "$ZFS_STATE/destroy.log"
printf '%s\n' "fakepool/x" "fakepool/x/src" "fakepool/x/src/logs" > "$ZFS_STATE/datasets"
out=$(env PATH="$T/bin:$PATH" WT_CONFIG= ZFS_STATE="$ZFS_STATE" WT_HOME="$WT_HOME" \
      WT_CANONICAL="$CANON" WT_DS_SRC=fakepool/x/src WT_DS_PARENT=fakepool/x \
      bash "$WT" gc 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [ ! -s "$ZFS_STATE/destroy.log" ]; } \
  && ok "gc refuses WT_DS_SRC nested under WT_DS_PARENT, destroying nothing" \
  || no "gc accepted a nested layout (rc=$rc), destroyed: [$(tr '\n' ' ' < "$ZFS_STATE/destroy.log")]"

: > "$ZFS_STATE/destroy.log"
out=$(env PATH="$T/bin:$PATH" WT_CONFIG= ZFS_STATE="$ZFS_STATE" WT_HOME="$WT_HOME" \
      WT_CANONICAL="$CANON" WT_DS_SRC=fakepool/x WT_DS_PARENT=fakepool/x/src \
      bash "$WT" gc 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [ ! -s "$ZFS_STATE/destroy.log" ]; } \
  && ok "gc refuses WT_DS_PARENT nested under WT_DS_SRC, destroying nothing" \
  || no "gc accepted the reverse nesting (rc=$rc)"

echo "== safe_rmrf will not step outside WT_HOME =="
out=$(WT_HOME="$WT_HOME" bash -c 'source "$1"; safe_rmrf /etc' _ "$WT" 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [ -d /etc ]; } \
  && ok "safe_rmrf refuses a path outside WT_HOME" || no "safe_rmrf did not refuse /etc"
out=$(WT_HOME="$WT_HOME" bash -c 'source "$1"; safe_rmrf ""' _ "$WT" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "safe_rmrf refuses an empty path" || no "safe_rmrf accepted an empty path"

echo
echo "wt-newrm-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
