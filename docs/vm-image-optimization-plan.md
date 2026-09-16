# VM image optimization plan

This plan tracks the approved CI optimization sequence. The objective is to
remove avoidable per-workload image work without hiding runtime coverage behind
a large all-in-one VM image.

## Phase 1: deterministic lightweight workloads

Status: **complete in this change**

- Pin `python:3.12-alpine` to the immutable multi-platform digest
  `sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a`.
- Remove the Alpine `build-base` dependency from `procfs-memory`; its `sysinfo`
  probe now calls the libc `sysinfo` function through Python `ctypes`.
- Remove unused guest compiler and development packages from both VM profiles:
  `build-essential`, `gcc`, `libseccomp-dev`, and `pkg-config`.
- Keep the explicit BusyBox pull in the smoke target so a real network pull and
  image extraction path remain covered.

Expected effect:

- Avoid the approximately 345MB unique `build-base` layer in `procfs-memory`.
- Reduce both base VM images before any image preset is added.
- Make Python-base behavior deterministic while the preset experiment is pending.

Validation:

- Local Docker builds succeeded for all four Python-based workload images.
- The `procfs-memory` image fell from roughly 433MB to 88MB.
- Branch validation for all five Python-based VM targets succeeded:
  [test run 35140157382](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35140157382).
- Static checks, standard smoke, and the Linux 6.18 floor smoke succeeded:
  [check run 35140175062](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35140175062).
- In the validated run, `procfs-memory` image preparation fell from the roughly
  116-second baseline to about 36 seconds. The other Python jobs still spend
  36-60 seconds extracting the shared base image, which is the target of phase
  two.

## Phase 2: experimental Python image preset

Status: **not started**

Create a separate experimental profile rather than enlarging `standard`
immediately. The candidate profile must contain the already-unpacked Docker
image store for the pinned Python digest. Storing only an OCI archive and
loading it on every boot would move, rather than remove, the expensive
extraction step.

Measure against the phase-one baseline:

- GHCR `disk.qcow2` artifact size.
- `Pull and verify VM image` duration.
- Duration of all five Python-based workload jobs.
- `gate` wall time and total runner minutes.
- Registry and network failure count.

Rollout criteria:

- The smoke BusyBox pull remains live, preserving image-pull coverage.
- Python workload image preparation drops by roughly 40-50 seconds per affected
  job after accounting for any larger VM artifact download.
- The experimental profile is promoted only if total gate cost and reliability
  improve; otherwise it is retired.

## Phase 3: slow-path workload review

Status: **not started**

Do not preload Docker-in-Docker, Kubernetes, or NGINX into the shared standard
profile. If they remain the gate critical path after phase two, optimize them
independently:

- Replace mutable or broad NGINX tags with a smaller pinned variant.
- Avoid rebuilding unchanged workload images.
- Split heavyweight coverage into an explicitly selected fast profile.
- Preserve at least one real image pull and extraction test in every gate.

## Baseline observations

The September 16, 2026 gate run showed:

- Python image preparation and build took about 47-116 seconds per affected job.
- The Python layer download itself was fast; extraction dominated.
- `procfs-memory` spent about 116 seconds in image preparation because of both
  the Python base and `build-base`.
- The standard and Linux-floor qcow2 artifacts were approximately 746MB and
  920MB respectively.
- Both VM profiles already set `GRUB_TIMEOUT=0` and
  `GRUB_RECORDFAIL_TIMEOUT=0`; there is no GRUB countdown to remove.
