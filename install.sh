#!/usr/bin/env bash
# install.sh — put `wt` on PATH for a consuming project.
#
# Two modes, and the difference is not cosmetic:
#
#   symlink (default)  $PREFIX/wt -> this checkout's wt. `wt` resolves its helper as
#                      $SELF_DIR/wt-setup.sh where SELF_DIR is the dir of the REAL file after
#                      readlink -f, so a symlink lands SELF_DIR back in the checkout and the two
#                      scripts stay a matched pair. Edit either one and the next `wt` run has it
#                      — no reinstall, no image rebuild. This is what a devcontainer wants (bake
#                      the symlink into the image; the checkout stays the source of truth).
#
#   copy (--copy)      wt AND wt-setup.sh are copied into $PREFIX. They MUST land in the same
#                      directory for the same SELF_DIR reason — a copied `wt` next to a missing
#                      wt-setup.sh fails at the point of `wt enter`, after a sandbox exists. For
#                      a release/tarball install where no checkout stays behind.
#
# Root is only needed if $PREFIX isn't writable by you; a user-writable prefix (~/.local/bin)
# installs with no privileges at all. Re-running is a no-op when everything is already in place.
#
# Usage:
#   ./install.sh [PREFIX] [--copy|--symlink] [--force]
#     PREFIX        install dir (default $WT_PREFIX, else /usr/local/bin)
#     --copy        copy the scripts instead of symlinking to this checkout
#     --force       replace files this installer did not put there
#
# Not installed: the config. `wt` finds it at $WT_CONFIG, else ~/.config/wt/config, else
# /etc/wt/config — see wt.conf.example. A devcontainer typically maps its in-repo config to
# /etc/wt/config in the image, so the checkout stays the single source of truth.
set -euo pipefail

die() { echo "wt-install: $*" >&2; exit 1; }
log() { echo "wt-install: $*"; }
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

# The checkout we install FROM: this script's own directory, symlinks resolved. wt/wt-setup.sh
# are its neighbours by construction, so nothing here needs to be told where they are.
SRC_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

PREFIX=${WT_PREFIX:-/usr/local/bin}
mode=symlink
force=0
for a in "$@"; do
  case "$a" in
    --copy)     mode=copy ;;
    --symlink)  mode=symlink ;;
    --force)    force=1 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown option '$a' (try --help)" ;;
    *)          PREFIX=$a ;;
  esac
done
PREFIX=${PREFIX%/}
case "$PREFIX" in /*) ;; *) die "install prefix must be an absolute path: $PREFIX" ;; esac

# Installing onto our own checkout is catastrophic, not merely useless: `ln -sfn wt wt` replaces
# the real script with a symlink to itself and the tool is simply gone (in copy mode, `cat src >
# tmp` from a src that IS the dst is no better). Nothing legitimate wants this — the checkout is
# already the thing being installed FROM.
[ "$PREFIX" != "$SRC_DIR" ] \
  || die "prefix is the wt checkout itself ($SRC_DIR) — that would replace wt with a link to itself"

for f in wt wt-setup.sh; do
  [ -f "$SRC_DIR/$f" ] || die "$SRC_DIR/$f is missing — run this from the wt checkout"
done

# Only escalate if we actually have to, and only after the arguments are known good — asking for
# a password to then die on a typo'd flag is rude.
if [ ! -d "$PREFIX" ] || [ ! -w "$PREFIX" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$PREFIX"
  elif command -v sudo >/dev/null 2>&1; then
    log "$PREFIX is not writable by $(id -nu); re-running under sudo"
    # An explicit --preserve-env=<names> list, not -E: sudo-rs (the default sudo on Ubuntu
    # 25.10+) silently ignores -E, which would drop WT_PREFIX and any other WT_* override the
    # caller set for this invocation rather than carry it into the root pass.
    exec sudo --preserve-env="$(compgen -e | paste -sd, -)" "$0" "$@"
  else
    die "$PREFIX is not writable and sudo is unavailable — pass a writable prefix, e.g. ./install.sh ~/.local/bin"
  fi
fi

# Refuse to clobber a stranger's file. A prefix like /usr/local/bin is shared ground and `wt` is a
# short, plausible name. The test is the same either way — does the file it resolves to look like
# one of ours? Both wt and wt-setup.sh mention WT_CANONICAL and unrelated commands generally do
# not, so an older wt upgrades silently while an unrelated `wt` stops us.
#
# Following the symlink is the point. "It's a symlink, so we must have made it" is not an
# argument: stow, nix-profile, asdf and friends all manage their tools as symlinks, and a bare
# -L test would silently replace one of theirs.
ours() {
  local dst=$1
  [ -e "$dst" ] || [ -L "$dst" ] || return 0            # nothing there: fine
  # A symlink that dangles is broken whoever made it — most likely ours, from a checkout that has
  # since moved. Replacing it takes nothing from anyone.
  if [ -L "$dst" ] && [ ! -e "$dst" ]; then return 0; fi
  grep -qs -- 'WT_CANONICAL' "$dst"                     # follows the link, if it is one
}

install_one() {
  local name=$1 tmp
  local src=$SRC_DIR/$name
  local dst=$PREFIX/$name

  if [ "$force" -eq 0 ] && ! ours "$dst"; then
    die "$dst exists and was not installed by wt — move it aside, or re-run with --force"
  fi

  if [ "$mode" = symlink ]; then
    if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
      log "unchanged: $dst -> $src"
      return 0
    fi
    ln -sfn -- "$src" "$dst"        # -n so an existing symlink-to-dir isn't followed into itself
    log "symlinked: $dst -> $src"
  else
    if [ -f "$dst" ] && cmp -s -- "$src" "$dst"; then
      log "unchanged: $dst"
      return 0
    fi
    # Stage + rename rather than write in place: `install`/`cp` truncate the destination inode,
    # and bash reads a script lazily off its fd — overwriting a `wt` that some sandbox is
    # running right now would make it resume mid-file, in garbage. A rename gives the new file a
    # new inode and leaves the running one alone.
    tmp=$(mktemp "$PREFIX/.$name.XXXXXX")
    cat -- "$src" > "$tmp"
    chmod 0755 "$tmp"
    mv -f -- "$tmp" "$dst"
    log "copied   : $src -> $dst"
  fi
}

install_one wt

# In symlink mode SELF_DIR already resolves into the checkout, so wt-setup.sh is found there and
# a second symlink would only put a non-command on everyone's PATH. In copy mode it is mandatory.
if [ "$mode" = copy ]; then
  install_one wt-setup.sh
else
  log "wt-setup.sh: not installed — wt resolves it next to its real path ($SRC_DIR)"
fi

# The most common first failure is a perfectly installed wt with no config: every dataset command
# dies on WT_CANONICAL/WT_DS_SRC/WT_DS_PARENT. Say so now rather than at first use.
found_config=${WT_CONFIG:-}
if [ -z "${WT_CONFIG+x}" ]; then
  for c in "${XDG_CONFIG_HOME:-$HOME/.config}/wt/config" /etc/wt/config; do
    [ -r "$c" ] && { found_config=$c; break; }
  done
fi
if [ -n "$found_config" ]; then
  log "config: $found_config"
else
  log "config: NONE FOUND — container-side sandbox commands need WT_CANONICAL, WT_DS_SRC and WT_DS_PARENT."
  log "        Copy $SRC_DIR/wt.conf.example to ~/.config/wt/config (or /etc/wt/config),"
  log "        or point \$WT_CONFIG at your project's own file. Then run: wt status"
  log "        Host-side 'wt ssh' discovers container config and does not need a local copy."
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) log "warning: $PREFIX is not on your PATH" ;;
esac
