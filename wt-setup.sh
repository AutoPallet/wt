#!/bin/bash
# In-namespace setup for `wt enter`. Runs as REAL ROOT (uid 0 in the container's initial
# userns) inside a new mountns from `sudo unshare --mount --propagation private`. Mounting the
# per-sandbox ZFS clone requires real CAP_SYS_ADMIN — userns CAP_SYS_ADMIN is NOT enough (the
# ZFS module rejects delegated dataset mounts from a non-init userns). After the mounts, drops
# to the target uid via setpriv and execs the command. The sudo'd mountns is torn down with
# this process tree, so the ZFS mount auto-cleans on exit (no umount needed).
#
# Knows nothing about any project, language or toolchain: everything project-specific arrives
# as WT_* env from `wt`, or is done by the session enter-hook.
set -euo pipefail

# Export the KEY=VALUE lines a session enter-hook printed on stdout (direnv-style) into this
# process's env, so they reach the command we exec below. The key is split at the FIRST '=',
# so a value may itself contain '='. Assignment is direct and never eval'd — a hook cannot
# inject shell here. Anything that isn't a well-formed KEY=VALUE (blank lines, comments,
# stray chatter the hook forgot to redirect) is ignored rather than trusted.
apply_hook_env() {
  local kv
  while IFS= read -r kv; do
    [[ $kv =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    export "${kv%%=*}=${kv#*=}"
  done
}

# The privilege drop, as one overridable command. setpriv needs CAP_SETUID even to "drop" to
# the uid it is already at, so an unprivileged unit test cannot call it and substitutes a
# no-op (WT_DROP_PRIV=). Real setuid, not a nested userns: a userns would shadow every host
# uid not explicitly mapped, so files owned by other users would show up as nobody (65534) and
# git/build tools would reject them with dubious-ownership / permission-denied.
WT_TARGET_UID=${WT_TARGET_UID:-$(id -u)}
WT_TARGET_GID=${WT_TARGET_GID:-$(id -g)}
WT_DROP_PRIV=${WT_DROP_PRIV-setpriv --reuid=$WT_TARGET_UID --regid=$WT_TARGET_GID --init-groups --inh-caps=-all --}

# Run the session enter-hook as the target user, in THIS namespace, and fold its emitted env
# into ours. wt knows nothing about what the hook starts.
#
# "Best-effort" is scoped deliberately, because getting it wrong is silently destructive:
#
#   ran, then failed   -> CONTINUE. It may have set up partially, and whatever env it managed
#                         to emit is still applied (a well-written hook prints its env FIRST,
#                         before the parts that can fail).
#   could not RUN      -> ABORT, loudly. 127/126 means the session would silently inherit NONE
#     (127/126)           of what the hook guarantees — for a hook that hands out a per-sandbox
#                         daemon socket, the session would quietly fall back to a SHARED one and
#                         write this sandbox's build outputs into another sandbox's clone. A
#                         missing hook is a config error, not a runtime hiccup, and a hard error
#                         beats corrupt artifacts.
run_enter_hook() {
  [ -n "${WT_HOOK_ENTER:-}" ] || return 0
  local out rc=0
  # shellcheck disable=SC2086  # deliberate word-split: WT_DROP_PRIV is a command + its args
  out=$($WT_DROP_PRIV bash -c "$WT_HOOK_ENTER" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
    echo "wt: enter hook could not be executed: $WT_HOOK_ENTER" >&2
    echo "wt: refusing to continue — the session would silently lose everything the hook sets up." >&2
    echo "wt: a sandbox cloned BEFORE the hook existed will not have it; recreate it." >&2
    exit 1
  fi
  [ "$rc" -eq 0 ] || echo "wt: enter hook failed (rc=$rc); continuing with the env it emitted" >&2
  # Here-string, NOT a pipe: a pipe would run apply_hook_env in a subshell and its exports
  # would die with it, silently losing the hook's env.
  apply_hook_env <<<"$out"
}

# Sourcing this file (test/test-hooks-unit.sh) defines the helpers above without running any
# of the mount/privilege work below.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

name="$1"; shift
[ "${1:-}" = -- ] && shift

# sudo's secure_path strips PATH down to system dirs even under -E, which would hide the
# caller's toolchains from the dropped-to-target process. `wt` stashes the real PATH in
# WT_PATH (which sudo does preserve) purely so we can put it back — wt itself has no idea
# what is on it.
export PATH="${WT_PATH:-$PATH}"

# All inputs arrive via WT_* env exported by `wt` (preserved through `sudo -E`).
: "${WT_CANONICAL:?}" "${WT_SRC_CLONE:?}" "${WT_META:?}"
: "${WT_GIT_HOLD:?}" "${WT_GIT_REAL:?}" "${WT_HOLD_DIR:?}"

# 1. Pre-shadow binds. Paths still resolve to main's host view here (the clone is not yet
#    mounted over $WT_CANONICAL). After step 2 these binds keep main's live .git and its
#    never-snapshotted subpaths reachable inside the namespace, via the hold paths.
mount --bind "$WT_GIT_REAL" "$WT_GIT_HOLD"
for sub in ${WT_SNAPSHOT_EXCLUDE:-}; do
  hold="$WT_HOLD_DIR/${sub//\//_}"          # keep this key in sync with wt's exclude_key()
  mkdir -p "$hold"
  mount --bind "$WT_CANONICAL/$sub" "$hold"
done

# 2. Mount the per-sandbox ZFS clone over the canonical path. Real CAP_SYS_ADMIN required (we
#    have it as sudo'd root); private propagation keeps this invisible outside the mountns.
#    The clone is read-write (CoW from its origin snapshot), so every sandbox write — source
#    edits AND build outputs — lands in the clone, and main is untouched.
mount -t zfs "$WT_SRC_CLONE" "$WT_CANONICAL"

# 3. Restore each excluded subpath to main's live view. In the clone these are just empty
#    child-dataset mountpoint dirs (the children are never snapshotted, so none of their data
#    is in the clone). Every sandbox therefore shares ONE real copy, on the host.
for sub in ${WT_SNAPSHOT_EXCLUDE:-}; do
  mount --bind "$WT_HOLD_DIR/${sub//\//_}" "$WT_CANONICAL/$sub"
done

# 4. Replace the snapshot-frozen .git directory with the worktree pointer file, so git in the
#    sandbox resolves through main's LIVE .git (via the WT_GIT_HOLD bind in step 1). Done
#    in-place inside the clone — this destroys the clone's frozen .git/ copy, but CoW means
#    the snapshot still references those blocks, so the storage cost stays at the snapshot,
#    not the clone. Idempotent across re-entry: after the first enter, $WT_CANONICAL/.git is
#    already the pointer file and the rm is a no-op. Chown so the target user owns the pointer
#    after the privilege drop, or git refuses with "dubious ownership in repository".
if [ -d "$WT_CANONICAL/.git" ]; then
  rm -rf "$WT_CANONICAL/.git"
fi
cp -f "$WT_META/dot_git" "$WT_CANONICAL/.git"
chown "$WT_TARGET_UID:$WT_TARGET_GID" "$WT_CANONICAL/.git"

# 5. Override the per-worktree gitdir back-pointer (private propagation keeps the host's real
#    .git untouched). main's .git/worktrees/$name/gitdir was written by `wt new`'s `git
#    worktree add` with the host-side placeholder path ($WT_HOME/trees/<name>/.git), but
#    inside the sandbox the worktree IS $WT_CANONICAL — so override the in-NS view to match.
mount --bind "$WT_META/gitdir_backptr" "$WT_GIT_HOLD/worktrees/$name/gitdir"

cd "$WT_CANONICAL"

# 6. First-enter checkout of a non-HEAD ref. `wt new <name> <ref>` clones main's CURRENT tree
#    (so build outputs stay warm) but points the branch HEAD at <ref>, so the clone holds
#    main's files, not <ref>'s. Materialize <ref> into the writable clone here, where it is
#    mounted, with minimal CoW writes: seed the index from the clone's actual baseline
#    (WT_SRC_COMMIT), refresh stat info, then a two-tree read-tree writes only the files that
#    differ (falling back to a hard reset if local state conflicts). Run as the target user so
#    the written files and index are theirs. A host-side sentinel makes this once-only, so
#    re-entry preserves the sandbox's working state. Skipped for the common current-state
#    clone (WT_REF_SHA == WT_SRC_COMMIT), where `wt new` already seeded the index.
if [ -n "${WT_REF_SHA:-}" ] && [ -n "${WT_SRC_COMMIT:-}" ] \
   && [ "$WT_REF_SHA" != "$WT_SRC_COMMIT" ] && [ ! -e "$WT_META/materialized" ]; then
  # shellcheck disable=SC2086
  if $WT_DROP_PRIV bash -c '
        set -e
        cd "$1"
        git read-tree "$2"                                                # index <- clone baseline
        git update-index -q --refresh || true                             # stamp stat; clean baseline
        git read-tree -m -u "$3" 2>/dev/null || git reset -q --hard "$3"  # write only the diffs
        git update-index -q --refresh || true
      ' _ "$WT_CANONICAL" "$WT_SRC_COMMIT" "$WT_REF_SHA"; then
    : > "$WT_META/materialized"
    chown "$WT_TARGET_UID:$WT_TARGET_GID" "$WT_META/materialized" 2>/dev/null || true
  else
    echo "wt: failed to check out $WT_REF_SHA into sandbox; left at baseline $WT_SRC_COMMIT" >&2
  fi
fi

# 7. Fire the session enter-hook (as the target user, in THIS namespace) and export whatever
#    env it emits, BEFORE handing off. Done explicitly here rather than from a shell rc file
#    so it also covers a directly-exec'd command (`wt enter x -- cmd`, `wt claude`).
run_enter_hook

# 8. Drop privileges and hand off.
# shellcheck disable=SC2086
exec $WT_DROP_PRIV "$@"
