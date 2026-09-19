# Runtime workload tests

This page documents the public runtime test repository. Product deployment is
owned by the NSCell repository and is not duplicated here.

## Workflows

- `Test workloads in VM` is the entry point for the product release workflow and
  for manual runs. The release workflow passes the digest it just built
  together with a suite and an optional target list, while manual runs may pass
  a tag such as `commit-<commit id>`. References are resolved to a digest once
  during preparation, then the selection runs on the canonical Ubuntu 26.04
  standard VM profile.
- `Build VM images` creates the Ubuntu 26.04 standard VM artifact used by the
  runtime workflow.

Suite and target selection is defined by `tests/manifest.json`, where every
target declares one class. Suites are compositions of those classes:

| Suite | Classes | Bundled budget |
| --- | --- | --- |
| `smoke` | preflight | 1 group, 1 target, 5m |
| `quick` | contract, policy, semantics | 12 groups, 20 targets, 74m |
| `runtime` | runtime | 3 groups, 3 targets, 28m |
| `gate` | quick + runtime | 15 groups, 23 targets, 102m |

`gate` is the release gate. `experiment` targets never run from a suite and
require an explicit `targets=` selection. Leaving targets empty runs the
requested suite and bundles targets that share a manifest group into one VM;
explicit targets run one workload per VM.

A target name and a group name are one namespace: both are selection tokens, so
both are lowercase kebab-case (`^[a-z0-9][a-z0-9-]*$`), neither may be a command
word (`all`, `cleanup`, `parallel`, `run`), and a group may not reuse a target
name. That token becomes the matrix entry, the job, the VM, the diagnostics
artifact, and the guest dispatch argument, so one token must always select the
same targets. `tests/manifest.sh` owns the rule: it rejects a manifest that
breaks it and re-derives the targets behind a token before a VM boots. An
explicit target list runs one target per VM, because no group token stands for
that entry.

## Targets

The table lists the targets the `gate` suite composes. `experiment` targets are
listed separately because only an explicit `targets=` selection reaches them.

| Target | Coverage |
| --- | --- |
| `container-security-policy` | security profile, BPF audit, xattr, proc/sys, and process isolation |
| `daemon-crash-recovery` | crash-time persistent state and recovery |
| `daemon-dial-retry` | control connection retry behavior |
| `daemon-fail-stop` | fail-stop cleanup and daemon readiness |
| `daemon-fail-stop-docker` | fail-stop reap of a container whose runtime state root is the shim's |
| `docker-in-docker` | nested Docker daemon and inner container lifecycle |
| `fuse-copy-file-range` | FUSE data-path behavior |
| `fuse-request-timeout` | FUSE request timeout and cancellation |
| `io-uring-policy` | io_uring task-scoped opcode policy: allowed ring, refused trapped forms, and profiles that stay closed |
| `kernel-capability-smoke` | Linux 7 native ABI diagnostic set |
| `kubernetes-k3s` | nested k3s node and inner pod lifecycle |
| `new-mount-api-deny` | mediated new-mount API policy, including the Linux 7.0 statmount fields a permitted profile must receive |
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

## Explicit-selection-only targets

| Target | Coverage |
| --- | --- |
| `fuse-cost-attribution` | daemon CPU attributed to FUSE traffic and the virtualized views |
| `fuse-io-uring-probe` | disabled baseline plus enabled register/commit/teardown probe inside an isolated disposable VM |
| `fuse-transport-baseline` | classic `/dev/fuse` transport baseline used as the comparison point |

The standalone `smoke` target installs NSCell, checks daemon readiness and the
BPF gate, registers the Docker runtime, and starts one preloaded Python Alpine
container.

## Runner environment

`scripts/ci.sh` and `tests/library/env.sh` own disposable VM deployment. Their
main inputs are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NSCELL_IMAGE` | `ghcr.io/lwmacct/260522-nscell:latest` | exact or mutable public NSCell image reference; test workflows resolve the input to an immutable digest before the matrix starts |
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
