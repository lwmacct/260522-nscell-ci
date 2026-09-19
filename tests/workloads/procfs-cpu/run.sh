#!/usr/bin/env bash
# shellcheck disable=all

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"

__metric_value() {
  local _name="$1"

  curl -fsS http://127.0.0.1:9618/metrics |
    awk -v _metric="$_name" '$1 == _metric { print $2; found = 1 } END { exit !found }'
}

__main() {
  local _pressure_name="${_procfs_cpu_name}-pressure"
  local _opens_before _opens_after _registrations_before _registrations_after

  if [[ "${1:-}" == "cleanup" ]]; then
    __require_cmd docker
    docker rm -f "$_procfs_cpu_name" "${_procfs_cpu_name}-nolimit" "${_procfs_cpu_name}-idle-isolation" "$_pressure_name" >/dev/null 2>&1 || true
    return
  fi

  __require_cmd docker
  __assert_nscell_ready
  __init_ci_dirs
  _opens_before="$(__metric_value nscell_virtfs_passthrough_opens_total)"
  _registrations_before="$(__metric_value nscell_virtfs_passthrough_registrations_total)"

  docker rm -f "$_procfs_cpu_name" "${_procfs_cpu_name}-nolimit" "${_procfs_cpu_name}-idle-isolation" "$_pressure_name" >/dev/null 2>&1 || true
  __build_ci_image "$_procfs_cpu_image" "${_workload_dir}/workloads/procfs-cpu" --build-arg "BASE_IMAGE=${_procfs_cpu_base_image}"

  __log "running host-equivalent CPU presentation validation without CPU limits"
  docker run --rm \
    --name "${_procfs_cpu_name}-nolimit" \
    --hostname "${_procfs_cpu_name}-nolimit" \
    --runtime nscell \
    --cgroupns=private \
    -e "CI_PROCFS_CPU_EXPECT_VISIBLE_FROM_AFFINITY=1" \
    -e "CI_PROCFS_CPU_EXPECT_AFFINITY_MATCH=1" \
    "$_procfs_cpu_image"

  __log "running automatic CPU quota presentation validation"
  docker run --rm \
    --name "$_procfs_cpu_name" \
    --hostname "$_procfs_cpu_name" \
    --runtime nscell \
    --cgroupns=private \
    --cpus "$_procfs_cpu_quota_cpus" \
    -e "CI_PROCFS_CPU_EXPECT_VISIBLE=1" \
    -e "CI_PROCFS_CPU_EXPECT_AFFINITY_MATCH=1" \
    -e "CI_PROCFS_CPU_CHECK_USAGE=1" \
    "$_procfs_cpu_image"

  __log "running CPU idle isolation validation under host-side load"
  docker run -d \
    --name "$_pressure_name" \
    --hostname "$_pressure_name" \
    "$_procfs_cpu_image" \
    python3 -c 'while True: pass' >/dev/null
  local _idle_status=0
  docker run --rm \
    --name "${_procfs_cpu_name}-idle-isolation" \
    --hostname "${_procfs_cpu_name}-idle-isolation" \
    --runtime nscell \
    --cgroupns=private \
    --cpus "$_procfs_cpu_quota_cpus" \
    -e "CI_PROCFS_CPU_EXPECT_VISIBLE=1" \
    -e "CI_PROCFS_CPU_EXPECT_AFFINITY_MATCH=1" \
    -e "CI_PROCFS_CPU_CHECK_IDLE=1" \
    "$_procfs_cpu_image" || _idle_status=$?
  docker rm -f "$_pressure_name" >/dev/null 2>&1 || true
  if [[ "$_idle_status" -ne 0 ]]; then
    return "$_idle_status"
  fi

  _opens_after="$(__metric_value nscell_virtfs_passthrough_opens_total)"
  _registrations_after="$(__metric_value nscell_virtfs_passthrough_registrations_total)"
  (( _opens_after > _opens_before ))
  (( _registrations_after > _registrations_before ))
  [[ "$(__metric_value nscell_virtfs_passthrough_active_backings)" == 0 ]]
  [[ "$(__metric_value nscell_virtfs_passthrough_registration_failures_total)" == 0 ]]
  [[ "$(__metric_value nscell_virtfs_passthrough_close_failures_total)" == 0 ]]
  [[ "$(__metric_value nscell_virtfs_passthrough_unexpected_reads_total)" == 0 ]]
  sudo grep -q 'FUSE mount ready: .*passthrough=true stack_depth=1' "$_daemon_log"

  __assert_nscell_ready
  echo "procfs-cpu-validation-ok"
}

__main "$@"
