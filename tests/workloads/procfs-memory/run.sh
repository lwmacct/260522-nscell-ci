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

__main() {
  local _expected_memtotal_kib
  local _expected_swap_kib

  if [[ "${1:-}" == "cleanup" ]]; then
    __require_cmd docker
    docker rm -f "$_procfs_memory_name" "${_procfs_memory_name}-swap" >/dev/null 2>&1 || true
    return
  fi

  __require_cmd docker
  __assert_nscell_ready
  __init_ci_dirs

  _expected_memtotal_kib=$((_procfs_memory_memory_bytes / 1024))
  _expected_swap_kib=$(((_procfs_memory_swap_bytes - _procfs_memory_memory_bytes) / 1024))
  docker rm -f "$_procfs_memory_name" >/dev/null 2>&1 || true
  __build_ci_image "$_procfs_memory_image" "${_workload_dir}/workloads/procfs-memory" --build-arg "BASE_IMAGE=${_procfs_memory_base_image}"

  __log "running /proc/meminfo, sysinfo, and overflow validation"
  docker run --rm \
    --name "$_procfs_memory_name" \
    --hostname "$_procfs_memory_name" \
    --runtime nscell \
    --cgroupns=private \
    --memory "$_procfs_memory_memory_bytes" \
    --memory-swap "$_procfs_memory_memory_bytes" \
    -e "CI_PROCFS_MEMORY_EXPECT_MEMTOTAL_KIB=${_expected_memtotal_kib}" \
    -e "CI_PROCFS_MEMORY_EXPECT_SWAPTOTAL_KIB=0" \
    -e "CI_PROCFS_MEMORY_OVERFLOW_ALLOC_BYTES=${_procfs_memory_overflow_alloc_bytes}" \
    "$_procfs_memory_image"

  __log "running /proc/swaps synthetic entry validation"
  docker run --rm \
    --name "${_procfs_memory_name}-swap" \
    --hostname "${_procfs_memory_name}-swap" \
    --runtime nscell \
    --cgroupns=private \
    --memory "$_procfs_memory_memory_bytes" \
    --memory-swap "$_procfs_memory_swap_bytes" \
    -e "CI_PROCFS_MEMORY_EXPECT_MEMTOTAL_KIB=${_expected_memtotal_kib}" \
    -e "CI_PROCFS_MEMORY_EXPECT_SWAPTOTAL_KIB=${_expected_swap_kib}" \
    -e "CI_PROCFS_MEMORY_OVERFLOW_ALLOC_BYTES=${_procfs_memory_overflow_alloc_bytes}" \
    -e "CI_PROCFS_MEMORY_EXERCISE_SWAP=1" \
    -e "CI_PROCFS_MEMORY_EXERCISE_ALLOC_BYTES=${_procfs_memory_swap_exercise_alloc_bytes}" \
    -e "CI_PROCFS_MEMORY_SKIP_OVERFLOW=1" \
    "$_procfs_memory_image"

  __assert_nscell_ready
  echo "procfs-memory-validation-ok"
}

__main "$@"
