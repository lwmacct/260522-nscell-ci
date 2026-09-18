# Workload suite taxonomy plan

Status: approved 2026-09-18. Implementation and public validation follow this
document; the plan is retired once the suites are live.

## Problem

Suite membership is hand written per target, so it drifts and does not express
what each target actually validates:

- `suite=smoke` lists five targets, but the selector rewrites it to the single
  `smoke` probe, so four of those memberships are dead;
- `gate` and `full` differ by two targets, so `gate` means "everything except
  the experiment" instead of a defined contract;
- real nested runtimes (`docker-in-docker`, `kubernetes-k3s`, `systemd-pid1`)
  share one flat list with synthetic-payload contract checks, so there is no way
  to run only the runtime layer or only the fast contract layer.

## Decision

Every target declares exactly one `class`. Suites are class compositions, not
hand-maintained member lists.

| Class | Meaning | Targets |
| --- | --- | --- |
| `preflight` | VM and NSCell liveness | `smoke` |
| `contract` | Linux 7 host contract | `kernel-capability-smoke` |
| `policy` | security mediation and deny paths | `container-security-policy`, `new-mount-api-deny`, `seccomp-notify-concurrency` |
| `semantics` | NSCell API and component behavior | OCI, FUSE, storage, recovery, cgroup, procfs, netns, and daemon targets |
| `runtime` | real nested runtimes end to end | `docker-in-docker`, `kubernetes-k3s`, `systemd-pid1` |
| `experiment` | non-blocking probes, never in a suite | `fuse-io-uring-probe` |

| Suite | Classes | Bundled budget |
| --- | --- | --- |
| `smoke` | preflight | 1 group, 1 target, 5m |
| `quick` | contract + policy + semantics | 11 groups, 19 targets, 68m |
| `runtime` | runtime | 3 groups, 3 targets, 28m |
| `gate` | quick + runtime | 14 groups, 22 targets, 96m |

`gate` stays the release gate required by ADR-031 and ADR-033: Linux 7 ABI, OCI
lifecycle, storage, recovery, cgroup, mount, seccomp, BPF, systemd, nested
runtime, and Kubernetes coverage. `full` is removed. Its extra coverage either
enters `gate` (`resource-update`, the only live cgroup-update check, named by
ADR-031's cgroup coverage) or becomes explicit-only (`fuse-io-uring-probe`,
an experiment). Experiment targets require an explicit `targets=` selection.

## Migration

1. `tests/manifest.json`: `schema_version: 2`; `modes.vm.class` replaces
   `modes.vm.suites`.
2. `tests/manifest.sh`: resolve suites from classes, drop the `suite=smoke`
   special case, and reject `suites`, unknown classes, and unknown suites.
3. `.github/scripts/check.sh`: assert the composition invariants
   `gate = quick + runtime`, `quick ∩ runtime = ∅`, and that the only targets
   outside every suite are the experiment ones.
4. `.github/workflows/test-vm.yml`: suite choices become
   `smoke|quick|runtime|gate`.
5. NSCell release workflow: suite choices become
   `none|smoke|quick|runtime|gate`; release tags keep running `gate`.
6. Documentation and ADR-031 wording: the release gate is the `gate` suite
   composed of the class lists above.

## Verification

- `tests/manifest.sh select vm <suite>` for every suite in both groupings, plus
  the composition invariants enforced by `check.sh`.
- One public dispatch for `quick` and one for `runtime`, then a `gate`
  dispatch from the NSCell release workflow.
