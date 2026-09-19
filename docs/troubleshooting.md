# Runtime CI troubleshooting

This page triages failures of the disposable VM runtime validation owned by
this repository. Product deployment, host contract requirements, daemon
recovery, and source-level debugging are owned by the
[NSCell repository](https://github.com/lwmacct/260522-nscell); see its
[deployment skill](https://github.com/lwmacct/260522-nscell/blob/main/.agents/skills/repo-deployment/SKILL.md)
and
[development skill](https://github.com/lwmacct/260522-nscell/blob/main/.agents/skills/repo-development/SKILL.md).

## Start from the failed matrix job

1. Open the failed matrix job log and identify whether deployment, readiness,
   or the workload step failed.
2. Download the VM diagnostics artifact. It contains the guest daemon log,
   systemd/Docker diagnostics, and the relevant `/data/nscell` logs.
3. `Test workloads in VM` runs deployment and readiness checks before the
   matrix jobs execute the selected workloads. A readiness failure must be
   fixed before investigating individual workload failures.

## Readiness failures

The setup step checks that:

- `nscell-daemon.service` is active.
- the daemon log contains `Ready ...`.
- the daemon log has no missing idmapped mount or overlayfs-on-idmapped-mount
  errors.

On failure, `tests/library/diagnostics.sh` prints service status, journal
output, and daemon log tails directly into the job log. Host contract details
such as the Linux 7.0 baseline, cgroup v2, `/dev/fuse`, FUSE passthrough, and
BPF LSM requirements are documented in the NSCell repository deployment guide.

## Failed initialization leaves a degraded daemon

If the first smoke run or workload fails during container creation, the daemon
may later report:

```text
daemon degraded: startup reconciliation failed
```

Preserve the guest daemon log, systemd journal, and Docker status first. The
validation guests are disposable, so the preferred recovery is to re-run the
target on a fresh VM. A manual reset is only acceptable inside an interactive
debug VM after confirming that no NSCell workload or state must be preserved:

```bash
docker ps -aq --filter name='^nscell-' | xargs -r docker rm -f
systemctl stop nscell-daemon.service
rm -rf /var/lib/nscell/state /var/lib/nscell/work /run/nscell/runtime /run/nscell/runtime-roots
systemctl start nscell-daemon.service
```

Never run this cleanup on a host with active workloads or state that must be
kept; production upgrades follow the drain and rollback procedure in the
NSCell repository deployment guide.

## Reproduce one workload

Use `Test workloads in VM` with explicit `targets` to reproduce
`docker-in-docker`, `kubernetes-k3s`, `systemd-pid1`, `procfs-memory`, or
`procfs-cpu` in an isolated guest. The target catalog is
`tests/manifest.json`, workflow inputs are documented in
[runtime-tests.md](runtime-tests.md), and workload defaults live in
`tests/library/env.sh`.

### kubernetes-k3s

Confirm that setup completed successfully before running this target. Then
check, in order:

- `docker.service` is running.
- workload image building succeeded; inspect `tests/library/images.sh` output
  and the Docker image list.
- the k3s container started; inspect NSCell and Docker container logs.
- the inner pod started; inspect k3s status and workload logs inside the k3s
  container.

This repository does not cover installing NSCell into an existing Kubernetes
cluster.

## Hand product failures back

`kernel-capability-smoke` independently checks the full Linux 7 ABI set and
helps distinguish host or distribution differences from product regressions.
When the evidence points to NSCell itself, move the investigation to the
NSCell repository together with the matrix job log and diagnostics artifact;
its development guide maps resource-view and mount-path failures to source
packages and targeted tests.
