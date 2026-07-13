#!/usr/bin/env bash
# Fast, hermetic unit tests for wt-ssh container resolution + verb dispatch (no docker/root needed).
set -uo pipefail
# Hermetic, and this is the sharp edge: wt resolves config as env > file > default. Setting
# WT_CONFIG= keeps an installed /etc/wt/config out, but says nothing about the ENVIRONMENT — and
# every `wt enter` exports a WT_* bundle, so running this suite inside a sandbox would quietly
# feed the code under test that sandbox's real config. It passed for the wrong reason. Scrub the
# inherited namespace first; everything the tests depend on is set explicitly below.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WTSSH="$DIR/../wt-ssh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL  $1 (got: ${2:-})"; }

# Mock docker: two running containers; only c2 mounts $WT_CANONICAL from the target repo
# (with a trailing slash, as docker sometimes records). WT_SSH_DRYRUN stops wt-ssh before the real
# `exec docker exec`, printing the resolved argv instead.
ENV="WT_SSH_CONFIG= WT_CANONICAL=/workspaces/myrepo WT_TARGET_USER=dev"
run_wt_ssh() { env $ENV WT_SSH_DRYRUN=1 WT_SSH_REPO=/home/u/myrepo \
  bash -c 'docker(){ case "$1" in
      ps) echo c1; echo c2;;
      inspect) case "$2" in c1) echo /home/u/other;; c2) echo /home/u/myrepo/;; esac;;
    esac; }; export -f docker; exec "$@"' _ "$WTSSH" "$@"; }

out=$(run_wt_ssh proxy scan)
[[ "$out" == *"docker exec -u0 -i c2 /usr/local/bin/wt ssh-serve scan"* ]] \
  && ok "proxy resolves the container whose workspace Source == repo (trailing slash tolerated)" \
  || no "proxy resolver picks c2" "$out"

out=$(run_wt_ssh config)
[[ "$out" == *"docker exec -u dev c2 /usr/local/bin/wt ssh-config /home/u/myrepo"* ]] \
  && ok "config proxies wt ssh-config with the auto-filled repo path, as the target user" \
  || no "config argv" "$out"

out=$(run_wt_ssh list)
[[ "$out" == *"docker exec -u dev c2 /usr/local/bin/wt list"* ]] \
  && ok "list proxies wt list as the target user" || no "list argv" "$out"

# No verb -> usage on stderr, nonzero exit, without touching docker.
out=$(env $ENV WT_SSH_DRYRUN=1 bash -c 'docker(){ echo SHOULD-NOT-CALL; }; export -f docker; exec "$1"' _ "$WTSSH" 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"usage: wt-ssh"* ]] && [[ "$out" != *"SHOULD-NOT-CALL"* ]]; } \
  && ok "no verb -> usage without touching docker" || no "usage gate" "rc=$rc $out"

# No matching container -> nonzero exit, error mentions the repo.
out=$(env $ENV WT_SSH_DRYRUN=1 WT_SSH_REPO=/nope bash -c 'docker(){ case "$1" in
    ps) echo c1;; inspect) echo /home/u/other;; esac; }; export -f docker; exec "$@"' _ "$WTSSH" proxy scan 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"/nope"* ]]; } \
  && ok "no matching container -> nonzero exit with a clear message" || no "no-match error" "rc=$rc $out"

# WT_SSH_CONTAINER override wins without any docker inspection.
out=$(env $ENV WT_SSH_DRYRUN=1 WT_SSH_CONTAINER=deadbeef WT_SSH_REPO=/whatever \
  bash -c 'docker(){ echo "SHOULD-NOT-CALL"; }; export -f docker; exec "$@"' _ "$WTSSH" proxy scan)
[[ "$out" == *"docker exec -u0 -i deadbeef /usr/local/bin/wt ssh-serve scan"* ]] \
  && ok "WT_SSH_CONTAINER overrides resolution" || no "container override" "$out"

# proxy without a name -> usage on stderr, exit 2, without touching docker.
out=$(env $ENV WT_SSH_DRYRUN=1 bash -c 'docker(){ echo SHOULD-NOT-CALL; }; export -f docker; exec "$@"' _ "$WTSSH" proxy 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && [[ "$out" == *"usage: wt-ssh"* ]] && [[ "$out" != *"SHOULD-NOT-CALL"* ]]; } \
  && ok "proxy without a name -> usage without touching docker" || no "proxy-no-name gate" "rc=$rc $out"

echo "wt-ssh-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
