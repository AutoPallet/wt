#!/usr/bin/env bash
# Fast, hermetic unit tests for config resolution (env > file > default) and for the two
# derivations that `wt` and `wt-setup.sh` each compute independently.
#
# This is the suite that should have existed already. Every other suite sets WT_CONFIG= to shut
# the config FILE out — which is correct hermeticity, and which also means the config-resolution
# code is dead in every test run. It resolves env > file > default, and nothing anywhere asserted
# that. Invert the precedence and all four other suites stay green: an operator's WT_DS_PARENT
# override would be silently ignored in favour of the file, and gc and rm would then be pointed at
# the wrong parent dataset. It is also the exact subsystem whose last bug shipped.
set -uo pipefail
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WT="$DIR/../wt"
SETUP="$DIR/../wt-setup.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

cat > "$T/config" <<'EOF'
WT_CANONICAL=/from/file
WT_DS_SRC=pool/from-file
WT_DS_PARENT=pool/from-file-wt
WT_ZFS_PROP=com.file:managed
EOF

# `wt status` prints the resolved config and touches no datasets, so it is the honest probe.
status() { env -i PATH="$PATH" HOME="$T" "$@" bash "$WT" status 2>/dev/null; }

echo "== precedence: environment > file > default =="
out=$(status WT_CONFIG="$T/config")
grep -q 'src dataset   : pool/from-file' <<<"$out" \
  && ok "with no env override, the file supplies the value" \
  || no "file value not used: $(grep 'src dataset' <<<"$out")"

# The load-bearing one. The file is SOURCED, so without the export-snapshot/restore around it the
# file's assignment would simply overwrite the caller's.
out=$(status WT_CONFIG="$T/config" WT_DS_SRC=pool/from-env)
grep -q 'src dataset   : pool/from-env' <<<"$out" \
  && ok "the ENVIRONMENT overrides the file (a one-off override actually takes effect)" \
  || no "the file overrode the environment — precedence is inverted: $(grep 'src dataset' <<<"$out")"

# ...for every WT_* the file sets, not just the one we happened to check.
out=$(status WT_CONFIG="$T/config" WT_ZFS_PROP=com.env:managed WT_CANONICAL=/from/env)
{ grep -q 'zfs property  : com.env:managed' <<<"$out" && grep -q 'canonical     : /from/env' <<<"$out"; } \
  && ok "the override applies to every WT_* the file sets, not one special-cased name" \
  || no "some overrides were lost: $(grep -E 'zfs property|canonical' <<<"$out" | tr '\n' ' ')"

# WT_CONFIG= (explicitly empty) must skip the file entirely — this is the seam every other suite
# leans on, so if it ever stopped working, they would start reading a real /etc/wt/config.
out=$(status WT_CONFIG= WT_DS_SRC=pool/only-env)
{ grep -q 'src dataset   : pool/only-env' <<<"$out" && ! grep -q 'from-file' <<<"$out"; } \
  && ok "WT_CONFIG= skips the config file entirely (the hermetic seam the suites rely on)" \
  || no "WT_CONFIG= did not skip the file: $out"

out=$(status WT_CONFIG=/nonexistent/config)
[ -z "$out" ] && ok "a WT_CONFIG naming a file that isn't there fails, rather than silently defaulting" \
  || no "an unreadable WT_CONFIG was ignored: $out"

# The built-in default, when neither env nor file has an opinion.
out=$(status WT_CONFIG=)
grep -q 'zfs property  : com.wt:managed' <<<"$out" \
  && ok "falls back to the built-in default when neither env nor file sets it" \
  || no "default WT_ZFS_PROP wrong: $(grep 'zfs property' <<<"$out")"

echo "== defaults: WT_DS_SRC and WT_DS_PARENT derive from the mount table when unset =="
# Stub findmnt so the derivation runs without a real ZFS mount. wt calls it as
# `findmnt -no SOURCE,FSTYPE -T <path>` — key by path so WT_CANONICAL and WT_HOME resolve
# to different datasets, and by fstype so a non-ZFS mount is filtered out.
mkdir -p "$T/bin"
cat > "$T/bin/findmnt" <<'EOF'
#!/bin/bash
path=${!#}
case "$path" in
  /derived/canonical) echo 'pool/derived-src zfs' ;;
  /derived/home)      echo 'pool/derived-parent zfs' ;;
  /nonzfs/*)          echo '/dev/sda1 ext4' ;;
esac
EOF
chmod +x "$T/bin/findmnt"
stub_status() { env -i PATH="$T/bin:$PATH" HOME="$T" "$@" bash "$WT" status 2>/dev/null; }

out=$(stub_status WT_CONFIG= WT_CANONICAL=/derived/canonical WT_HOME=/derived/home)
{ grep -q 'src dataset   : pool/derived-src' <<<"$out" \
    && grep -q 'wt dataset    : pool/derived-parent' <<<"$out"; } \
  && ok "WT_DS_SRC / WT_DS_PARENT default to the ZFS dataset WT_CANONICAL / WT_HOME is mounted from" \
  || no "derivation failed: $(grep -E 'src dataset|wt dataset' <<<"$out" | tr '\n' ' ')"

# A non-ZFS mount is filtered out — otherwise a plain-directory checkout would be handed to
# `zfs clone` with whatever /dev block it happens to sit on.
out=$(stub_status WT_CONFIG= WT_CANONICAL=/nonzfs/checkout WT_HOME=/nonzfs/home)
{ grep -q 'src dataset   : UNSET' <<<"$out" \
    && grep -q 'wt dataset    : UNSET' <<<"$out"; } \
  && ok "a non-ZFS mount is filtered out (require_config would then die as it does today)" \
  || no "a non-ZFS mount was accepted as a dataset: $(grep -E 'src dataset|wt dataset' <<<"$out")"

# Precedence must extend to the derived defaults: env > file > derivation. An explicit override
# must not be silently replaced by whatever findmnt returns.
out=$(stub_status WT_CONFIG= WT_CANONICAL=/derived/canonical WT_HOME=/derived/home \
                  WT_DS_SRC=pool/env-src WT_DS_PARENT=pool/env-parent)
{ grep -q 'src dataset   : pool/env-src' <<<"$out" \
    && grep -q 'wt dataset    : pool/env-parent' <<<"$out"; } \
  && ok "an explicit env value wins over the derivation" \
  || no "derivation overrode an explicit env value: $(grep -E 'src dataset|wt dataset' <<<"$out")"

cat > "$T/config-derive" <<'EOF'
WT_CANONICAL=/derived/canonical
WT_HOME=/derived/home
WT_DS_SRC=pool/file-src
WT_DS_PARENT=pool/file-parent
EOF
out=$(stub_status WT_CONFIG="$T/config-derive")
{ grep -q 'src dataset   : pool/file-src' <<<"$out" \
    && grep -q 'wt dataset    : pool/file-parent' <<<"$out"; } \
  && ok "an explicit file value wins over the derivation" \
  || no "derivation overrode an explicit file value: $(grep -E 'src dataset|wt dataset' <<<"$out")"

echo "== exclude_key: injective, and identical on both sides of the sudo boundary =="
# wt and wt-setup.sh each derive this independently — wt to CREATE the hold dir, wt-setup.sh to
# BIND it — on opposite sides of `sudo`. If they ever disagree, a sandbox binds the wrong live
# directory over an excluded subpath, or fails to bind it at all.
key_wt()    { bash -c 'source "$1" >/dev/null 2>&1; exclude_key "$2"' _ "$WT" "$1"; }
key_setup() { bash -c 'source "$1" >/dev/null 2>&1; exclude_key "$2"' _ "$SETUP" "$1"; }

drift=0
for s in logs build/logs build_logs a/b/c a_b_c "we_ird/pa_th" plain; do
  a=$(key_wt "$s"); b=$(key_setup "$s")
  [ "$a" = "$b" ] || { drift=1; echo "      drift on '$s': wt=[$a] wt-setup=[$b]"; }
done
[ "$drift" -eq 0 ] \
  && ok "wt and wt-setup.sh derive the identical hold-path key" \
  || no "the two derivations have drifted apart"

# Injectivity. Escaping only '/' is NOT enough: a real directory named "build_Slogs" would then
# collide with the subpath "build/logs", and wt-setup.sh would bind one of them over BOTH — so
# writes meant for one shared directory would land in the other, silently.
declare -A seen; collide=""
for s in logs build/logs build_logs build_Slogs a/b a_b "x_Uy" "x/y"; do
  k=$(key_wt "$s")
  [ -n "${seen[$k]:-}" ] && collide="'$s' and '${seen[$k]}' both -> $k"
  seen[$k]=$s
done
[ -z "$collide" ] \
  && ok "distinct subpaths always produce distinct keys (the encoding is injective)" \
  || no "COLLISION: $collide"

echo
echo "wt-config-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
