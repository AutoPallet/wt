#!/usr/bin/env bash
# Fast, hermetic unit tests for wt's snapshot provenance filter (no ZFS/root/docker needed).
#
# `wt gc` destroys snapshots. The ONLY thing standing between it and someone's hand-made
# @wt-backup snapshot is the ZFS user property wt stamps on the ones it created ($WT_ZFS_PROP):
# a name glob alone cannot prove provenance. These tests drive the REAL `wt gc` / `wt list`
# end-to-end with `zfs` stubbed first on PATH, so the filter is exercised for real.
#
# Nothing here can touch real state: zfs is a stub, every path is overridden, WT_CONFIG= skips
# any installed config file, and WT_HOOK_TEARDOWN= disarms the teardown hook.
set -uo pipefail
# Hermetic, and this is the sharp edge: wt resolves config as env > file > default. Setting
# WT_CONFIG= keeps an installed /etc/wt/config out, but says nothing about the ENVIRONMENT — and
# every `wt enter` exports a WT_* bundle, so running this suite inside a sandbox would quietly
# feed the code under test that sandbox's real config. It passed for the wrong reason. Scrub the
# inherited namespace first; everything the tests depend on is set explicitly below.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WT="$DIR/../wt"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/trees" "$T/home/active"

DS_SRC="fakepool/src"
DS_PARENT="fakepool/wt"
PROP="com.example:managed"                      # exercise it as configurable, not a constant
SNAP_TAGGED="$DS_SRC@wt-alpha-20260101-000000"  # wt-created orphan ($PROP=1)
SNAP_UNTAGGED="$DS_SRC@wt-beta-20260101-000000" # matches the @wt-* glob but is NOT wt's
SNAP_FOREIGN="$DS_SRC@manual-backup"            # not even @wt-*; excluded by the name glob
DESTROY_LOG="$T/destroy.log"; : > "$DESTROY_LOG"

# Fake zfs. Reads only its own args. Answers exactly the queries gc/list make:
#   list -t snapshot <ds>  -> the canned snapshot set
#   list -r <ds>           -> the parent line only, so `| tail -n +2` yields no orphan clones
#   get -H -o value <prop> <snap> -> 1 for the tagged snapshot under $PROP, else '-'
#   destroy <thing>        -> record it and succeed
cat > "$T/bin/zfs" <<EOF
#!/usr/bin/env bash
sub=\$1; shift || true
last() { local a; for a in "\$@"; do :; done; printf '%s' "\${a:-}"; }
case "\$sub" in
  list)
    if printf '%s\n' "\$@" | grep -q -- '-t'; then
      ds=\$(last "\$@")
      printf '%s\n' "\$ds@wt-alpha-20260101-000000" "\$ds@wt-beta-20260101-000000" "\$ds@manual-backup"
    else
      printf '%s\n' "\$(last "\$@")"
    fi
    ;;
  get)
    prop=""; target=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -H) ;;
        -o) shift ;;
        *) if [ -z "\$prop" ]; then prop=\$1; else target=\$1; fi ;;
      esac
      shift
    done
    case "\$prop" in
      "$PROP") case "\$target" in *@wt-alpha-*) echo 1 ;; *) echo - ;; esac ;;
      *) echo - ;;
    esac
    ;;
  destroy) printf '%s\n' "\$*" >> "$DESTROY_LOG" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$T/bin/zfs"

wt() {
  env PATH="$T/bin:$PATH" WT_CONFIG= WT_HOOK_TEARDOWN= \
      WT_HOME="$T/home" WT_CANONICAL="$T/canonical" \
      WT_DS_SRC="$DS_SRC" WT_DS_PARENT="$DS_PARENT" WT_ZFS_PROP="$PROP" \
      bash "$WT" "$@"
}

resolved=$(env PATH="$T/bin:$PATH" bash -c 'command -v zfs')
[ "$resolved" = "$T/bin/zfs" ] && ok "the fake zfs is first on PATH" || no "zfs resolved to $resolved"

echo "== wt gc reaps only what wt created =="
wt gc >"$T/gc.out" 2>"$T/gc.err"
grep -qF "$SNAP_TAGGED" "$DESTROY_LOG" \
  && ok "destroys the tagged orphan" || no "did NOT destroy the tagged orphan"
grep -qF "$SNAP_UNTAGGED" "$DESTROY_LOG" \
  && no "destroyed an UNTAGGED @wt-* snapshot — the provenance filter failed" \
  || ok "spares an untagged @wt-* snapshot (name glob alone is not provenance)"
grep -qF "$SNAP_FOREIGN" "$DESTROY_LOG" \
  && no "destroyed a non-wt snapshot" || ok "spares a non-wt snapshot"
grep -qF "skipping untagged snapshot $SNAP_UNTAGGED" "$T/gc.err" \
  && ok "says out loud that it skipped the untagged snapshot" \
  || no "skipped the untagged snapshot silently"

echo "== wt list separates what gc will reap from what it won't =="
wt list >"$T/list.out" 2>"$T/list.err"
reclaim=$(awk "/orphan snapshots \(run 'wt gc' to reclaim\):/,/untagged @wt-\* snapshots/" "$T/list.out")
manual=$(awk '/untagged @wt-\* snapshots/,0' "$T/list.out")

printf '%s' "$reclaim" | grep -qF "$SNAP_TAGGED" \
  && ok "tagged orphan is listed under 'reclaim'" || no "tagged orphan missing from 'reclaim'"
printf '%s' "$reclaim" | grep -qF "$SNAP_UNTAGGED" \
  && no "untagged snapshot leaked into the 'reclaim' section" \
  || ok "untagged snapshot stays out of 'reclaim'"
printf '%s' "$manual" | grep -qF "$SNAP_UNTAGGED" \
  && ok "untagged snapshot is surfaced under 'reap by hand' (not silently ignored)" \
  || no "untagged snapshot missing from 'reap by hand'"
printf '%s' "$manual" | grep -qF "$SNAP_TAGGED" \
  && no "tagged orphan leaked into the 'reap by hand' section" \
  || ok "tagged orphan stays out of 'reap by hand'"

echo
echo "wt-gc-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
