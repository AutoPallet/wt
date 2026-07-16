#!/usr/bin/env bash
# Fast, hermetic unit tests for wt-ssh container resolution + verb dispatch (no docker/root needed).
set -uo pipefail
# wt-ssh runs on the HOST, so it cannot read the container's /etc/wt/config: it resolves config as
# env > <repo>/.wt.conf > default, and WT_SSH_CONFIG= (set below) closes the file channel. But
# neither says anything about the ENVIRONMENT, and every `wt enter` exports a WT_* bundle — run
# this suite inside a sandbox and it would quietly feed the code under test that sandbox's real
# config. Scrub the inherited namespace first; everything the tests depend on is set explicitly.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WTSSH="$DIR/../wt-ssh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL  $1 (got: ${2:-})"; }

# Mock docker: two running containers; only c2 mounts $WT_CANONICAL from the target repo
# (with a trailing slash, as docker sometimes records). WT_SSH_DRYRUN stops wt-ssh before the real
# `exec docker exec`, printing the resolved argv instead.
#
# The mock checks the QUERY, not just the container id. resolve() asks docker for the Source of
# the mount whose Destination is $WT_CANONICAL, via a Go --format template; a mock that answers on
# the id alone would return the right container even if that template were nonsense, leaving half
# of the resolution predicate as unexecuted logic wearing a green badge. So: no well-formed
# template, no answer.
ENV="WT_SSH_CONFIG= WT_CANONICAL=/workspaces/myrepo WT_TARGET_USER=dev"
run_wt_ssh() { env $ENV WT_SSH_DRYRUN=1 WT_SSH_REPO=/home/u/myrepo \
  bash -c 'docker(){ case "$1" in
      ps) echo c1; echo c2;;
      inspect)
        case "$*" in
          *.Destination*/workspaces/myrepo*.Source*)
            case "$2" in c1) echo /home/u/other;; c2) echo /home/u/myrepo/;; esac ;;
        esac ;;
    esac; }; export -f docker; exec "$@"' _ "$WTSSH" "$@"; }

out=$(run_wt_ssh proxy scan)
[[ "$out" == *"docker exec -u0 -i c2 /usr/local/bin/wt ssh-serve scan"* ]] \
  && ok "proxy resolves the container whose workspace Source == repo (trailing slash tolerated)" \
  || no "proxy resolver picks c2" "$out"

out=$(run_wt_ssh config)
[[ "$out" == *"docker exec -u dev c2 /usr/local/bin/wt ssh-config /home/u/myrepo $(readlink -f "$WTSSH")"* ]] \
  && ok "config proxies wt ssh-config with the repo path and its own path, as the target user" \
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

# Installed-on-PATH case: wt-ssh's own real path resolves into the wt checkout, which serves no
# project — so with no WT_SSH_REPO it must fall back to the repo the CALLER is standing in and
# read that repo's config. (Regression guard: it used to look for config only in its own repo,
# so an installed wt-ssh could never serve a consuming project.)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/proj/.config"
git -C "$T/proj" init -q 2>/dev/null
printf 'WT_CANONICAL=/workspaces/myrepo\nWT_TARGET_USER=dev\n' > "$T/proj/.config/wt.conf"
out=$(cd "$T/proj" && env WT_SSH_DRYRUN=1 bash -c 'docker(){ case "$1" in
    ps) echo c9;;
    inspect) case "$*" in *.Destination*/workspaces/myrepo*.Source*) echo "'"$T"'/proj";; esac ;;
  esac; }; export -f docker; exec "$@"' _ "$WTSSH" config)
[[ "$out" == *"docker exec -u dev c9 /usr/local/bin/wt ssh-config $T/proj"* ]] \
  && ok "no WT_SSH_REPO -> falls back to the caller's repo and finds its config" \
  || no "cwd-repo fallback" "$out"

# The generated ~/.ssh/config must bake WT_SSH_REPO into every ProxyCommand: ssh runs the
# ProxyCommand from an arbitrary directory, where the cwd fallback above cannot help.
WT="$DIR/../wt"
mkdir -p "$T/home/trees/foo"
out=$(env WT_CONFIG= WT_HOME="$T/home" WT_TARGET_USER=dev bash "$WT" ssh-config /home/u/myrepo)
[[ "$out" == *"ProxyCommand env WT_SSH_REPO=/home/u/myrepo wt-ssh proxy foo"* ]] \
  && ok "wt ssh-config bakes WT_SSH_REPO into the ProxyCommand" \
  || no "ProxyCommand repo baking" "$out"

# When the generating wt-ssh passes its own path (second arg), the ProxyCommand points at it
# absolutely — the ssh transport must not depend on wt-ssh also being on PATH.
out=$(env WT_CONFIG= WT_HOME="$T/home" WT_TARGET_USER=dev bash "$WT" ssh-config /home/u/myrepo /home/u/src/wt/wt-ssh)
[[ "$out" == *"ProxyCommand env WT_SSH_REPO=/home/u/myrepo /home/u/src/wt/wt-ssh proxy foo"* ]] \
  && ok "wt ssh-config prefers the generating wt-ssh's absolute path over a PATH lookup" \
  || no "ProxyCommand caller path" "$out"

# ...unless the project vendors wt-ssh at a checkout-relative WT_SSH_PROXY, which is deliberate
# config and wins over the caller's path.
out=$(env WT_CONFIG= WT_HOME="$T/home" WT_TARGET_USER=dev WT_SSH_PROXY=.devcontainer/wt-ssh \
      bash "$WT" ssh-config /home/u/myrepo /home/u/src/wt/wt-ssh)
[[ "$out" == *"ProxyCommand env WT_SSH_REPO=/home/u/myrepo /home/u/myrepo/.devcontainer/wt-ssh proxy foo"* ]] \
  && ok "a vendored (slash) WT_SSH_PROXY wins over the caller's path" \
  || no "ProxyCommand vendored proxy" "$out"

echo "wt-ssh-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
