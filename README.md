# Container Runtime CI Probe

This public repository probes whether GitHub-hosted runners can execute
host-level container runtime tests.

The workflow intentionally does not mirror any product repository CI. It checks
only the resources needed by runtime validation:

- passwordless sudo and systemd-managed Docker
- Docker daemon restart and custom runtime registration
- privileged container mount behavior
- BTF, bpffs, and active BPF LSM
- ID-mapped bind mounts and overlayfs on top of the mapped mount

When manually dispatching `Test host`, enable `debug_tmate` to open an SSH
session on the GitHub-hosted runner selected by `debug_target`.

`Test host` validates binaries extracted from an exact public GHCR image, for
example `ghcr.io/lwmacct/260522-nscell@sha256:...`. The runtime setup, gate
check, diagnostics, and workload flow live in this repository under
`scripts/ci.sh` and `tests/`.

All runtime workloads are stored in `tests/workloads/`. `tests/manifest.json`
is the single catalog for host and VM availability, the `smoke`, `gate`, and
`full` suites, and target timeouts. Each selected target gets its own runner,
services, logs, and artifact. A manual run can use `targets` to override its
selected suite and isolate one or more workloads.

Runtime host setup starts from a clean daemon state by default. Storage crash
recovery tests decode the checksummed `/var/lib/nscell/state/events.log`
snapshots directly, so they validate the daemon's actual recovery state instead
of relying on legacy per-domain JSON files.

The expensive Ubuntu 24.04 systemd environment is published separately as
`ghcr.io/lwmacct/260522-nscell-ci:systemd-pid1-latest`. Only the
`systemd-pid1` workload pulls it, on demand. The probe script and systemd unit
remain under `tests/workloads/systemd-pid1/` and are injected at test time, so
the published image contains no workload assertions.

`Test release` is the product-facing `workflow_dispatch` entry point. It calls
the reusable host and VM workflows in parallel, so every release gate uses one
CI commit and has one final conclusion. `Test host` and `Test workloads in VM`
remain manually dispatchable for focused runs and debugging. Runs, billing,
matrix jobs, logs, and artifacts remain in this public repository. The test
runner fetches the selected linux/amd64 image manifest and layers, extracts
`/usr/local/bin/nscell`, then installs the binary and the
`nscell-daemon.service` systemd unit.

`Check main` validates every direct push to `main`. It always runs repository
static checks and adds host and VM smoke coverage when runtime test files or
Actions change. This repository does not use a pull-request workflow.

The dedicated Ubuntu VM image and its nested Incus validation workflows are
documented in [`docs/nscell-vm.md`](docs/nscell-vm.md).
