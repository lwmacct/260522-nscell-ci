# NSCell Runtime CI

This public repository runs NSCell runtime workload validation in disposable
virtual machines with the BPF LSM gate enforced in strict mode.

The workflow intentionally does not mirror any product repository CI. It checks
only the resources needed by runtime validation:

- passwordless sudo and systemd-managed Docker
- Docker daemon restart and custom runtime registration
- privileged container mount behavior
- BTF, bpffs, and active BPF LSM
- ID-mapped bind mounts and overlayfs on top of the mapped mount

Every workflow validates binaries extracted from one public
`ghcr.io/lwmacct/260522-nscell` image. Callers pass either an immutable digest
or a tag such as `commit-<commit id>`; the run resolves the reference once
before the VM matrix starts. The runtime setup, gate check, diagnostics, and
workload flow live in this repository under `scripts/ci.sh` and `tests/`.

All runtime workloads are stored in `tests/workloads/`. `tests/manifest.json`
is the single catalog for VM availability, the `smoke`, `gate`, and `full`
suites, target timeouts, and compatible VM target groups. Selecting a suite
bundles targets that share a group into one runner, VM, runtime installation,
and diagnostics artifact, while daemon-mutating and heavy workloads remain
isolated. Selecting explicit `targets` instead runs one target per VM.

Runtime host setup starts from a clean daemon state by default. Storage crash
recovery tests decode the checksummed `/var/lib/nscell/state/events.log`
snapshots directly, so they validate the daemon's actual recovery state instead
of relying on legacy per-domain JSON files.

The expensive Ubuntu 26.04 systemd environment is published separately as
`ghcr.io/lwmacct/260522-nscell-ci:systemd-pid1-latest`. Only the
`systemd-pid1` workload pulls it, on demand. The probe script and systemd unit
remain under `tests/workloads/systemd-pid1/` and are injected at test time, so
the published image contains no workload assertions.

`Test workloads in VM` is the entry point for the product release workflow and
for manual runs. The release workflow passes the immutable digest it just built
together with a suite and an optional target list, while manual runs may pass a
tag such as `commit-<commit id>`. Choosing the `smoke` suite selects only the
standalone `smoke` probe. Explicit targets bypass the suite selection for
focused debugging. Runs, billing, matrix jobs, logs, and artifacts remain in
this public repository. The test runner fetches the selected linux/amd64 image
manifest and layers, extracts `/usr/local/bin/nscell`, then installs the binary
and the `nscell-daemon.service` systemd unit.

`Check main` validates every direct push to `main`. It always runs repository
static checks and adds VM smoke coverage when runtime test files or
Actions change. The smoke run pulls `ghcr.io/lwmacct/260522-nscell:latest`,
so CI changes are always exercised against the current released NSCell image.
This repository does not use a pull-request workflow.

The dedicated Ubuntu VM image and its nested Incus validation workflows are
documented in [`docs/nscell-vm.md`](docs/nscell-vm.md).
Runtime workflow inputs, target coverage, and disposable-runner environment
variables are documented in [`docs/runtime-tests.md`](docs/runtime-tests.md).
Failed workflow, readiness, and workload triage steps are documented in
[`docs/troubleshooting.md`](docs/troubleshooting.md).
