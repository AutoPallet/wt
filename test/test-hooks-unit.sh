#!/usr/bin/env bash
# Fast, hermetic unit tests for wt's session-hook contract (no ZFS/root/docker needed).
#
# The hooks are what keep `wt` generic. The motivating case: a per-sandbox compiler-cache server
# (sccache) used to be wired straight into wt, and is now supplied by the consuming project as
# WT_HOOK_ENTER / WT_HOOK_TEARDOWN. These tests pin that contract down so it can't creep back.
#
# `zfs` is stubbed on PATH and the hook is stubbed as a script that logs each call, so the
# real `wt gc` code path runs for real. What is NOT hermetic: "teardown fires exactly once on
# the LAST of N concurrent sessions" goes through `sudo unshare` + a real ZFS mount. We test
# its two composable halves here (the name_active predicate, and run_teardown_hook); the full
# multi-session path belongs to the ZFS end-to-end test-harness.sh.
set -uo pipefail
# Hermetic, and this is the sharp edge: wt resolves config as env > file > default. Setting
# WT_CONFIG= keeps an installed /etc/wt/config out, but says nothing about the ENVIRONMENT — and
# every `wt enter` exports a WT_* bundle, so running this suite inside a sandbox would quietly
# feed the code under test that sandbox's real config. It passed for the wrong reason. Scrub the
# inherited namespace first; everything the tests depend on is set explicitly below.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WT="$DIR/../wt"
SETUP="$DIR/../wt-setup.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL  $1 (got: ${2:-})"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# --- stub zfs: datasets come from $ZFS_STATE/clones, destroys are recorded ------------------
# wt gc calls: `zfs list -H -o name -r <parent>`  ($5 == -r) and
#              `zfs list -H -o name -t snapshot <src>` ($5 == -t), plus get/destroy.
cat > "$BIN/zfs" <<'EOF'
#!/bin/bash
case "$1" in
  list)
    case "${5:-}" in
      -t) cat "$ZFS_STATE/snapshots" 2>/dev/null ;;
      *)  cat "$ZFS_STATE/clones"    2>/dev/null ;;
    esac ;;
  get)     echo '-' ;;
  destroy) echo "$2" >> "$ZFS_STATE/destroyed" ;;
esac
exit 0
EOF

# --- stub hook: records every invocation as "<sandbox> <verb>" ------------------------------
cat > "$BIN/hook-log" <<'EOF'
#!/bin/bash
printf '%s %s\n' "${WT_SANDBOX:-<unset>}" "${1:-<noverb>}" >> "$HOOK_LOG"
EOF
chmod +x "$BIN/zfs" "$BIN/hook-log"

# Fresh WT_HOME + zfs state per case. One live sandbox ("live", has a tree) and one orphan
# clone ("orphan", tree is gone) — gc must tear down only the orphan.
setup_case() {
  rm -rf "$TMP/home" "$TMP/zfs"; mkdir -p "$TMP/home/trees/live" "$TMP/home/active" "$TMP/zfs"
  printf 'tank/wt\ntank/wt/live\ntank/wt/orphan\n' > "$TMP/zfs/clones"   # line 1 = the parent
  : > "$TMP/zfs/snapshots"
  : > "$TMP/zfs/destroyed"
  : > "$TMP/hook.log"
}

# WT_CONFIG= skips any installed /etc/wt/config, so a real one on the machine cannot reach in
# and change these answers.
run_gc() {
  PATH="$BIN:$PATH" ZFS_STATE="$TMP/zfs" HOOK_LOG="$TMP/hook.log" WT_CONFIG= \
  WT_HOME="$TMP/home" WT_CANONICAL="$TMP/canonical" WT_DS_SRC=tank/src WT_DS_PARENT=tank/wt \
  WT_HOOK_TEARDOWN="${1:-hook-log teardown}" \
    "$WT" gc >/dev/null 2>&1
}

# 1/2. gc fires teardown for the orphan clone, exactly once, with WT_SANDBOX set — and not for
#      the live one. (Both assertions come from the same run: the log must be exactly one line.)
setup_case
run_gc; rc=$?
log=$(cat "$TMP/hook.log")
{ [ "$rc" -eq 0 ] && [ "$log" = "orphan teardown" ]; } \
  && ok "gc fires teardown once for the orphan clone, with WT_SANDBOX set" \
  || no "gc teardown for orphan" "rc=$rc log=[$log]"

[[ "$log" != *live* ]] \
  && ok "gc does NOT fire teardown for a live (non-orphan) clone" \
  || no "gc spared the live clone" "$log"

# The teardown must precede the destroy, or the daemon would still pin the clone's mount.
[ "$(cat "$TMP/zfs/destroyed")" = "tank/wt/orphan" ] \
  && ok "gc destroys only the orphan clone" || no "destroy list" "$(cat "$TMP/zfs/destroyed")"

# 3. Best-effort contract: a hook that fails must not fail the wt operation.
setup_case
run_gc "false"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$TMP/zfs/destroyed")" = "tank/wt/orphan" ]; } \
  && ok "a failing teardown hook does not fail gc (best-effort), and gc still reclaims" \
  || no "failing hook broke gc" "rc=$rc destroyed=[$(cat "$TMP/zfs/destroyed")]"

# 4/5. The last-exit decision, `name_active <n> || run_teardown_hook <n>` — the exact
#      composition the EXIT trap in wt_enter uses. A marker is LIVE only while a process holds
#      its flock (the file existing proves nothing: SIGKILL leaves it behind).
decide() {  # $1 = sandbox name; prints the hook log the decision produced
  PATH="$BIN:$PATH" HOOK_LOG="$TMP/hook.log" WT_HOME="$TMP/home" WT_CONFIG= \
  WT_HOOK_TEARDOWN="hook-log teardown" \
    bash -c 'source "$1"; name_active "$2" || run_teardown_hook "$2"' _ "$WT" "$1" >/dev/null 2>&1
  cat "$TMP/hook.log"
}

setup_case
touch "$TMP/home/active/livebox.1"
flock -x "$TMP/home/active/livebox.1" -c 'sleep 10' &   # a live session still holds its lock
lockpid=$!
sleep 0.3
[ -z "$(decide livebox)" ] \
  && ok "live marker (lock held) -> teardown SKIPPED" || no "live marker fired teardown" "$(cat "$TMP/hook.log")"
kill "$lockpid" 2>/dev/null; wait "$lockpid" 2>/dev/null

setup_case
touch "$TMP/home/active/deadbox.1"                      # marker left by a SIGKILLed session
[ "$(decide deadbox)" = "deadbox teardown" ] \
  && ok "stale marker (no lock holder) -> teardown FIRES" || no "stale marker skipped teardown" "$(cat "$TMP/hook.log")"

# 6/7. apply_hook_env — the enter hook's stdout becomes session env. Split at the FIRST '=' so
#      values may contain '='; anything not a well-formed KEY=VALUE is ignored, not trusted.
env_out=$(bash -c '
  source "$1"
  apply_hook_env <<EOF
FOO=bar
PATHY=a=b=c
_OK=ok

# a comment
not an assignment
1BAD=x
has space=y
EOF
  printf "FOO=%s|PATHY=%s|_OK=%s\n" "${FOO:-<unset>}" "${PATHY:-<unset>}" "${_OK:-<unset>}"
  env | grep -qE "^(1BAD|has)" && echo LEAKED || echo CLEAN
' _ "$SETUP" 2>&1)

[[ "$env_out" == *'FOO=bar|PATHY=a=b=c|_OK=ok'* ]] \
  && ok "apply_hook_env exports KEY=VALUE, keeps '=' in the value, allows a leading _" \
  || no "apply_hook_env exports" "$env_out"

[[ "$env_out" == *CLEAN* ]] \
  && ok "apply_hook_env ignores blank/comment/malformed lines (no junk in env)" \
  || no "apply_hook_env leaked a malformed line" "$env_out"

# 8/9/10. run_enter_hook's failure contract. This is the sharp edge. A hook typically hands the
#   session a PER-SANDBOX daemon socket. If a missing hook were merely "best-effort", the session
#   would start without it and fall back to whatever SHARED default the tool has — one daemon,
#   living in one namespace, writing every sandbox's build outputs into the WRONG clone. So:
#   a hook that RAN and failed still delivers its env; a hook that could not RUN aborts.
# WT_DROP_PRIV= disables the setpriv drop: it needs CAP_SETUID even to drop to the uid we are
# already at, so an unprivileged test cannot call it. The real setpriv path is covered by the
# ZFS end-to-end harness, which runs as root.
enter_hook() {  # $1 = WT_HOOK_ENTER; prints "rc=<n> UDS=<value>"
  WT_DROP_PRIV= bash -c '
    source "$1"
    export WT_HOOK_ENTER="$2"
    set +e; run_enter_hook; rc=$?; set -e
    printf "rc=%s SOCK=%s\n" "$rc" "${CACHE_SOCK:-<unset>}"
  ' _ "$SETUP" "$1" 2>/dev/null
}

# A hook that emits its env and THEN fails: the env must still land, session continues.
out=$(enter_hook 'echo CACHE_SOCK=/tmp/cache-x.sock; exit 3')
[ "$out" = "rc=0 SOCK=/tmp/cache-x.sock" ] \
  && ok "enter hook that ran-then-failed still delivers its env, session continues" \
  || no "ran-then-failed hook" "$out"

# A hook that cannot be executed at all (127) must ABORT, not silently drop the env.
out=$(enter_hook '/nonexistent/hook enter'); rc_line=$out
[[ "$rc_line" != *"rc=0"* ]] \
  && ok "enter hook that could not run ABORTS (no silent fallback to a shared daemon socket)" \
  || no "missing enter hook was silently tolerated" "$rc_line"

# ...and it says why, rather than dying mutely.
msg=$(WT_DROP_PRIV= bash -c 'source "$1"; export WT_HOOK_ENTER="/nonexistent/hook enter"; run_enter_hook' _ "$SETUP" 2>&1)
[[ "$msg" == *"could not be executed"* ]] \
  && ok "the abort explains itself on stderr" || no "abort message" "$msg"

# 11. No hook configured (the extracted-wt default) must be a clean no-op, not an error.
setup_case
PATH="$BIN:$PATH" ZFS_STATE="$TMP/zfs" WT_HOME="$TMP/home" WT_CONFIG= \
WT_CANONICAL="$TMP/canonical" WT_DS_SRC=tank/src WT_DS_PARENT=tank/wt WT_HOOK_TEARDOWN= \
  "$WT" gc >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$TMP/zfs/destroyed")" = "tank/wt/orphan" ]; } \
  && ok "no teardown hook configured -> gc still works (hooks are optional)" \
  || no "empty hook broke gc" "rc=$rc"

echo "wt-hooks-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
