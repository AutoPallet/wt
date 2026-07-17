#!/bin/bash
# In-namespace setup for `wt enter`. Runs as REAL ROOT (uid 0 in the container's initial userns)
# inside a fresh mount namespace from `sudo unshare --mount --propagation private`. Mounting the
# per-sandbox ZFS clone needs real CAP_SYS_ADMIN — userns CAP_SYS_ADMIN is not enough, the ZFS
# module rejects delegated mounts from a non-init userns. Once the mounts are up it drops to the
# target uid and execs the command. The mount namespace dies with this process tree, so the ZFS
# mount cleans itself up on exit; nothing to umount.
#
# THIS SCRIPT IS NOT A SECURITY BOUNDARY, and must not be made into one.
#
# It is root-equivalent BY DESIGN: running as root, it takes WT_CANONICAL, WT_SRC_CLONE, WT_PATH
# and the hook command straight from its environment, and then mounts, chowns, and `rm -rf`s with
# them. That is fine in wt's intended setting, where the user already has blanket sudo — it hands
# them nothing they did not have. It is NOT fine as a privilege gate. Do not write a "narrow"
# NOPASSWD sudoers rule for `unshare ... wt-setup.sh` believing it contains anything: whoever can
# invoke it can choose what root mounts and what root deletes. If you need a real boundary, put it
# around who may run `wt` at all.
#
# Knows nothing about any project, language or toolchain. Everything project-specific arrives as
# WT_* env from `wt`, or is done by the enter hook.
set -euo pipefail

# Export the KEY=VALUE lines an enter hook printed on stdout (direnv-style) into this process,
# so they reach the command exec'd below. Split at the FIRST '=', so a value may contain '='.
# Assignment is direct, never eval'd: a hook cannot inject shell here. Anything that isn't a
# well-formed KEY=VALUE — blank lines, comments, chatter the hook forgot to redirect — is
# ignored rather than trusted.
apply_hook_env() {
  local kv
  while IFS= read -r kv; do
    [[ $kv =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    export "${kv%%=*}=${kv#*=}"
  done
}

# Flatten an excluded subpath into one hold-dir component. Injective — escape the escape
# character, then the separator (_ -> _U, / -> _S) — so two excluded subpaths can never land on
# the same hold path and cross-wire their bind mounts. `wt` defines this identically, and
# test-config-unit.sh asserts the two agree: they are derived independently on either side of the
# sudo boundary, so a drift here would silently mis-bind a sandbox's shared directories.
exclude_key() { local s=${1//_/_U}; printf '%s' "${s//\//_S}"; }

# The privilege drop, as one overridable command. --init-groups needs CAP_SETGID even to "drop"
# to the ids we already hold, so an unprivileged unit test cannot call setpriv at all and
# substitutes a no-op (WT_DROP_PRIV=). Real setuid, not a nested userns: a userns would shadow
# every host uid it didn't map, so files owned by other users would appear as nobody (65534) and
# git and build tools would reject them with dubious-ownership or permission-denied.
WT_TARGET_UID=${WT_TARGET_UID:-$(id -u)}
WT_TARGET_GID=${WT_TARGET_GID:-$(id -g)}
WT_DROP_PRIV=${WT_DROP_PRIV-setpriv --reuid=$WT_TARGET_UID --regid=$WT_TARGET_GID --init-groups --inh-caps=-all --}

# Run the enter hook as the target user, in THIS namespace, and fold the env it prints into ours.
# wt has no idea what the hook starts.
#
# The hook's exit code GATES the session: anything non-zero aborts. That is a deliberate choice to
# fail loudly rather than quietly, because a half-set-up sandbox is the expensive failure. Consider
# a hook whose job is to hand the session a PER-SANDBOX build-daemon socket: if it doesn't run, the
# session doesn't get that env, falls back to the tool's SHARED default, and one daemon in one
# namespace writes every sandbox's build outputs into the WRONG clone. You would not find out from
# an error; you would find out from a corrupt artifact days later.
#
# Sniffing exit codes to tell "the hook could not start" (126/127) from "the hook ran and failed"
# cannot work, and trying was a bug: through `bash -c`, a hook that ends in an exec of a missing
# binary is also 127, and a privilege drop that fails is 1 — so the case that most needed the abort
# got classified as tolerable. One rule, no classification: non-zero is non-zero.
#
# A hook step that is genuinely advisory should say so with `|| true`.
run_enter_hook() {
  [ -n "${WT_HOOK_ENTER:-}" ] || return 0
  local out rc=0
  # stdout is captured (it is the env channel); stderr is left alone, so the hook's diagnostics
  # reach the terminal. A hook that wants to be quiet redirects itself: WT_HOOK_ENTER='h 2>/dev/null'.
  # shellcheck disable=SC2086  # deliberate word-split: WT_DROP_PRIV is a command plus its args
  out=$($WT_DROP_PRIV bash -c "$WT_HOOK_ENTER") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "wt: enter hook failed (rc=$rc): $WT_HOOK_ENTER" >&2
    echo "wt: refusing to continue — the session would be missing whatever the hook sets up." >&2
    echo "wt: (a sandbox cloned BEFORE the hook existed will not have it; recreate it.)" >&2
    exit 1
  fi
  # Here-string, NOT a pipe: a pipe runs apply_hook_env in a subshell, whose exports die with it.
  apply_hook_env <<<"$out"
}

# Sourcing this file (test/test-hooks-unit.sh) defines the helpers above and runs none of the
# mount or privilege work below.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

name="$1"; shift
[ "${1:-}" = -- ] && shift

# sudo's secure_path strips PATH to system dirs even when PATH is preserved, hiding the caller's toolchains
# from the process we drop to. `wt` stashes the real PATH in WT_PATH (which sudo does preserve)
# purely so we can put it back. wt has no idea what is on it.
export PATH="${WT_PATH:-$PATH}"

# Every input arrives as WT_* env from `wt`, through `sudo --preserve-env`.
: "${WT_CANONICAL:?}" "${WT_SRC_CLONE:?}" "${WT_META:?}"
: "${WT_GIT_HOLD:?}" "${WT_GIT_REAL:?}" "${WT_HOLD_DIR:?}"

# Pre-shadow binds, while paths still resolve to main's host view — the clone is not mounted yet.
# Once it is, these hold paths are what keep main's live .git and the never-snapshotted subpaths
# reachable from inside the namespace.
mount --bind "$WT_GIT_REAL" "$WT_GIT_HOLD"
for sub in ${WT_SNAPSHOT_EXCLUDE:-}; do
  hold="$WT_HOLD_DIR/$(exclude_key "$sub")"
  mkdir -p "$hold"
  mount --bind "$WT_CANONICAL/$sub" "$hold"
done

# The clone, over the canonical path. This is the whole trick: same path, so absolute paths in
# build artifacts still resolve. Private propagation keeps it invisible outside this namespace.
# The clone is read-write (CoW from its origin snapshot), so every sandbox write — source edits
# and build outputs alike — lands in the clone, and main is untouched.
mount -t zfs "$WT_SRC_CLONE" "$WT_CANONICAL"

# Restore the excluded subpaths to main's live view. Inside the clone they are empty
# child-dataset mountpoints — the children were never snapshotted, so none of their data is
# there. Binding the canonical copy back over them gives every sandbox ONE shared live copy.
for sub in ${WT_SNAPSHOT_EXCLUDE:-}; do
  mount --bind "$WT_HOLD_DIR/$(exclude_key "$sub")" "$WT_CANONICAL/$sub"
done

# Swap the clone's snapshot-frozen .git directory for the worktree pointer file, so git in the
# sandbox resolves through main's LIVE .git (bound at WT_GIT_HOLD above). The rm destroys the
# clone's frozen copy, but CoW means the snapshot still holds those blocks — the storage cost
# stays with the snapshot. Idempotent on re-entry: .git is already the pointer file by then.
# Chown it, or git refuses the target user with "dubious ownership in repository".
if [ -d "$WT_CANONICAL/.git" ]; then
  rm -rf "$WT_CANONICAL/.git"
fi
cp -f "$WT_META/dot_git" "$WT_CANONICAL/.git"
chown "$WT_TARGET_UID:$WT_TARGET_GID" "$WT_CANONICAL/.git"

# `wt new`'s `git worktree add` wrote the gitdir back-pointer with the host-side placeholder path
# ($WT_HOME/trees/<name>/.git), but inside the sandbox the worktree IS $WT_CANONICAL. Override
# the in-namespace view to match; private propagation keeps the host's real .git untouched.
mount --bind "$WT_META/gitdir_backptr" "$WT_GIT_HOLD/worktrees/$name/gitdir"

cd "$WT_CANONICAL"

# First-enter checkout of a non-HEAD ref. `wt new <name> <ref>` clones main's CURRENT tree (that
# is what keeps the build warm) but points the branch at <ref> — so the clone holds main's files,
# not <ref>'s. Materialize <ref> here, where the clone is mounted and writable, with as few CoW
# writes as possible: seed the index from the clone's actual baseline (WT_SRC_COMMIT), refresh
# stat info, then let a two-tree read-tree write only the files that differ. As the target user,
# so the files and index are theirs. A host-side sentinel makes it once-only, so re-entry
# preserves the sandbox's working state.
# Skipped for the common case (WT_REF_SHA == WT_SRC_COMMIT), where `wt new` seeded the index.
#
# read-tree -m -u refuses when a locally-dirty path also differs baseline->ref — and the clone
# carries main's dirty diff, which `wt new` promised would survive. So on refusal: record the
# dirt against the baseline, hard-reset to the ref, and replay the dirt on top. Non-conflicting
# edits survive; a genuinely conflicting file gets conflict markers instead of silently
# reverting to the ref's version. (An untracked file that the ref wants to create is still
# overwritten by the reset — read-tree's message below names it.)
if [ -n "${WT_REF_SHA:-}" ] && [ -n "${WT_SRC_COMMIT:-}" ] \
   && [ "$WT_REF_SHA" != "$WT_SRC_COMMIT" ] && [ ! -e "$WT_META/materialized" ]; then
  # shellcheck disable=SC2086
  if $WT_DROP_PRIV bash -c '
        set -e
        cd "$1"
        git read-tree "$2"                             # index <- clone baseline
        git update-index -q --refresh >/dev/null || true   # stamp stat; clean baseline
        if ! rt_err=$(git read-tree -m -u "$3" 2>&1); then # write only the diffs
          echo "wt: carried working-tree changes overlap the checkout of $3:" >&2
          printf "%s\n" "$rt_err" | sed "s/^/wt:   /" >&2
          dirt=$(git diff --binary "$2")
          git reset -q --hard "$3"
          if [ -n "$dirt" ] && ! printf "%s\n" "$dirt" | git apply --3way; then
            echo "wt: some carried changes conflict with $3 — look for conflict markers" >&2
          fi
        fi
        git update-index -q --refresh >/dev/null || true
      ' _ "$WT_CANONICAL" "$WT_SRC_COMMIT" "$WT_REF_SHA"; then
    : > "$WT_META/materialized"
    chown "$WT_TARGET_UID:$WT_TARGET_GID" "$WT_META/materialized" 2>/dev/null || true
  else
    echo "wt: failed to check out $WT_REF_SHA into sandbox; left at baseline $WT_SRC_COMMIT" >&2
  fi
fi

# Stamp the index's stat cache. On the common path (`wt new <name>` with no ref), the index was
# seeded host-side with a bare read-tree, which stores NO stat data — so git's first look at the
# tree re-hashes every tracked file through its clean filters, and plumbing like `git diff`
# (which never writes the index back) pays that on every call. One refresh here, as the target
# user against the mounted clone, settles it: subsequent enters are a fast all-match stat sweep.
# stdout is silenced because --refresh lists carried-dirty files, which is noise at every enter;
# `|| true` because a non-empty such list is also its exit status.
# shellcheck disable=SC2086
$WT_DROP_PRIV git -C "$WT_CANONICAL" update-index -q --refresh >/dev/null 2>&1 || true

# Fire the enter hook and export what it emits, before handing off. Done here rather than from a
# shell rc file so it also covers a directly-exec'd command (`wt enter x -- cmd`), which never
# sources one.
run_enter_hook

# shellcheck disable=SC2086
exec $WT_DROP_PRIV "$@"
