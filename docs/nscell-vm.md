# NSCell VM validation

This repository owns dedicated AMD64 Incus VM images for NSCell runtime
validation. The images are built with `distrobuilder`, while the runner installs
Incus from the signed Zabbly source at `pkgs.zabbly.com`.

Two production profiles are maintained:

- `images/standard.yaml` is Ubuntu 26.04 with `linux-image-virtual-hwe-26.04`.
  It provides broad current-kernel workload coverage.
- `images/linux-6-18.yaml` is Debian 13 with the stable 6.18 kernel. It is the
  exact floor gate and is used for `kernel-capability-smoke`.

`images/standard-pycache.yaml` is an experimental copy of the standard profile.
Its build workflow boots the candidate once, pulls the pinned Python base image
into Docker, and republishes the warmed qcow2 disk as a split Incus VM image.
It is not used by release validation until its size and runtime measurements
satisfy the optimization plan.

Both contain the Incus VM agent, the Docker runtime stack, FUSE and idmap
utilities, diagnostics, and a guest GRUB command line that enables the BPF LSM.
They do not contain an NSCell binary; each test workflow accepts an nscell OCI
image, extracts its AMD64 binary on the GitHub runner, and exposes it to a
disposable VM through a read-only Incus disk share.

The profiles intentionally omit a guest compiler toolchain. Runtime workloads
must not depend on building probes inside the guest; the staged plan for a
possible Python image preset is tracked in
[`vm-image-optimization-plan.md`](vm-image-optimization-plan.md).

The image workflow publishes a commit-addressed candidate such as:

```text
ghcr.io/lwmacct/260522-nscell-ci:artifact-images-standard-sha-<12-char-commit>
```

Each profile uses the same pattern and publishes a stable
`artifact-images-<profile>` tag. A successful build publishes the
commit-addressed tag and updates that profile's stable tag.

GHCR artifacts are imported into Incus with ORAS before the VM is started.
The artifact contains `incus.tar.xz`, `disk.qcow2`, and `SHA256SUMS`.

## Workflows

- `Build VM images` runs on profile changes or manually. It builds each
  selected profile, checks the qcow2 file, and publishes commit-addressed and
  stable tags without starting a guest.
- `Test workloads in VM` is the manual VM coverage entry point. Each selected
  target gets its own runner and VM, so workloads run concurrently rather than
  sharing a guest. The `smoke`, `gate`, and `full` suites are defined in
  `tests/manifest.json`; an explicit `targets` value overrides the suite.
- VM `gate` is the complete release check suite. Every workload runs in an
  isolated guest with the BPF LSM gate enforced in strict mode; the reduced
  security host execution mode has been removed.
- The special `smoke` target checks BPF LSM, nscell daemon readiness, Docker
  runtime registration, and one `busybox` container.
- Release validation also runs `kernel-capability-smoke` on the Debian 6.18
  floor profile. A current-kernel standard VM run cannot replace that gate.

Both test workflows accept `nscell_image`. The nscell release workflow passes
an immutable digest and waits for their results, while manual runs can select
any published nscell image.
Before expanding the VM matrix, the workflow resolves the requested VM tag to
an immutable OCI digest. Every isolated VM in that run therefore consumes the
same image even if the stable profile tag changes while tests are running.
The smoke workflow also pulls and exports its BusyBox image on the runner, so
the guest setup and smoke test do not depend on guest network access. Test
assets and a CI repository snapshot are exposed through one read-only Incus
`9p` directory share. The runner explicitly selects `9p` because the default
`virtiofs` transport conflicts with PCI allocation on GitHub-hosted runners.

The VM runner always uses KVM and is AMD64-only. Failed runs upload the guest
daemon log, systemd/Docker diagnostics, and `/data/nscell` test logs.
