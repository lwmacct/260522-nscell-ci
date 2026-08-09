# NSCell Ubuntu VM validation

This repository owns a dedicated Ubuntu 24.04 AMD64 Incus VM image for NSCell
runtime validation. The image is built with `distrobuilder`, while the runner
installs Incus from the signed Zabbly source at `pkgs.zabbly.com`.

The first image profile is `images/standard.yaml`. It contains the Incus VM
agent, the Docker runtime stack, FUSE and idmap utilities, diagnostics, and a
guest GRUB command line that enables the BPF LSM. It does not contain an
NSCell binary; each test workflow accepts an nscell OCI image, extracts its
AMD64 binary on the GitHub runner, and exposes it to a disposable VM through a
read-only Incus disk share.

The image workflow publishes a commit-addressed candidate such as:

```text
ghcr.io/lwmacct/260522-nscell-ci:artifact-images-standard-sha-<12-char-commit>
```

The stable profile tag is
`ghcr.io/lwmacct/260522-nscell-ci:artifact-images-standard`. A successful
build publishes the commit-addressed tag and updates this stable tag.

GHCR artifacts are imported into Incus with ORAS before the VM is started.
The artifact contains `incus.tar.xz`, `disk.qcow2`, and `SHA256SUMS`.

## Workflows

- `Build VM standard` runs on profile changes or manually. It builds each
  selected profile, checks the qcow2 file, and publishes commit-addressed and
  stable tags without starting a guest.
- `Test workloads in VM` is the manual and reusable entry point for VM
  coverage. Each selected target gets its own runner and VM, so workloads run
  concurrently rather than sharing a guest. The special `smoke` target checks
  BPF LSM, nscell daemon readiness, Docker runtime registration, and one
  `busybox` container.
- The same workflow accepts a space-separated list such as
  `procfs-cpu systemd-pid1`, or `all` for the complete suite.

Both test workflows accept `nscell_image`. The nscell release workflow passes
an immutable digest, while manual runs can select any published nscell image.
The smoke workflow also pulls and exports its BusyBox image on the runner, so
the guest setup and smoke test do not depend on guest network access. Test
assets and a CI repository snapshot are exposed through one read-only Incus
`9p` directory share. The runner explicitly selects `9p` because the default
`virtiofs` transport conflicts with PCI allocation on GitHub-hosted runners.

The VM runner always uses KVM and is AMD64-only. Failed runs upload the guest
daemon log, systemd/Docker diagnostics, and `/data/nscell` test logs.
