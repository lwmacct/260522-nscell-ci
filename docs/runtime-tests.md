# Runtime workload tests

This page documents the public runtime test repository. Product deployment is
owned by the NSCell repository and is not duplicated here.

## Workflows

- `Test release` is called by the product release workflow with an immutable
  NSCell image digest. It runs the complete `gate` suite on the canonical
  Ubuntu 26.04 standard VM profile.
- `Test workloads in VM` is the manual debugging entry point. Choose a suite, or
  provide explicit target names for focused validation.
- `Build VM images` creates the Ubuntu 26.04 standard VM artifact used by both
  runtime workflows.

Suite and target selection is defined by `tests/manifest.json`. Leaving targets
empty selects the requested suite. Explicit targets run one workload per VM by
default; set `grouping=bundled` to reuse a VM for compatible lightweight targets.

## Gate targets

| Target | Coverage |
| --- | --- |
| `container-security-policy` | security profile, BPF audit, xattr, proc/sys, and process isolation |
| `daemon-crash-recovery` | crash-time persistent state and recovery |
| `daemon-dial-retry` | control connection retry behavior |
| `daemon-fail-stop` | fail-stop cleanup and daemon readiness |
| `docker-in-docker` | nested Docker daemon and inner container lifecycle |
| `fuse-copy-file-range` | FUSE data-path behavior |
| `fuse-io-uring-probe` | full-suite-only ABI/resource inventory plus bounded detached register/commit/teardown probe; never enables the host feature |
| `fuse-request-timeout` | FUSE request timeout and cancellation |
| `kernel-capability-smoke` | Linux 7 native ABI diagnostic set |
| `kubernetes-k3s` | nested k3s node and inner pod lifecycle |
| `new-mount-api-deny` | mediated new-mount API policy |
| `oci-lifecycle` | OCI create/start/exec/kill/delete lifecycle |
| `oci-mount-semantics` | mount identity, propagation, and visibility |
| `procfs-cpu` | CPU procfs presentation and cpuset resources |
| `procfs-memory` | memory procfs presentation and OOM behavior |
| `resource-limits` | initial resource limit application |
| `resource-update` | live resource updates |
| `rootfs-event-recovery` | rootfs event and retained-resource recovery |
| `seccomp-notify-concurrency` | concurrent seccomp notification handling |
| `shared-netns-lifecycle` | shared network namespace reuse and cleanup |
| `storage-crash-boundaries` | checksummed event-log crash boundaries |
| `storage-lifecycle` | volume creation, synchronization, and destruction |
| `systemd-pid1` | systemd-managed system container |

The standalone `smoke` target installs NSCell, checks daemon readiness and the
BPF gate, registers the Docker runtime, and starts one preloaded Python Alpine
container.

## Runner environment

`scripts/ci.sh` and `tests/library/env.sh` own disposable VM deployment. Their
main inputs are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NSCELL_IMAGE` | `ghcr.io/lwmacct/260522-nscell:latest` | exact or mutable public NSCell image reference |
| `NSCELL_IMAGE_PLATFORM` | `linux/amd64` | platform manifest selected with ORAS |
| `NSCELL_CI_TEST_ROOT` | `/tmp/nscell` | test workspace root |
| `NSCELL_CI_IMAGE_CACHE_DIR` | `${NSCELL_CI_TEST_ROOT}/images` | image cache |
| `NSCELL_CI_RESET_DAEMON_STATE` | `1` | start each disposable guest from clean daemon state |
| `NSCELL_RELEASE_ROOT` | `/opt/nscell/releases` | release directory inside the guest |
| `NSCELL_CURRENT_LINK` | `/opt/nscell/current` | current release symlink |
| `NSCELL_DAEMON_LOG` | `/var/log/nscell-daemon.log` | guest daemon log |
| `NSCELL_WORKLOAD_RUN_ID` | Actions run and attempt | resource naming suffix |

Workload image and container names are defined near each workload in
`tests/library/env.sh`. Avoid copying these implementation defaults into product
deployment documentation.

The runner creates `/data/nscell` for workload data, images, volumes, and logs
when those paths are selected by a test. Failed VM jobs upload guest daemon logs,
systemd/Docker diagnostics, and the relevant `/data/nscell` logs as artifacts.

## Product-owned validation boundary

The Ubuntu 26.04 standard profile is the canonical minimum validation profile.
It boots the Linux 7.0 series and also serves as the supported current workload
profile. A second Linux-floor image is not maintained.
