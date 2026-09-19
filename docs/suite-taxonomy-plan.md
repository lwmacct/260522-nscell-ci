# Workload suite taxonomy plan

Status: implemented and retired. The class composition, the suite selector and
the bundled-group rule this plan argued for are live in `tests/manifest.json`
and `tests/manifest.sh`; the current numbers and the target catalog are in
[runtime-tests.md](runtime-tests.md). What follows is the record of why the
taxonomy looks the way it does, not a description of pending work.

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

The class names, the suite compositions and each target's class live in
`tests/manifest.json`; per-suite group, target and budget numbers are kept in
[runtime-tests.md](runtime-tests.md) so there is one place to read them.

`gate` stays the release gate the product deployment path requires (the public
Ubuntu 26.04 standard VM profile; see the NSCell repository's deployment skill):
Linux 7 ABI, OCI lifecycle, storage, recovery, cgroup, mount, seccomp, BPF,
systemd, nested runtime, and Kubernetes coverage. `full` is removed. Its extra
coverage either enters `gate` (`resource-update`, the only live cgroup-update
check) or becomes explicit-only (`fuse-io-uring-probe`, an experiment).
Experiment targets require an explicit `targets=` selection.

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
6. Documentation wording: the release gate is the `gate` suite
   composed of the class lists above.

## Verification

- `tests/manifest.sh select vm <suite>` for every suite in both groupings, plus
  the composition invariants enforced by `check.sh`.
- One public dispatch for `quick` and one for `runtime`, then a `gate`
  dispatch from the NSCell release workflow.
