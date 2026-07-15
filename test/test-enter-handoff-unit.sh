#!/usr/bin/env bash
# Fast, hermetic unit test for the enter handoff's environment channel — the sudo invocation
# that carries every WT_* input (and the user's whole session env) into wt-setup.sh.
#
# Why this exists: Ubuntu 25.10+ ships sudo-rs as `sudo`, and sudo-rs IGNORES -E ("preserving
# the entire environment is not supported, '-E' is ignored"). Under it, `sudo -E unshare ...`
# delivers wt-setup.sh an empty WT_* namespace and enter dies at its `: "${WT_CANONICAL:?}"`
# guard. Both sudo.ws and sudo-rs honor an explicit --preserve-env=<names> list, so wt must
# name what it means to keep. These tests pin that argv contract.
set -uo pipefail
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WT="$DIR/../wt"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export ZFS_STATE="$T/zfs"; mkdir -p "$T/bin" "$ZFS_STATE"

DS_SRC="fakepool/src"; DS_PARENT="fakepool/wt"

# zfs stub, minimal: `list` of something unknown FAILS (wt's existence checks stay real
# checks), and snapshot/clone record their target so enter's later `list` of the clone passes.
cat > "$T/bin/zfs" <<'STUB'
#!/usr/bin/env bash
S=$ZFS_STATE; touch "$S/datasets" "$S/snapshots"
sub=$1; shift || true
case "$sub" in
  list)
    t=""
    while [ $# -gt 0 ]; do
      case "$1" in -H) ;; -o|-t|-d) shift ;; *) t=$1 ;; esac; shift
    done
    case "$t" in
      *@*) grep -qxF "$t" "$S/snapshots" && printf '%s\n' "$t" || exit 1 ;;
      *)   grep -qxF "$t" "$S/datasets"  && printf '%s\n' "$t" || exit 1 ;;
    esac ;;
  snapshot) printf '%s\n' "${!#}" >> "$S/snapshots" ;;
  clone)    printf '%s\n' "${!#}" >> "$S/datasets" ;;
esac
exit 0
STUB
chmod +x "$T/bin/zfs"

# sudo stub: record the exact argv, one token per line, and go no further — everything behind
# it needs real root and a real pool, and the contract under test is the argv itself.
export SUDO_ARGV="$T/sudo.argv"
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SUDO_ARGV"
exit 0
STUB
chmod +x "$T/bin/sudo"

# A real git repo: enter resolves main's git dir before the handoff.
CANON="$T/canonical"; mkdir -p "$CANON"
git -C "$CANON" init -q -b main
git -C "$CANON" config user.email t@t; git -C "$CANON" config user.name t
echo hello > "$CANON/file.txt"; git -C "$CANON" add -A; git -C "$CANON" commit -qm first

export WT_HOME="$T/home"
printf '%s\n' "$DS_SRC" "$DS_PARENT" > "$ZFS_STATE/datasets"

# MY_SESSION_VAR stands in for the user's own env (TERM, LANG, sockets). WT_DROP_PRIV is
# exported ON PURPOSE: enter must refuse to carry the privilege-drop test seam across.
wt() {
  env PATH="$T/bin:$PATH" WT_CONFIG= ZFS_STATE="$ZFS_STATE" SUDO_ARGV="$SUDO_ARGV" \
      WT_HOME="$WT_HOME" WT_CANONICAL="$CANON" \
      WT_DS_SRC="$DS_SRC" WT_DS_PARENT="$DS_PARENT" \
      MY_SESSION_VAR=carried WT_DROP_PRIV= \
      bash "$WT" "$@"
}

echo "== scaffold =="
wt new alpha >/dev/null 2>"$T/new.err" \
  && ok "wt new alpha" || no "wt new failed: $(cat "$T/new.err")"
wt enter alpha -- true >/dev/null 2>"$T/enter.err"
[ -s "$SUDO_ARGV" ] \
  && ok "wt enter reached the sudo handoff" \
  || no "wt enter died before sudo: $(cat "$T/enter.err")"

echo "== the handoff must not depend on -E =="
grep -qx -- '-E' "$SUDO_ARGV" \
  && no "wt enter still passes -E (a no-op under sudo-rs: the whole env would be stripped)" \
  || ok "no -E in the sudo argv"

pe=$(grep -m1 -- '^--preserve-env=' "$SUDO_ARGV" || true)
[ -n "$pe" ] \
  && ok "an explicit --preserve-env=<list> is passed" \
  || no "no --preserve-env=<list> in the sudo argv: $(tr '\n' ' ' < "$SUDO_ARGV")"

echo "== the list is complete =="
list=",${pe#--preserve-env=},"
for v in WT_CANONICAL WT_SRC_CLONE WT_META WT_GIT_HOLD WT_GIT_REAL WT_HOLD_DIR \
         WT_TARGET_UID WT_TARGET_GID WT_SANDBOX WT_PATH; do
  case "$list" in
    *,"$v",*) ok "the list names $v" ;;
    *)        no "the list is missing $v — wt-setup.sh would die at its :? guard" ;;
  esac
done

# -E's one virtue was carrying the USER'S env into the session. The explicit list must keep
# doing that, not shrink the channel to the WT_* bundle.
case "$list" in
  *,MY_SESSION_VAR,*) ok "the caller's own exported vars still cross the boundary" ;;
  *) no "the caller's env no longer crosses — sessions would lose TERM, LANG, sockets" ;;
esac

# WT_DROP_PRIV is wt-setup.sh's privilege-drop test seam; enter unsets it precisely so a
# caller's stray export cannot run the sandbox command as root. It must not be in the list.
case "$list" in
  *,WT_DROP_PRIV,*) no "WT_DROP_PRIV crossed the boundary — a caller export would disable the privilege drop" ;;
  *) ok "WT_DROP_PRIV is dropped before the list is built" ;;
esac

echo "== the list is one token =="
next=$(grep -A1 -m1 -- '^--preserve-env=' "$SUDO_ARGV" | tail -1)
[ "$next" = unshare ] \
  && ok "--preserve-env is a single argument, followed by unshare" \
  || no "unexpected token after --preserve-env: '$next'"

echo
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
