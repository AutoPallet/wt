#!/usr/bin/env bash
# Fast, hermetic tests for the unified host-side `wt ssh` command and private container helpers.
set -uo pipefail

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WT="$DIR/../wt"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL  $1 (got: ${2:-})"; }

mkdir -p "$T/bin" "$T/home/.ssh" "$T/config" "$T/data" "$T/my repo"
git -C "$T/my repo" init -q
generated="$T/config/wt/ssh_config"
# An existing bottom Include is not good enough: an earlier Host * would win OpenSSH's first-value
# semantics. enable must move its managed Include to the top while preserving unrelated config.
printf 'Host *\n    User root\nInclude "%s"\n\nHost existing\n    User somebody\n' \
  "$generated" > "$T/home/.ssh/config"

# Docker is a real PATH executable rather than an exported function because wt's proxy ends with
# `exec docker ...`. c2 is the only container whose source mount and container-side WT_CANONICAL
# both identify MOCK_REPO. Every call is logged for dispatch assertions.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$MOCK_LOG"; printf '\n' >> "$MOCK_LOG"
case "$1" in
  ps) echo c1; echo c2 ;;
  inspect)
    case "$2" in
      c1) if [ -n "${MOCK_MULTIPLE:-}" ]; then printf '%s\t%s\n' "$MOCK_REPO" "$MOCK_CANONICAL"
          else printf '/somewhere/else\t/workspaces/other\n'; fi ;;
      c2) printf '%s\t%s\n' "$MOCK_REPO" "${MOCK_DESTINATION:-$MOCK_CANONICAL}" ;;
    esac
    ;;
  exec)
    shift
    while [[ "${1:-}" = -* ]]; do
      case "$1" in -u|-e) shift 2 ;; *) shift ;; esac
    done
    cid=${1:-}; shift || true
    bin=${1:-}; shift || true
    cmd=${1:-}; shift || true
    case "$cmd" in
      _ssh-info) printf 'wt:ssh-info\t%s\tdev\t1000\t1000\t/state/wt\t/home/dev/.config/wt/config\n' "$MOCK_CANONICAL" ;;
      _ssh-prepare) IFS= read -r key; [[ "$key" = ssh-* ]] ;;
      _ssh-serve) echo "serve:$cid:${1:-}" ;;
      list) echo 'scan  12K' ;;
      *) echo "unexpected docker exec: $bin $cmd $*" >&2; exit 9 ;;
    esac
    ;;
  *) echo "unexpected docker call: $*" >&2; exit 8 ;;
esac
EOF
chmod +x "$T/bin/docker"

export PATH="$T/bin:$PATH"
export HOME="$T/home"
export XDG_CONFIG_HOME="$T/config"
export XDG_DATA_HOME="$T/data"
export WT_SSH_USER_CONFIG="$T/home/.ssh/config"
export WT_SSH_REMOTE_BIN=/usr/local/bin/wt
export WT_SSH_BIN=/opt/wt/bin/wt
export MOCK_REPO="$T/my repo"
export MOCK_CANONICAL=/workspaces/myrepo
export MOCK_LOG="$T/docker.log"

# Host SSH dispatch must not source a missing container config.
out=$(WT_CONFIG=/definitely/missing "$WT" ssh --help 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"wt ssh [-P PROJECT"* ]]; } \
  && ok "host SSH help bypasses container WT_CONFIG" || no "host config bypass" "rc=$rc $out"

# Discovery starts from the host checkout, derives the destination from Docker's mount, then
# verifies it against the container's own config through _ssh-info.
out=$(cd "$MOCK_REPO" && WT_CONFIG=/definitely/missing "$WT" ssh status 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"checkout      : $MOCK_REPO"* ]] \
    && [[ "$out" == *"container     : c2"* ]] && [[ "$out" == *"canonical     : $MOCK_CANONICAL"* ]]; } \
  && ok "status discovers and verifies the checkout mount without host WT_CANONICAL" \
  || no "mount discovery" "rc=$rc $out"

out=$(cd "$MOCK_REPO" && WT_SSH_CONTAINER=c2 "$WT" ssh status 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"container     : c2"* ]]; } \
  && ok "an explicit container still passes repo/canonical mount verification" \
  || no "verified container override" "rc=$rc $out"

out=$(cd "$MOCK_REPO" && WT_SSH_CONTAINER=c1 "$WT" ssh status 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"does not mount $MOCK_REPO"* ]]; } \
  && ok "a container override cannot select another project's container" \
  || no "wrong-project override" "rc=$rc $out"

export MOCK_DESTINATION=/workspaces/wrong
out=$(cd "$MOCK_REPO" && WT_SSH_CONTAINER=c2 "$WT" ssh status 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"but its WT_CANONICAL is $MOCK_CANONICAL"* ]]; } \
  && ok "a container override cannot bypass canonical-destination verification" \
  || no "wrong-destination override" "rc=$rc $out"
unset MOCK_DESTINATION

# -P is an ssh-family option before the subcommand. Enable creates a registry entry, one wildcard
# stanza, a dedicated key, and a single managed Include without touching unrelated config.
out=$(cd "$MOCK_REPO" && "$WT" ssh -P alpha enable 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$T/config/wt/projects/alpha/repo")" = "$MOCK_REPO" ] \
    && grep -Fq 'Host wt-alpha.*' "$generated" \
    && grep -Fq 'ssh -P alpha proxy %n' "$generated" \
    && [ "$(head -1 "$T/home/.ssh/config")" = '# BEGIN wt managed SSH config' ] \
    && grep -Fq 'Host existing' "$T/home/.ssh/config" \
    && [ -s "$T/data/wt/ssh/id_ed25519" ]; } \
  && ok "enable registers project and installs its managed wildcard config" \
  || no "enable" "rc=$rc $out"

out=$(ssh -G -F "$T/home/.ssh/config" wt-alpha.scan 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"user dev"* ]] \
    && [[ "$out" == *"proxycommand '/opt/wt/bin/wt' ssh -P alpha proxy %n"* ]]; } \
  && ok "OpenSSH accepts the top managed Include and its project wildcard wins Host *" \
  || no "OpenSSH config validation" "rc=$rc $out"

# ProxyCommand is executed by a shell. Its executable path must remain literal even when it
# contains spaces, expansion syntax, backticks, or a single quote.
evil="$T/bin/wt %h \$HOME \$(touch PWNED) \`touch PWNED2\` 'quoted"
ln -s "$WT" "$evil"
export WT_SSH_BIN="$evil"
out=$(cd "$MOCK_REPO" && "$WT" ssh -P alpha enable 2>&1); rc=$?
: > "$MOCK_LOG"
(cd "$T" && ssh -F "$T/home/.ssh/config" wt-alpha.scan </dev/null >/dev/null 2>&1) || true
{ [ "$rc" -eq 0 ] && [ ! -e "$T/PWNED" ] && [ ! -e "$T/PWNED2" ] \
    && grep -Fq '_ssh-serve scan' "$MOCK_LOG"; } \
  && ok "ProxyCommand shell-quotes adversarial executable paths" \
  || no "ProxyCommand path quoting" "rc=$rc $out config=$(cat "$generated")"
export WT_SSH_BIN=/opt/wt/bin/wt

out=$(cd "$MOCK_REPO" && "$WT" ssh -P alpha enable 2>&1); rc=$?
includes=$(grep -Fc "Include \"$generated\"" "$T/home/.ssh/config")
stanzas=$(grep -Fc 'Host wt-alpha.*' "$generated")
{ [ "$rc" -eq 0 ] && [ "$includes" -eq 1 ] && [ "$stanzas" -eq 1 ]; } \
  && ok "enable is idempotent" || no "idempotent enable" "rc=$rc includes=$includes stanzas=$stanzas"

# Registered lookup works outside the checkout, and list is proxied as the container target user.
out=$(cd "$T" && "$WT" ssh -P alpha list 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"scan  12K"* ]]; } \
  && ok "-P selects a registered project outside its checkout" || no "registered list" "rc=$rc $out"

# Direct connect builds an ssh command whose proxy has an explicit project and unambiguous alias.
out=$(cd "$T" && WT_SSH_DRYRUN=1 "$WT" ssh -P alpha connect scan 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"wt-alpha.scan"* ]] \
    && [[ "$out" == *"-P"*alpha*proxy*wt-alpha.scan* ]] && [[ "$out" == *"-l dev"* ]]; } \
  && ok "connect uses explicit project routing and the container target user" \
  || no "connect argv" "rc=$rc $out"

# Proxy validates the literal project prefix, prepares the runtime key, then serves the tree.
: > "$MOCK_LOG"
out=$(cd "$T" && "$WT" ssh -P alpha proxy wt-alpha.scan 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"serve:c2:scan"* ]] \
    && grep -Fq '_ssh-prepare' "$MOCK_LOG" && grep -Fq '_ssh-serve scan' "$MOCK_LOG" \
    && grep -Fq 'WT_CONFIG=/home/dev/.config/wt/config' "$MOCK_LOG" \
    && grep -Fq 'WT_HOME=/state/wt' "$MOCK_LOG" && grep -Fq 'WT_TARGET_UID=1000' "$MOCK_LOG"; } \
  && ok "proxy preserves discovered config and identity across its root helpers" \
  || no "proxy sequence" "rc=$rc $out log=$(cat "$MOCK_LOG")"

out=$(cd "$T" && "$WT" ssh -P alpha proxy wt-alpha-scan 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"does not match project 'alpha'"* ]]; } \
  && ok "proxy rejects ambiguous/nonconforming host aliases" || no "alias validation" "rc=$rc $out"

out=$(cd "$MOCK_REPO" && "$WT" ssh -P beta enable 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"already registered as 'alpha'"* ]]; } \
  && ok "one checkout cannot silently acquire conflicting project registrations" \
  || no "registration collision" "rc=$rc $out"

out=$(cd "$T" && "$WT" ssh -P alpha config --print 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"Host wt-alpha.*"* ]] && [[ "$out" == *"-P alpha proxy %n"* ]]; } \
  && ok "config --print exposes the selected managed project stanza" || no "config print" "rc=$rc $out"

export MOCK_MULTIPLE=1
out=$(cd "$T" && "$WT" ssh -P alpha status 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"multiple running containers match"* ]]; } \
  && ok "ambiguous container discovery names every match and requires an override" \
  || no "multiple containers" "rc=$rc $out"
unset MOCK_MULTIPLE

# A checkout can connect without registration; the direct proxy carries repo and tree separately.
mkdir -p "$T/unregistered"; git -C "$T/unregistered" init -q
export MOCK_REPO="$T/unregistered"
out=$(cd "$MOCK_REPO" && WT_SSH_DRYRUN=1 "$WT" ssh connect demo 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"proxy"*"--repo"*"unregistered"*"--tree"*"demo"* ]]; } \
  && ok "connect needs no registration when run in a checkout" || no "direct unregistered connect" "rc=$rc $out"

# Private info still uses the container config path and emits the line-oriented discovery record.
out=$(WT_CONFIG= WT_CANONICAL=/inside/project WT_HOME=/state/inside WT_TARGET_UID=123 \
  WT_TARGET_GID=456 WT_TARGET_USER=inside "$WT" _ssh-info 2>&1); rc=$?
{ [ "$rc" -eq 0 ] \
    && [ "$out" = $'wt:ssh-info\t/inside/project\tinside\t123\t456\t/state/inside\t-' ]; } \
  && ok "container _ssh-info reports resolved config, state and target identity" \
  || no "_ssh-info" "rc=$rc $out"

# Preparation is root-side, independent of HOME, and writes a complete validated runtime from the
# dedicated host public key. Fake id/sshd make the check hermetic and unprivileged.
cat > "$T/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -u) echo 0 ;; *) exit 0 ;; esac
EOF
cat > "$T/bin/sshd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$T/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MOCK_CHOWN_LOG"
EOF
chmod +x "$T/bin/id" "$T/bin/sshd" "$T/bin/chown"
runtime="$T/container-run"; hostkey="$T/host-key"; printf private > "$hostkey"
pub=$(cat "$T/data/wt/ssh/id_ed25519.pub")
export MOCK_CHOWN_LOG="$T/chown.log"
out=$(printf '%s\n' "$pub" | WT_CONFIG= WT_CANONICAL=/inside/project WT_HOME="$T/container-data" \
  WT_TARGET_UID=1000 WT_TARGET_GID=1000 WT_TARGET_USER=dev WT_SSH_DIR="$runtime" \
  WT_SSH_HOST_KEY="$hostkey" WT_SSH_PRIVSEP_DIR="$T/sshd" WT_REMOTE_BIN=/usr/local/bin/wt \
  "$WT" _ssh-prepare 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$runtime/authorized_keys")" = "$pub" ] \
    && grep -Fq "HostKey $hostkey" "$runtime/sshd_config" \
    && grep -Fq 'ForceCommand /usr/local/bin/wt _ssh-forced' "$runtime/sshd_config" \
    && [ "$(cat "$MOCK_CHOWN_LOG")" = "1000:1000 $runtime/authorized_keys" ]; } \
  && ok "container _ssh-prepare recreates and validates root-side runtime state" \
  || no "_ssh-prepare" "rc=$rc $out"

out=$(cd "$T" && "$WT" ssh -P alpha disable 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ ! -e "$T/config/wt/projects/alpha" ] \
    && ! grep -Fq 'Host wt-alpha.*' "$generated" && grep -Fq 'Host existing' "$T/home/.ssh/config"; } \
  && ok "disable removes only the project registration and generated stanza" \
  || no "disable" "rc=$rc $out"

mv "$T/home/.ssh/config" "$T/home/.ssh/config.real"
ln -s config.real "$T/home/.ssh/config"
export MOCK_REPO="$T/my repo"
out=$(cd "$MOCK_REPO" && "$WT" ssh -P alpha enable 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"is a symlink"* ]] \
    && [ ! -e "$T/config/wt/projects/alpha" ]; } \
  && ok "enable preflights SSH config before writing project state" \
  || no "enable preflight" "rc=$rc $out"

echo "ssh-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
