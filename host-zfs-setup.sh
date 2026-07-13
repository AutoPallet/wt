#!/usr/bin/env bash
# host-zfs-setup.sh — one-time HOST-side provisioning for `wt` ZFS-clone sandboxes. Run it on
# the host (NOT inside the container), as the human who owns the checkout; it re-execs itself
# under sudo for the parts that need root.
#
# It builds exactly what `wt` expects to already be there, and nothing else:
#   $WT_DS_SRC          the dataset holding the checkout. If the checkout is currently a plain
#                       directory, its contents are migrated INTO the new dataset, in place.
#   $WT_DS_SRC/<sub>    one child dataset per WT_SNAPSHOT_EXCLUDE entry. `wt new` snapshots
#                       $WT_DS_SRC NON-recursively, so being a child dataset is the whole
#                       mechanism by which a subpath stays out of every snapshot — and hence
#                       out of every clone. wt-setup.sh then bind-mounts the canonical copy
#                       back into each sandbox, so all sandboxes share one live copy.
#   $WT_DS_PARENT       the dataset the per-sandbox clones hang under. Its mountpoint is also
#                       where wt's state dir ($WT_HOME, as the container sees it) should live.
#   zfs allow           snapshot/clone/destroy/mount/... delegated to the uid the sandboxes run
#                       as, so `wt` never needs root for dataset work.
#
# Config is read the way `wt` reads it: $WT_CONFIG, else ~/.config/wt/config, else
# /etc/wt/config, with the environment overriding the file. Two host-side wrinkles:
#
#   * A devcontainer install typically keeps its config INSIDE the checkout and only maps it to
#     /etc/wt/config in the image — the host has no such file, so point WT_CONFIG at the real
#     one:   WT_CONFIG=.config/wt.conf ./host-zfs-setup.sh ~/src/myrepo
#   * WT_CANONICAL is the checkout path as the CONTAINER sees it (/workspaces/myrepo). The
#     dataset must be mounted where the HOST sees the checkout (~/src/myrepo). When those
#     differ — they usually do — pass the host path as the first argument.
#
# Safe to re-run: every step is skipped if its dataset already exists. The migration never
# deletes anything; the pre-migration checkout is left at <checkout>.aside and the script prints
# the command to reclaim it once you are satisfied.
#
# Usage: host-zfs-setup.sh [CHECKOUT_DIR [WT_DIR]] [-y]
#   CHECKOUT_DIR   host mountpoint for $WT_DS_SRC       (default: $WT_CANONICAL from config)
#   WT_DIR         host mountpoint for $WT_DS_PARENT    (default: <CHECKOUT_DIR>-wt)
#   -y, --yes      don't prompt before migrating a plain-directory checkout into a dataset
set -euo pipefail

die() { echo "host-zfs-setup: $*" >&2; exit 1; }
log() { echo "host-zfs-setup: $*" >&2; }
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

# Root is needed for zfs create/mount, chown, and the `sudo -u` delegation probe. -E so a WT_*
# override (WT_CONFIG above all) set by the caller survives into the root pass; if sudoers
# forbids -E the config search below still finds the same file, it just cannot be overridden.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

assume_yes=0
args=()
for a in "$@"; do
  case "$a" in
    -y|--yes)          assume_yes=1 ;;
    -h|--help)         usage; exit 0 ;;
    -*)                die "unknown option '$a' (try --help)" ;;
    *)                 args+=("$a") ;;
  esac
done

# ---- config -------------------------------------------------------------------------------
# The invoking human, not root: we are past the sudo re-exec, so $HOME is root's and would send
# the config search to /root/.config. Their uid is also the only sane fallback for the identity
# the sandboxes run as (wt's own `id -u` default would resolve to 0 here — useless).
ORIG_USER=${SUDO_USER:-$(id -nu)}
ORIG_HOME=$(getent passwd "$ORIG_USER" | cut -d: -f6)
[ -n "$ORIG_HOME" ] || die "could not determine the home directory of '$ORIG_USER'"

# Precedence and search order are `wt`'s, idiom for idiom (see its config block) so the two
# cannot drift: environment > config file > built-in default, and WT_CONFIG= (empty) skips the
# file. The one deliberate difference is ~ meaning $ORIG_HOME, per above.
_wt_env=$(export -p | grep -E '^declare -x WT_[A-Za-z0-9_]+=' || true)
if [ -z "${WT_CONFIG+x}" ]; then
  for _c in "${XDG_CONFIG_HOME:-$ORIG_HOME/.config}/wt/config" /etc/wt/config; do
    [ -r "$_c" ] && { WT_CONFIG=$_c; break; }
  done
fi
if [ -n "${WT_CONFIG:-}" ]; then
  [ -r "$WT_CONFIG" ] || die "config file not readable: $WT_CONFIG"
  # shellcheck source=/dev/null
  . "$WT_CONFIG"
  eval "$_wt_env"        # environment wins over the file
fi

WT_CANONICAL=${WT_CANONICAL:-}
WT_DS_SRC=${WT_DS_SRC:-}
WT_DS_PARENT=${WT_DS_PARENT:-}
WT_SNAPSHOT_EXCLUDE=${WT_SNAPSHOT_EXCLUDE:-}
WT_ZFS_PROP=${WT_ZFS_PROP:-com.wt:managed}
WT_TARGET_UID=${WT_TARGET_UID:-$(id -u "$ORIG_USER")}
WT_TARGET_GID=${WT_TARGET_GID:-$(id -g "$ORIG_USER")}
WT_TARGET_USER=${WT_TARGET_USER:-}

[ -n "$WT_DS_SRC" ]    || die "WT_DS_SRC is not set (config: ${WT_CONFIG:-none found}) — see wt.conf.example"
[ -n "$WT_DS_PARENT" ] || die "WT_DS_PARENT is not set (config: ${WT_CONFIG:-none found}) — see wt.conf.example"

# A bare pool name has no parent to create it under, and `zfs create` cannot make one.
case "$WT_DS_SRC"    in */*) ;; *) die "WT_DS_SRC='$WT_DS_SRC' names a pool, not a dataset" ;; esac
case "$WT_DS_PARENT" in */*) ;; *) die "WT_DS_PARENT='$WT_DS_PARENT' names a pool, not a dataset" ;; esac
# `wt gc` destroys every child of $WT_DS_PARENT. Pointed inside the source dataset it would
# reach the WT_SNAPSHOT_EXCLUDE children — the live, never-snapshotted data every sandbox shares.
case "$WT_DS_PARENT" in
  "$WT_DS_SRC"|"$WT_DS_SRC"/*) die "WT_DS_PARENT must not be, or live under, WT_DS_SRC ($WT_DS_SRC)" ;;
esac

CHECKOUT_DIR=${args[0]:-$WT_CANONICAL}
[ -n "$CHECKOUT_DIR" ] \
  || die "no checkout path: pass one as the first argument, or set WT_CANONICAL (config: ${WT_CONFIG:-none found})"
case "$CHECKOUT_DIR" in /*) ;; *) die "checkout path must be absolute: $CHECKOUT_DIR" ;; esac
CHECKOUT_DIR=${CHECKOUT_DIR%/}
WT_DIR=${args[1]:-${CHECKOUT_DIR}-wt}
ASIDE_DIR=$CHECKOUT_DIR.aside

# ---- identity to delegate to --------------------------------------------------------------
# ZFS delegation is stored by uid, and the container bind-mount preserves uids — so the account
# that must hold the permissions is whichever HOST account has WT_TARGET_UID, whatever the
# container happens to call it (WT_TARGET_USER is a name inside the container; the host account
# with the same uid may well be named differently, or not exist at all).
#
# If the configured name DOES exist on the host but under a different uid, stop: delegating to
# it would hand the permissions to an identity no sandbox ever runs as, and every `wt new` would
# then fail with a permission error nobody can explain. This is the generic form of the old
# "host user must be uid 1000, or the delegation would not apply" assertion.
[ "$WT_TARGET_UID" != 0 ] \
  || die "WT_TARGET_UID resolved to 0 — sandboxes must not run as root; set WT_TARGET_UID in the config"
if [ -n "$WT_TARGET_USER" ] && getent passwd "$WT_TARGET_USER" >/dev/null 2>&1; then
  _u=$(id -u "$WT_TARGET_USER")
  [ "$_u" = "$WT_TARGET_UID" ] \
    || die "host user '$WT_TARGET_USER' is uid $_u but WT_TARGET_UID=$WT_TARGET_UID — the delegation would land on the wrong identity"
fi
HOST_USER=$(getent passwd "$WT_TARGET_UID" | cut -d: -f1 || true)
# `zfs allow -u` accepts a bare uid, which is what an unmapped container-only uid needs.
DELEGATE=${HOST_USER:-$WT_TARGET_UID}

# ---- sanity -------------------------------------------------------------------------------
command -v zfs >/dev/null 2>&1 || die "zfs CLI not found on this host"
[ -c /dev/zfs ] || die "/dev/zfs missing — is the ZFS kmod loaded?"
_parent_of_src=${WT_DS_SRC%/*}
zfs list -H -o name "$_parent_of_src" >/dev/null 2>&1 \
  || die "$_parent_of_src does not exist — create the parent dataset before pointing WT_DS_SRC under it"
_parent_of_wt=${WT_DS_PARENT%/*}
zfs list -H -o name "$_parent_of_wt" >/dev/null 2>&1 \
  || die "$_parent_of_wt does not exist — create the parent dataset before pointing WT_DS_PARENT under it"

log "config        : ${WT_CONFIG:-none found (env only)}"
log "checkout      : $CHECKOUT_DIR   (host view; container sees it as ${WT_CANONICAL:-<unset>})"
log "src dataset   : $WT_DS_SRC"
log "wt dataset    : $WT_DS_PARENT   (mounted at $WT_DIR)"
log "never snapshot: ${WT_SNAPSHOT_EXCLUDE:-<none>}"
log "delegate to   : $DELEGATE (uid $WT_TARGET_UID, gid $WT_TARGET_GID)"

# ---- helpers ------------------------------------------------------------------------------
confirm() {
  [ "$assume_yes" -eq 1 ] && return 0
  # Non-interactive callers must say so explicitly: this moves someone's working checkout.
  [ -t 0 ] || die "$1 — refusing to do that non-interactively; re-run with -y if it is what you want"
  local a
  read -r -p "host-zfs-setup: $1 [y/N] " a || true
  case "$a" in y|Y|yes|YES) return 0 ;; *) die "aborted" ;; esac
}

# The dataset mounted EXACTLY at $1, or nothing. `zfs list <path>` happily resolves any path on
# a ZFS filesystem to its *containing* dataset, so its bare output cannot answer "is this path a
# mountpoint?" — every directory inside the checkout would answer yes.
mount_owner_of() {
  local dir=$1 ds mp
  ds=$(zfs list -H -o name "$dir" 2>/dev/null || true)
  [ -n "$ds" ] || return 0
  mp=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null || true)
  [ "$mp" = "$dir" ] && printf '%s' "$ds"
  return 0
}

# Turn an existing plain directory into the mountpoint of a NEW dataset without losing what is
# in it: stage the content in a sibling temp dir (same filesystem, so that first move is a
# rename, not a copy), create the dataset over the now-empty path, move the content back in.
# Idempotent — an existing dataset is left exactly as it is.
promote_dir_to_dataset() {
  local dir=$1 ds=$2; shift 2
  if zfs list -H -o name "$ds" >/dev/null 2>&1; then
    log "$ds already exists; skipping create"
    return 0
  fi
  # Some OTHER dataset already owns this path — moving its contents around would be vandalism.
  local owner
  owner=$(mount_owner_of "$dir")
  if [ -n "$owner" ]; then
    die "$dir is already the mountpoint of $owner; refusing to promote it to $ds"
  fi

  local staged=""
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    staged=$(mktemp -d "$dir.aside.XXXXXX")
    log "$dir has content; staging it in $staged while $ds is created"
    # dotglob, because .git/.cargo/... must come along; the classic `.??*` glob also silently
    # misses two-character dotfiles.
    ( shopt -s dotglob; mv -- "$dir"/* "$staged"/ )
    [ -z "$(ls -A "$dir" 2>/dev/null)" ] || die "could not empty $dir (its content is in $staged)"
  fi
  if [ -d "$dir" ]; then
    rmdir "$dir" || die "could not rmdir $dir (still has content?)"
  fi

  zfs create "$@" -o mountpoint="$dir" "$ds"
  chown "$WT_TARGET_UID:$WT_TARGET_GID" "$dir"
  if [ -n "$staged" ]; then
    ( shopt -s dotglob; mv -- "$staged"/* "$dir"/ )
    rmdir "$staged" 2>/dev/null || log "warning: $staged is not empty after the restore — check it by hand"
  fi
  log "created $ds mounted at $dir"
}

# Each WT_SNAPSHOT_EXCLUDE entry becomes $WT_DS_SRC/<sub>, mounted at <checkout>/<sub>.
create_exclude_dataset() {
  local sub=$1 ds parent_ds
  case "$sub" in
    /*|*/|*//*|*..*) die "WT_SNAPSHOT_EXCLUDE entry '$sub' must be a plain relative subpath (no leading/trailing slash, no ..)" ;;
  esac
  ds=$WT_DS_SRC/$sub
  parent_ds=${ds%/*}
  # A nested entry ("build/logs") needs $WT_DS_SRC/build to be a dataset too — and that is
  # almost never what the author meant: `wt new` snapshots $WT_DS_SRC non-recursively, so
  # EVERYTHING under build/ (not just build/logs) would then be absent from every sandbox.
  # Refuse rather than create the intermediate silently; `zfs create -p` here would be a data
  # disappearance bug wearing a convenience flag.
  if [ "$parent_ds" != "$WT_DS_SRC" ] && ! zfs list -H -o name "$parent_ds" >/dev/null 2>&1; then
    die "WT_SNAPSHOT_EXCLUDE entry '$sub' needs the intermediate dataset $parent_ds, which does not exist.
    Creating it would make $CHECKOUT_DIR/${parent_ds#"$WT_DS_SRC"/} a dataset of its own, and then
    everything under it — not just $sub — would vanish from every sandbox. Exclude the top-level
    directory instead, or create $parent_ds yourself if that really is what you want."
  fi
  promote_dir_to_dataset "$CHECKOUT_DIR/$sub" "$ds"
}

# Cheap post-copy proof that nothing was dropped. Exact for a subtree we copied whole.
verify_identical() {
  local src=$1 dst=$2 src_n dst_n src_b dst_b
  src_n=$(find "$src" -mindepth 1 | wc -l); dst_n=$(find "$dst" -mindepth 1 | wc -l)
  src_b=$(du -sb "$src" | cut -f1);         dst_b=$(du -sb "$dst" | cut -f1)
  log "  verify $src: src files=$src_n bytes=$src_b ; dst files=$dst_n bytes=$dst_b"
  if [ "$src_n" != "$dst_n" ] || [ "$src_b" != "$dst_b" ]; then
    die "copy verify FAILED for $src (file count or size differs); nothing was deleted — the original is intact at $ASIDE_DIR"
  fi
}

# ---- refuse to provision under live sandboxes ---------------------------------------------
# Clones under $WT_DS_PARENT descend from a snapshot of $WT_DS_SRC. If they exist while the
# source dataset does not, they came from some other origin (a previous layout), and creating
# the source under them would leave two incompatible generations of sandboxes side by side.
if ! zfs list -H -o name "$WT_DS_SRC" >/dev/null 2>&1 \
   && zfs list -H -o name "$WT_DS_PARENT" >/dev/null 2>&1; then
  existing=$(zfs list -H -o name -r "$WT_DS_PARENT" 2>/dev/null | tail -n +2 | grep -v '@' || true)
  if [ -n "$existing" ]; then
    log "existing sandbox clones under $WT_DS_PARENT, but $WT_DS_SRC does not exist:"
    printf '%s\n' "$existing" | sed 's/^/  /' >&2
    die "'wt rm' each of them (inside the container) before provisioning the source dataset"
  fi
fi

# ---- 1. the source dataset ----------------------------------------------------------------
migrated=0
if zfs list -H -o name "$WT_DS_SRC" >/dev/null 2>&1; then
  mp=$(zfs get -H -o value mountpoint "$WT_DS_SRC" 2>/dev/null || true)
  [ "$mp" = "$CHECKOUT_DIR" ] \
    || log "warning: $WT_DS_SRC is mounted at '$mp', not $CHECKOUT_DIR — wt clones whatever is at the mountpoint"
  log "$WT_DS_SRC already exists; skipping checkout migration"
elif [ ! -e "$CHECKOUT_DIR" ]; then
  # Nothing to preserve: hand back an empty dataset and let them clone the repo into it.
  log "creating $WT_DS_SRC at $CHECKOUT_DIR (nothing there yet — clone your repo into it afterwards)"
  zfs create -o mountpoint="$CHECKOUT_DIR" -o xattr=sa -o acltype=posixacl "$WT_DS_SRC"
  chown "$WT_TARGET_UID:$WT_TARGET_GID" "$CHECKOUT_DIR"
else
  [ -d "$CHECKOUT_DIR" ] || die "$CHECKOUT_DIR exists but is not a directory"
  command -v rsync >/dev/null 2>&1 || die "rsync not found — needed to migrate the checkout into $WT_DS_SRC"
  owner=$(mount_owner_of "$CHECKOUT_DIR")
  [ -z "$owner" ] \
    || die "$CHECKOUT_DIR is already the mountpoint of $owner — set WT_DS_SRC=$owner, or unmount it first"
  # The aside is the ONLY copy of the pre-migration checkout while the copy runs. Clobbering one
  # from an earlier (possibly half-finished) run would destroy exactly the thing it exists for.
  [ ! -e "$ASIDE_DIR" ] \
    || die "$ASIDE_DIR already exists; refusing to overwrite it — move or remove it first"

  confirm "move $CHECKOUT_DIR aside to $ASIDE_DIR and recreate it as ZFS dataset $WT_DS_SRC?"

  log "mv $CHECKOUT_DIR -> $ASIDE_DIR (nothing is deleted; this is your rollback copy)"
  mv -- "$CHECKOUT_DIR" "$ASIDE_DIR"

  log "zfs create $WT_DS_SRC (mountpoint=$CHECKOUT_DIR)"
  zfs create -o mountpoint="$CHECKOUT_DIR" -o xattr=sa -o acltype=posixacl "$WT_DS_SRC"
  chown "$WT_TARGET_UID:$WT_TARGET_GID" "$CHECKOUT_DIR"
  migrated=1
fi

# ---- 2. the never-snapshotted children ----------------------------------------------------
# Before any copying: a subpath's data must land IN its own dataset. Copy first and it lands in
# the parent, where every snapshot would faithfully capture it.
for sub in $WT_SNAPSHOT_EXCLUDE; do
  create_exclude_dataset "$sub"
done

# ---- 3. refill the checkout from the aside ------------------------------------------------
if [ "$migrated" -eq 1 ]; then
  # Excluded subpaths first, each into its own (now mounted) dataset, verified exactly: this is
  # the data that exists in ONE place and is shared by every sandbox, so a silent short copy here
  # is unrecoverable once the aside is reclaimed.
  for sub in $WT_SNAPSHOT_EXCLUDE; do
    [ -d "$ASIDE_DIR/$sub" ] || continue
    log "rsync $sub/ -> $CHECKOUT_DIR/$sub (own dataset; never snapshotted)"
    rsync -aHAX --info=progress2 "$ASIDE_DIR/$sub/" "$CHECKOUT_DIR/$sub/"
    verify_identical "$ASIDE_DIR/$sub" "$CHECKOUT_DIR/$sub"
  done

  rsync_excl=(); du_excl=()
  for sub in $WT_SNAPSHOT_EXCLUDE; do
    rsync_excl+=( --exclude="/$sub/" )   # anchored: only the checkout-root path, not any deep match
    du_excl+=( --exclude="$sub" )
  done
  log "rsync the rest of the checkout -> $CHECKOUT_DIR"
  rsync -aHAX --info=progress2 ${rsync_excl[@]+"${rsync_excl[@]}"} "$ASIDE_DIR/" "$CHECKOUT_DIR/"

  # Bytes, not file counts: hard links and sparse files legitimately count differently across a
  # dataset boundary. Directory inode blocks drift a little too, so allow a small tolerance and
  # only shout about a gap no bookkeeping difference could explain.
  src_b=$(du -sb ${du_excl[@]+"${du_excl[@]}"} "$ASIDE_DIR"    | cut -f1)
  dst_b=$(du -sb ${du_excl[@]+"${du_excl[@]}"} "$CHECKOUT_DIR" | cut -f1)
  drift=$(( src_b > dst_b ? src_b - dst_b : dst_b - src_b ))
  log "  verify source: src bytes=$src_b ; dst bytes=$dst_b ; drift=$drift"
  if [ "$drift" -ge 104857600 ]; then    # 100 MiB — larger than any plausible per-directory drift
    die "source rsync verify FAILED (drift $drift bytes); nothing was deleted — the original is intact at $ASIDE_DIR"
  fi
fi

# ---- 4. the clone parent ------------------------------------------------------------------
# wt mounts each clone itself (mountpoint=legacy), so this dataset's own mountpoint matters only
# as the host home of wt's state dir — bind it into the container as $WT_HOME.
promote_dir_to_dataset "$WT_DIR" "$WT_DS_PARENT" -o xattr=sa -o acltype=posixacl

# ---- 5. delegation ------------------------------------------------------------------------
# Permission sets are dataset-local, so define them on each dataset; both calls are idempotent.
#
# userprop is in the set because `wt new` stamps its provenance property ($WT_ZFS_PROP) at
# snapshot time (`zfs snapshot -o`), and `wt gc`/`wt list` reap ONLY snapshots that carry it.
# Losing the stamp does not just lose a label: every wt snapshot then looks hand-made, gc leaves
# them all behind, and the pool quietly fills up. It grants nothing new in practice — the same
# user may already destroy these datasets outright.
for ds in "$WT_DS_SRC" "$WT_DS_PARENT"; do
  zfs allow -s @wt-ops create,destroy,mount,clone,snapshot,promote,hold,release,rename,userprop "$ds"
done
# `wt new` clones with -o mountpoint=legacy -o canmount=noauto; setting properties at clone time
# needs permission for those properties on the dataset being created.
zfs allow -s @wt-props mountpoint,canmount,readonly,compression "$WT_DS_PARENT"

# -l AND -d: `-l` because the snapshot is named $WT_DS_SRC@... and the permission to create it
# lives on $WT_DS_SRC itself, not on a descendant; `-d` so the descendants (the exclude children,
# and every clone under the parent) inherit it without a second grant per sandbox.
zfs allow -l -d -u "$DELEGATE" @wt-ops "$WT_DS_SRC"
zfs allow -l -d -u "$DELEGATE" @wt-ops,@wt-props "$WT_DS_PARENT"
log "delegated snapshot/clone/destroy/mount/... to $DELEGATE (uid $WT_TARGET_UID)"

# ---- 6. probe -----------------------------------------------------------------------------
# Prove the delegation actually works for that identity, doing exactly what `wt new` does —
# including the $WT_ZFS_PROP stamp, whose permission (userprop) is easy to get wrong and whose
# absence would only surface later, as snapshots gc refuses to reap. `#<uid>` rather than a name:
# a container-only uid has no host passwd entry to look up.
probe_snap="$WT_DS_SRC@wt-host-setup-probe-$$"
log "probing: zfs snapshot -o $WT_ZFS_PROP=1 $probe_snap  (as uid $WT_TARGET_UID)"
if sudo -u "#$WT_TARGET_UID" zfs snapshot -o "$WT_ZFS_PROP=1" "$probe_snap"; then
  sudo -u "#$WT_TARGET_UID" zfs destroy "$probe_snap" \
    || die "probe snapshot $probe_snap was created but uid $WT_TARGET_UID could not destroy it — destroy it by hand and re-check the delegation"
  log "OK: uid $WT_TARGET_UID can snapshot (stamped) and destroy $WT_DS_SRC"
else
  die "probe FAILED: uid $WT_TARGET_UID cannot snapshot $WT_DS_SRC despite the delegation — inspect 'zfs allow $WT_DS_SRC'"
fi

# ---- done ---------------------------------------------------------------------------------
log ""
log "Host setup complete. Next:"
log "  1. Make $WT_DIR reachable in the container as \$WT_HOME, and $CHECKOUT_DIR as \$WT_CANONICAL"
log "     (bind mounts); rebuild/reopen the devcontainer so the new dataset is the bind source."
log "  2. Install wt in the container (see install.sh) and check 'wt status'."
if [ "$migrated" -eq 1 ]; then
  log "  3. Verify $CHECKOUT_DIR looks right (git status; build it), then reclaim the copy:"
  log "       rm -rf $ASIDE_DIR"
  log ""
  log "Rollback — only before that rm, and only if step 2 shows a problem:"
  log "  zfs destroy -r $WT_DS_SRC        # cascades to the never-snapshotted children"
  log "  mv $ASIDE_DIR $CHECKOUT_DIR"
fi
