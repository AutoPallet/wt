# wt

Throwaway build sandboxes that are **warm from the first second**, via per-sandbox ZFS clones.

`wt new foo` gives you an isolated checkout of your repo — sources *and* build outputs — near
instantly. Build in it immediately: nothing recompiles, because it is a copy-on-write clone of
the tree you were just working in. Break it, `wt rm foo`, and it is gone. Your main checkout was
never touched.

```
wt new   <name> [ref]         snapshot+clone your current tree (uncommitted changes and all)
wt enter <name> [-- cmd...]   enter the sandbox (default: bash)
wt list                       sandboxes, and the bytes each clone alone is holding down
wt rm    <name>               clone+snapshot destroyed; the branch is archived, not deleted
wt gc                         reclaim orphans whose sandbox is gone
wt status                     config + dataset state
```

## Why it's warm, and why that's hard to get otherwise

The usual approaches to "a second checkout" all cost you the build cache:

| approach | why the build cache dies |
|---|---|
| `git worktree` | different path → absolute paths in build artifacts miss; a fresh `target/` |
| `cp -r` the repo | different path, and you pay a full copy |
| container per branch | different path *and* different filesystem |
| shared cache dir | the compiler still re-checks and re-links everything |

`wt` sidesteps all of it with one trick: **the sandbox lives at the same path as your main
checkout.** Inside its own mount namespace, the ZFS clone is mounted *over* `$WT_CANONICAL`.
So every absolute path a build system baked into its artifacts still resolves, and the sandbox
is byte-for-byte what your working tree was — including `target/`, `build/`, `node_modules/`.

Sources and build outputs come from **one atomic snapshot**, so their mtimes stay mutually
consistent. An mtime-based build system (cargo, make, ninja) therefore sees a fully warm tree
and rebuilds exactly what you edit — no content-hashing flag, no mtime-aging hack, no path
remapping.

`zfs snapshot` and `zfs clone` take milliseconds and are copy-on-write, so a sandbox costs only
what it diverges by. `wt list` shows you that number.

## It knows nothing about your project

`wt` has no language, toolchain, daemon or cache built into it. Anything project-specific
comes from two hooks you configure:

- **`WT_HOOK_ENTER`** runs inside the sandbox namespace, as the target user, once per
  `wt enter`, before your command. Whatever `KEY=VALUE` lines it prints on stdout are exported
  into the session (direnv-style). Use it to start per-sandbox daemons and inject their env.
- **`WT_HOOK_TEARDOWN`** runs host-side when the last session exits, and on `wt rm` / `wt gc`.
  Must be idempotent. Anything the enter hook left running inside the namespace *pins the
  clone's mount* and would otherwise block `zfs destroy`.

**The enter hook's exit code gates the session: non-zero aborts `wt enter`.** That is deliberate,
and it is the one rule worth internalising before you write a hook. A sandbox that starts without
what its hook guarantees is the expensive failure — if the hook's job was to hand out a
*per-sandbox* build-daemon socket, a session that skips it falls back to the *shared* one, and
then one daemon writes every sandbox's build outputs into the wrong clone. You would not learn
that from an error message; you would learn it from a corrupt artifact, days later. So make
anything advisory `|| true`, and let a real failure stop the session. The hook's stderr goes to
your terminal, so you can see why.

The teardown hook is the opposite: its exit code is **ignored**. A sandbox whose teardown hook is
broken must still be removable.

## Install

```sh
git clone https://github.com/AutoPallet/wt && cd wt
sudo ./install.sh                 # /usr/local/bin, or pass a prefix
```

Then write a config. `wt` reads `$WT_CONFIG` if set, else `~/.config/wt/config`, else
`/etc/wt/config` — and the environment overrides whatever the file says. Start from
[`wt.conf.example`](wt.conf.example):

```sh
WT_CANONICAL=/workspaces/myrepo               # required: the checkout wt clones
WT_DS_SRC=rpool/data/myrepo-src               # required: the dataset holding it
WT_DS_PARENT=rpool/data/myrepo-wt             # required: where per-sandbox clones go
WT_SNAPSHOT_EXCLUDE=logs                      # subpaths that must never enter a snapshot
WT_HOOK_ENTER='/opt/myrepo/wt-hook enter'
WT_HOOK_TEARDOWN='/opt/myrepo/wt-hook teardown'
```

Config in hand, build the datasets. Run this **on the host** and **as yourself** — it re-execs
itself under sudo for the parts that need root, and it reads the config you just wrote:

```sh
./host-zfs-setup.sh               # once per host: builds the datasets, delegates ZFS to your user
```

## Requirements

**ZFS.** Not an implementation detail to be abstracted away later — millisecond copy-on-write
snapshots *are* the tool. Also: Linux, for mount namespaces; `sudo`, because mounting a ZFS
dataset needs real root (the ZFS module refuses the mount from inside a user namespace, so
unprivileged containers alone will not do); and git ≥ 2.17, for `git worktree remove`.

## Editor over SSH, with no listening port

`wt-ssh` runs on your machine, not in the container, and hands your editor an SSH session
*into* a sandbox over `docker exec`: sshd speaks its protocol over the pipe (`sshd -i`), so no
port is bound anywhere.

```sh
sudo ./install.sh --with-ssh      # on your machine: installs wt-ssh alongside wt
wt ssh-setup                      # inside the container, once: sshd config + authorized_keys
wt-ssh config >> ~/.ssh/config    # on your machine: one `Host wt-<name>` per sandbox
ssh wt-foo                        # or point VS Code / JetBrains at it
```

Run `wt ssh-setup` from your container's start hook (as `wt ssh-setup || true`) so it survives a
container restart.

## Two things wt refuses to do

**Destroy a snapshot it didn't create.** `wt gc` reaps only snapshots stamped with its ZFS
property (`WT_ZFS_PROP`); a name glob is not provenance. Your hand-made `@wt-backup` gets
listed for you to reap by hand, never destroyed automatically.

**Believe a marker file.** A session counts as live only while it holds an `flock`. The exit
trap never runs on SIGKILL, so a leftover marker proves nothing — but the lock dies with the
process, however the process dies. So `wt rm` can't be fooled into destroying a clone a live
session is still using, and can't be blocked forever by a sandbox that was OOM-killed a week ago.

(Anything *else* still pinning the clone's mount — a daemon that outlived its session — is killed
so the destroy can proceed. The flock protects sessions, not stragglers.)

## Tests

```sh
test/test-gc-unit.sh        # snapshot provenance: gc reaps only what wt created
test/test-newrm-unit.sh     # wt new / wt rm: the create and destroy paths
test/test-hooks-unit.sh     # the hook contract, incl. the exit-code gate
test/test-marker-unit.sh    # session liveness + locking (a flock, not a pidfile)
test/test-ssh-unit.sh       # wt-ssh container resolution
```

These are hermetic: `zfs`, `git` and the hooks are stubbed on `PATH`, `docker` is a shell
function, and the `setpriv` privilege drop is disabled through its `WT_DROP_PRIV` seam. So they
need no pool, no root and no container, and they run in seconds. CI gates every pull request and
every push to `main`.

`test/spikes/` holds the standalone experiments that settled the load-bearing design questions
(does a mount namespace outlive its creator? does `flock` behave under contention? will `sshd -i`
serve a session over a pipe?). They need a real host, and they are kept because re-running them
re-proves those assumptions on your hardware.

## License

MIT. See [LICENSE](LICENSE).
