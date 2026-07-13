#!/usr/bin/env bash
# Fast, hermetic unit tests for wt's session-hook contract (no ZFS/root/docker needed).
#
# The hooks are what keep `wt` generic — every project-specific thing a sandbox needs (a build
# cache, a language server, session env) arrives through WT_HOOK_ENTER / WT_HOOK_TEARDOWN and
# nothing else. These tests pin that contract down so it can't quietly erode.
#
# `zfs` is stubbed on PATH and the hook is a script that logs each call, so the real `wt gc` code
# path runs for real. What is NOT covered: "teardown fires exactly once on the LAST of N
# concurrent sessions" needs `sudo unshare` and a real ZFS mount. Its two composable halves are
# tested here (the name_active predicate, and run_teardown_hook); the multi-session path itself
# needs a real pool.
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

# --- stub hook: records every invocation as "<sandbox> <verb> destroys=<n>" -----------------
# destroys=<n> is how many datasets had been destroyed when the hook fired. gc must tear a
# sandbox down BEFORE destroying its clone — a daemon the enter hook left running pins the
# clone's mount, and a pinned dataset cannot be destroyed. Recording the count at invocation
# time is what makes the ORDER assertable; comparing two logs afterwards can't see it.
cat > "$BIN/hook-log" <<'EOF'
#!/bin/bash
n=$(wc -l < "$ZFS_STATE/destroyed" 2>/dev/null || echo 0)
printf '%s %s destroys=%s\n' "${WT_SANDBOX:-<unset>}" "${1:-<noverb>}" "$n" >> "$HOOK_LOG"
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

# gc fires teardown for the orphan clone, once, with WT_SANDBOX set — and not for the live one.
# Both assertions come from one run: the log must be exactly one line.
setup_case
run_gc; rc=$?
log=$(cat "$TMP/hook.log")
{ [ "$rc" -eq 0 ] && [ "$log" = "orphan teardown destroys=0" ]; } \
  && ok "gc fires teardown once for the orphan clone, with WT_SANDBOX set" \
  || no "gc teardown for orphan" "rc=$rc log=[$log]"

[[ "$log" != *live* ]] \
  && ok "gc does NOT fire teardown for a live (non-orphan) clone" \
  || no "gc spared the live clone" "$log"

# The teardown must precede the destroy, or the daemon would still pin the clone's mount. The
# hook stamps how many destroys had happened when it ran, so this sees the ORDER, not just that
# both occurred.
[[ "$log" == *"destroys=0"* ]] \
  && ok "gc fires teardown BEFORE destroying the clone (nothing destroyed yet when the hook ran)" \
  || no "gc destroyed the clone before tearing it down" "$log"

[ "$(cat "$TMP/zfs/destroyed")" = "tank/wt/orphan" ] \
  && ok "gc destroys only the orphan clone" || no "destroy list" "$(cat "$TMP/zfs/destroyed")"

# Best-effort: a hook that fails must not fail the wt operation that called it.
setup_case
run_gc "false"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$TMP/zfs/destroyed")" = "tank/wt/orphan" ]; } \
  && ok "a failing teardown hook does not fail gc (best-effort), and gc still reclaims" \
  || no "failing hook broke gc" "rc=$rc destroyed=[$(cat "$TMP/zfs/destroyed")]"

# The last-exit decision, `name_active <n> || run_teardown_hook <n>` — the exact composition
# wt_enter's EXIT trap uses. A marker is live only while a process holds its flock; the file
# existing proves nothing, since SIGKILL leaves it behind.
decide() {  # $1 = sandbox name; prints the hook log the decision produced
  PATH="$BIN:$PATH" HOOK_LOG="$TMP/hook.log" ZFS_STATE="$TMP/zfs" WT_HOME="$TMP/home" WT_CONFIG= \
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
[ "$(decide deadbox)" = "deadbox teardown destroys=0" ] \
  && ok "stale marker (no lock holder) -> teardown FIRES" || no "stale marker skipped teardown" "$(cat "$TMP/hook.log")"

# apply_hook_env — the enter hook's stdout becomes session env. Split at the FIRST '=' so values
# may contain '='; anything not a well-formed KEY=VALUE is ignored rather than trusted.
#
# The injection case is the load-bearing one. apply_hook_env runs in wt-setup.sh's ROOT process,
# and the hook whose output it is parsing ran privilege-DROPPED. The assignment is direct
# (export "K=V"), never eval'd, so a value is data. Swap that for `eval "export $kv"` — which is
# exactly how someone would "add" $HOME expansion in hook values — and unprivileged hook output
# becomes root command execution. Nothing else in the suite pins this, so it is pinned here.
canary="$TMP/pwned"
env_out=$(CANARY="$canary" bash -c '
  source "$1"
  apply_hook_env <<EOF
FOO=bar
PATHY=a=b=c
_OK=ok
EVIL=\$(touch $CANARY)
EVILTOO=\`touch $CANARY\`

# a comment
not an assignment
1BAD=x
has space=y
EOF
  printf "FOO=%s|PATHY=%s|_OK=%s|EVIL=%s\n" "${FOO:-<unset>}" "${PATHY:-<unset>}" "${_OK:-<unset>}" "${EVIL:-<unset>}"
  env | grep -qE "^(1BAD|has)" && echo LEAKED || echo CLEAN
' _ "$SETUP" 2>&1)

[[ "$env_out" == *'FOO=bar|PATHY=a=b=c|_OK=ok'* ]] \
  && ok "apply_hook_env exports KEY=VALUE, keeps '=' in the value, allows a leading _" \
  || no "apply_hook_env exports" "$env_out"

[[ "$env_out" == *CLEAN* ]] \
  && ok "apply_hook_env ignores blank/comment/malformed lines (no junk in env)" \
  || no "apply_hook_env leaked a malformed line" "$env_out"

{ [ ! -e "$canary" ] && [[ "$env_out" == *'EVIL=$(touch'* ]]; } \
  && ok "apply_hook_env does not EVAL a hook's value (command substitution stays literal)" \
  || no "apply_hook_env executed a hook-supplied value — root command execution" "$env_out"

# run_enter_hook's failure contract. A hook typically hands the session a PER-SANDBOX daemon
# socket. A session that starts without it falls back to the tool's SHARED default — one daemon,
# in one namespace, writing every sandbox's build outputs into the WRONG clone. So the hook's exit
# code GATES the session: non-zero aborts, whatever the code, whatever the cause.
#
# The old contract tried to tell "could not start" (126/127) from "ran, then failed" and continue
# on the latter. It cannot be done: through `bash -c`, a hook that ends in an exec of a missing
# binary also exits 127, and a privilege drop that fails exits 1 — so the case that most needed
# the abort (the hook never ran, session silently loses everything it guarantees) was the one
# classified as tolerable. These tests pin the single rule that replaced it.
#
# WT_DROP_PRIV= disables the setpriv drop, whose --init-groups needs CAP_SETGID even to drop to
# the ids we already hold — an unprivileged test cannot call it. The real setpriv path needs root.
enter_hook() {  # $1 = WT_HOOK_ENTER; prints "rc=<n> SOCK=<value>"
  WT_DROP_PRIV= bash -c '
    source "$1"
    export WT_HOOK_ENTER="$2"
    set +e; run_enter_hook; rc=$?; set -e
    printf "rc=%s SOCK=%s\n" "$rc" "${CACHE_SOCK:-<unset>}"
  ' _ "$SETUP" "$1" 2>/dev/null
}

# The happy path: a hook that succeeds delivers its env to the session.
out=$(enter_hook 'echo CACHE_SOCK=/tmp/cache-x.sock')
[ "$out" = "rc=0 SOCK=/tmp/cache-x.sock" ] \
  && ok "a successful enter hook delivers its env into the session" \
  || no "successful hook did not deliver env" "$out"

# Ran, printed env, then failed. Non-zero is non-zero: abort. The env it printed must NOT be
# applied — a sandbox set up halfway is the failure this contract exists to prevent.
out=$(enter_hook 'echo CACHE_SOCK=/tmp/cache-x.sock; exit 3')
[ "$out" = "" ] \
  && ok "enter hook that ran-then-failed ABORTS (its partial env is not applied)" \
  || no "ran-then-failed hook did not abort" "$out"

# Could not be executed at all (127).
out=$(enter_hook '/nonexistent/hook enter')
[ "$out" = "" ] \
  && ok "enter hook that does not exist ABORTS (no silent fallback to a shared daemon socket)" \
  || no "missing enter hook was tolerated" "$out"

# Exists but is not executable (126) — a hook that lost its exec bit, or whose interpreter is
# gone. The old 127-only check let this one through silently; it is the same catastrophe.
printf '#!/bin/sh\necho CACHE_SOCK=/tmp/nope.sock\n' > "$TMP/noexec-hook"
chmod -x "$TMP/noexec-hook"
out=$(enter_hook "$TMP/noexec-hook enter")
[ "$out" = "" ] \
  && ok "enter hook that is not executable (126) ABORTS" \
  || no "non-executable enter hook was tolerated" "$out"

# The abort must be a real failure exit, not just empty output — a probe that died for some other
# reason would also print nothing.
WT_DROP_PRIV= bash -c 'source "$1"; export WT_HOOK_ENTER="exit 3"; run_enter_hook' _ "$SETUP" >/dev/null 2>&1
[ $? -ne 0 ] \
  && ok "the abort exits non-zero (wt enter actually fails, not just prints)" \
  || no "run_enter_hook returned success after a failing hook"

# ...and it says why, rather than dying mutely.
msg=$(WT_DROP_PRIV= bash -c 'source "$1"; export WT_HOOK_ENTER="/nonexistent/hook enter"; run_enter_hook' _ "$SETUP" 2>&1)
[[ "$msg" == *"enter hook failed"* ]] \
  && ok "the abort explains itself on stderr" || no "abort message" "$msg"

# A hook's stderr must reach the user: it is where a hook reports why it failed, and the abort
# message above is useless without it.
msg=$(WT_DROP_PRIV= bash -c 'source "$1"; export WT_HOOK_ENTER="echo diagnostic-detail >&2"; run_enter_hook' _ "$SETUP" 2>&1)
[[ "$msg" == *diagnostic-detail* ]] \
  && ok "a hook's stderr reaches the terminal (not swallowed)" || no "hook stderr was swallowed" "$msg"

# No hook configured at all — wt's default — must be a clean no-op, not an error.
setup_case
PATH="$BIN:$PATH" ZFS_STATE="$TMP/zfs" WT_HOME="$TMP/home" WT_CONFIG= \
WT_CANONICAL="$TMP/canonical" WT_DS_SRC=tank/src WT_DS_PARENT=tank/wt WT_HOOK_TEARDOWN= \
  "$WT" gc >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$TMP/zfs/destroyed")" = "tank/wt/orphan" ]; } \
  && ok "no teardown hook configured -> gc still works (hooks are optional)" \
  || no "empty hook broke gc" "rc=$rc"

echo "wt-hooks-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
