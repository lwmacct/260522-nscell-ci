# NSCell VM validation

This repository owns dedicated AMD64 Incus VM images for NSCell runtime
validation. The images are built with `distrobuilder`, while the runner installs
Incus from the signed Zabbly source at `pkgs.zabbly.com`.

One production profile is maintained:

- `images/standard.yaml` is Ubuntu 26.04 with `linux-image-virtual-hwe-26.04`.
  Ubuntu 26.04 currently boots the `7.0.0-X-generic` kernel series, so this
  profile provides both the Linux 7.0 minimum-kernel gate and broad
  current-kernel workload coverage. It also contains the unpacked Docker image
  store for the pinned Python Alpine base used by repeated runtime workloads.

The profile contains the Incus VM agent, the Docker runtime stack, FUSE and
idmap utilities, diagnostics, and a guest GRUB command line that enables the
BPF LSM. It does not contain an NSCell binary; each disposable guest accepts an
exact public NSCell OCI image reference, fetches its AMD64 layers with ORAS,
and installs the extracted binary without guest registry credentials.

The profiles intentionally omit a guest compiler toolchain. Runtime workloads
must not depend on building probes inside the guest; the staged plan for a
the measured Python image preset is tracked in
[`vm-image-optimization-plan.md`](vm-image-optimization-plan.md).

The image workflow publishes a commit-addressed candidate such as:

```text
ghcr.io/lwmacct/260522-nscell-ci:artifact-images-standard-sha-<12-char-commit>
```

The profile publishes the stable `artifact-images-standard` tag. A successful
build publishes the commit-addressed tag and updates that stable tag.

GHCR artifacts are imported into Incus with ORAS before the VM is started.
The artifact contains `incus.tar.xz`, `disk.qcow2`, and `SHA256SUMS`.

## Workflows

- `Build VM images` runs on profile changes or manually. It builds each
  selected profile, checks the qcow2 file, and publishes commit-addressed and
  stable tags without starting a guest.
- `Test workloads in VM` is the manual VM coverage entry point. Suite runs use
  manifest-declared workload groups, while explicit target selection defaults
  to one target per VM for focused debugging. The `smoke`, `gate`, and `full`
  suites are defined in `tests/manifest.json`.
- VM `gate` is the complete release check suite. Every workload runs in an
  isolated guest with the BPF LSM gate enforced in strict mode; the reduced
  security host execution mode has been removed.
- The special `smoke` target checks BPF LSM, nscell daemon readiness, Docker
  runtime registration, and one `busybox` container.
- `kernel-capability-smoke` enforces the Linux 7.0 minimum on the standard
  Ubuntu 26.04 VM and exercises its mount, namespace, pidfd, FUSE, and
  namespace-listing interfaces.

Both test workflows accept `nscell_image`. The nscell release workflow passes
an immutable digest and waits for their results, while manual runs can select
any published nscell image.
Before expanding the VM matrix, the workflow resolves the requested VM tag to
an immutable OCI digest. Every isolated VM in that run therefore consumes the
same image even if the stable profile tag changes while tests are running.
The standard image's Docker store contains the pinned Python Alpine image used
by Python-derived workloads and by the lightweight OCI-bundle workloads. The
smoke target runs that preloaded image with `--pull=never`; it does not provide
an offline-guest guarantee because the NSCell OCI image is still fetched inside
the VM. Uncached heavyweight workload images are also fetched normally. Test
assets and a CI repository snapshot are exposed through one read-only Incus
`9p` directory share. The runner explicitly selects `9p` because the default
`virtiofs` transport conflicts with PCI allocation on GitHub-hosted runners.

The VM runner always uses KVM and is AMD64-only. Failed runs upload the guest
daemon log, systemd/Docker diagnostics, and `/data/nscell` test logs.
