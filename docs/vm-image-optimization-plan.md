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
- Dry-run builds of both trimmed production profiles succeeded without
  publishing:
  [build run 35140713300](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35140713300).
  The standard and Linux-floor jobs completed in approximately 5m42s and 4m41s.

## Phase 2: experimental Python image preset

Status: **complete and promoted to `standard`**

The experiment used a temporary `standard-pycache` profile. Its build booted a
candidate VM, pulled the pinned Python digest into Docker, cleaned first-boot
state, and republished the already-unpacked disk. This intentionally avoided
storing only an OCI archive that would still need extraction on every boot.
After the measurements below, the behavior was promoted into `standard` and the
temporary profile was removed.

Validation:

- The warmed-image build and qcow2 validation succeeded:
  [dry run 35141389343](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35141389343).
- The warmed profile passed all five Python-based targets:
  [test run 35143078526](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35143078526).
- The same qcow2 then passed the complete 21-target VM gate:
  [gate run 35143574513](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35143574513).
- After promotion into `standard`, the final warmed standard artifact built and
  published successfully:
  [build run 35144286764](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35144286764).
  Its qcow2 is 676,790,784 bytes with immutable VM artifact digest
  `sha256:fb8a73b9957de072bb714d601749447c4fccd8fbef3d8d09a5c4bab40748d65c`.
- The merged `main` build also passed for both production profiles:
  [build run 35145068241](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35145068241).
  The current standard qcow2 is 676,659,712 bytes with immutable VM artifact
  digest `sha256:6470c3e3ccca6a4d1566a4ed2a3b3d74f2273e880815d1a0ed5e64f6cc57f39f`;
  the trimmed Linux-floor qcow2 is 795,617,792 bytes.
- The merged `main` static, standard smoke, and Linux-floor smoke checks passed:
  [check run 35145068726](https://github.com/lwmacct/260522-nscell-ci/actions/runs/35145068726).

Measurements:

- The phase-one standard disk was 631,234,048 bytes; the warmed disk was
  676,921,344 bytes, an increase of 45,687,296 bytes (7.2%).
- The warmed disk is still about 69.1MB smaller than the original 746MB
  production baseline because the compiler toolchain was removed.
- Across the five affected targets, Python image preparation fell from about
  234.8 seconds to 29.0 seconds, saving about 205.8 seconds of runner time.
- Python image build steps fell to roughly 2-4 seconds; `fuse-copy-file-range`
  still spends about 15 seconds exporting its Python rootfs into an OCI bundle.
- Compared with the prior 21-job standard gate, total job time fell from about
  3,511 seconds to 3,155 seconds (10.1%). The wall-clock critical path remained
  Docker-in-Docker, so gate wall time is bounded by that workload rather than
  Python image preparation.

The smoke BusyBox pull remains live, preserving real image-pull and extraction
coverage.

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
