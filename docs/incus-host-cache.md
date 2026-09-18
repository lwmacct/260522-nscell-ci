# Incus host cache

The VM test jobs run on a clean `ubuntu-26.04` hosted runner. The
`Setup Incus host` action restores an exact-key cache containing only the
package filesystem delta from that runner image, then recreates the host state
that cannot be copied between machines.

The cache is deliberately not a snapshot of `/`. The layer excludes runtime
mounts, runner workspaces, machine identity, logs, apt indexes, Incus state,
and systemd runtime state. Package metadata and files under the package-owned
paths are restored with GNU tar's incremental extraction; `systemd-sysusers`,
`systemd-tmpfiles`, `ldconfig`, and `systemctl daemon-reload` rebuild the
machine-local pieces.

The cache key includes the runner image version when the hosted image exposes
it, the kernel, architecture, package recipe, cache script, and baseline dpkg
manifest. A changed runner image, recipe, or script therefore cannot reuse an
old layer. The cache is immutable; bump `.github/incus-host/cache-version` to
force a new entry without changing the recipe.

`.github/workflows/build-incus-host-cache.yml` is the cache owner. It creates a
layer on one hosted runner and restores it on a second fresh runner before
initializing a real Incus bridge and checking VM prerequisites. Production
matrix jobs only restore the exact key. A cache miss, fingerprint mismatch,
checksum failure, or post-restore package audit failure falls back to the
existing APT installation path.

If a cache layer must be retired, bump the cache version and dispatch the
dedicated workflow. Old entries are immutable Actions caches and will be
evicted by the repository cache policy.
