#!/usr/bin/env bash
# Unified installer: host-side SSH support ships in the wt executable.
set -uo pipefail

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
INSTALL="$DIR/../install.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL  $1 (got: ${2:-})"; }

mkdir "$T/copy" "$T/link"
out=$(WT_CONFIG= "$INSTALL" "$T/copy" --copy 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -x "$T/copy/wt" ] && [ -x "$T/copy/wt-setup.sh" ]; } \
  && ok "copy install includes host-side SSH support in wt" \
  || no "copy install" "rc=$rc $out"

out=$(WT_CONFIG=/definitely/missing "$T/copy/wt" ssh --help 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"wt ssh [-P PROJECT"* ]]; } \
  && ok "a copied host wt runs SSH commands without local container config" \
  || no "copied host command" "rc=$rc $out"

out=$(WT_CONFIG= "$INSTALL" "$T/link" --symlink 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -L "$T/link/wt" ]; } \
  && ok "default/symlink install exposes one wt executable" || no "symlink install" "rc=$rc $out"

echo "install-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
