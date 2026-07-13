# wt

Throwaway build sandboxes that are **warm from the first second**, via per-sandbox ZFS clones.

`wt new foo` gives you an isolated checkout of your repo — sources *and* build outputs — in a
few milliseconds. Build in it immediately: nothing recompiles, because it is a copy-on-write
clone of the tree you were just working in. Break it, `wt rm foo`, and it is gone. Your main
checkout was never touched.

```
wt new   <name> [ref]         snapshot+clone your current tree (uncommitted changes and all)
wt enter <name> [-- cmd...]   enter the sandbox (default: bash)
wt list                       sandboxes + how many bytes each clone actually costs
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

`zfs snapshot` and `zfs clone` take milliseconds and are copy-on-write, so a sandbox is
near-instant to create and costs only what it diverges by. `wt list` shows you that number.

## It knows nothing about your project

`wt` has no language, toolchain, daemon or cache built into it. Anything project-specific
comes from two hooks you configure:

- **`WT_HOOK_ENTER`** runs inside the sandbox namespace, as the target user, once per
  `wt enter`, before your command. Whatever `KEY=VALUE` lines it prints on stdout are exported
  into the session (direnv-style). Use it to start per-sandbox daemons and inject their env.
- **`WT_HOOK_TEARDOWN`** runs host-side when the last session exits, and on `wt rm` / `wt gc`.
  Must be idempotent. Anything the enter hook left running inside the namespace *pins the
  clone's mount* and would otherwise block `zfs destroy`.

The failure contract is deliberately asymmetric, and it matters: a hook that **ran and then
failed** is tolerated (the env it already printed still applies — so print your env first). A
hook that **could not be executed at all** aborts the session, loudly. Silently tolerating a
missing hook would start the sandbox without whatever the hook guarantees — and if that was,
say, a per-sandbox compiler-cache socket, every sandbox would quietly share one server and
write its build outputs into *someone else's clone*. A hard error beats corrupt artifacts.

## Install

```sh
git clone https://github.com/AutoPallet/wt && cd wt
sudo ./install.sh                 # /usr/local/bin, or pass a prefix
sudo ./host-zfs-setup.sh          # once per host: build the datasets, delegate to your user
```

Then write a config — `/etc/wt/config`, or `~/.config/wt/config`, or `$WT_CONFIG`. Start from
[`wt.conf.example`](wt.conf.example); the environment overrides anything in the file.

```sh
WT_CANONICAL=/workspaces/myrepo               # required: the checkout wt clones
WT_DS_SRC=rpool/data/myrepo-src               # required: the dataset holding it
WT_DS_PARENT=rpool/data/myrepo-wt             # required: where per-sandbox clones go
WT_SNAPSHOT_EXCLUDE=logs                      # subpaths that must never enter a snapshot
WT_HOOK_ENTER='/opt/myrepo/wt-hook enter'
WT_HOOK_TEARDOWN='/opt/myrepo/wt-hook teardown'
```

## Requirements

**ZFS.** Not an implementation detail to be abstracted away later — millisecond copy-on-write
snapshots *are* the tool. Also: Linux (mount namespaces), `sudo` for the mount (the ZFS module
rejects delegated mounts from a non-init userns, so a userns alone will not do), and git ≥ 2.5.

## Editor over SSH, with no listening port

`wt-ssh` runs on your machine, not in the container, and hands your editor an SSH session
*into* a sandbox over `docker exec` — inetd-mode `sshd -i` on a pipe, no port bound anywhere.

```sh
wt-ssh config >> ~/.ssh/config    # one `Host wt-<name>` per sandbox
ssh wt-foo                        # or point VS Code / JetBrains at it
```

## Two things wt refuses to do

**Destroy a snapshot it didn't create.** `wt gc` reaps only snapshots stamped with its ZFS
property (`WT_ZFS_PROP`); a name glob is not provenance. Your hand-made `@wt-backup` gets
listed for you to reap by hand, never destroyed automatically.

**Believe a marker file.** A session counts as live only while it holds an `flock`. The exit
trap never runs on SIGKILL, so a leftover marker proves nothing — but the lock dies with the
process no matter how the process dies, which is the only signal that cannot lie. `wt rm`
therefore can't be fooled into destroying a clone that something is still using, or blocked
forever by a sandbox that was OOM-killed a week ago.

## Tests

```sh
test/test-gc-unit.sh        # snapshot provenance: gc reaps only what wt created
test/test-hooks-unit.sh     # the hook contract, incl. the asymmetric failure rule
test/test-marker-unit.sh    # session liveness + locking (a flock, not a pidfile)
test/test-ssh-unit.sh       # wt-ssh container resolution
```

These are hermetic — `zfs`, `docker`, `setpriv` and the hooks are stubbed on `PATH`, so they
need no pool, no root and no container, and they run in seconds. CI gates on every push.

`test/spikes/` holds the standalone experiments that settled the load-bearing design questions
(does a mount namespace outlive its creator? does `flock` behave under contention? will `sshd -i`
serve a session over a pipe?). They need a real host; they are kept because the answers are
easier to re-derive by running them than by arguing.
