# Changelog

## 0.4.0

### SSH upgrade

SSH access is now part of the `wt ssh` command family. When upgrading an existing installation:

1. Reinstall `wt` normally on both the host and container; the installer no longer accepts
   `--with-ssh`.
2. Remove the old `wt-ssh` executable from its installation prefix.
3. Remove SSH config blocks whose `ProxyCommand` invokes `wt-ssh proxy`.
4. Remove `wt ssh-setup` from container startup hooks.
5. From each host checkout that needs editor aliases, run `wt ssh enable`.

The retired `wt ssh-config`, `wt ssh-serve`, and `wt ssh-forced` plumbing commands have no direct
replacement. Configuration is managed by `wt ssh enable`, and server preparation happens as part
of each connection.
