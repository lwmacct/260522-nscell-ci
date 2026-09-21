#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"
source "${_workload_dir}/library/oci.sh"

_bundle="${_volume_root}/oci-lifecycle/bundle"
_export_name="nscell-oci-export-${_workload_resource_id:-oci-lifecycle}"
_process_args='["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]'

__cleanup() {
  __remove_oci_container "$_oci_runtime_root" "$_oci_lifecycle_id"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__state() {
  sudo nscell --root "$_oci_runtime_root" state "${1:-$_oci_lifecycle_id}"
}

__assert_state() {
  local _expected="$1"

  __state | jq -e --arg _expected "$_expected" '.status == $_expected' >/dev/null
}

__wait_for_state() {
  local _expected="$1"
  local _id="${2:-$_oci_lifecycle_id}"
  local _deadline=$((SECONDS + 20))
  local _actual=""

  while ((SECONDS <= _deadline)); do
    _actual="$(__state "$_id" 2>/dev/null | jq -r '.status // empty' || true)"
    if [[ "$_actual" == "$_expected" ]]; then
      return 0
    fi
    sleep 0.2
  done

  echo "container ${_id} state did not become ${_expected}; last state: ${_actual:-unavailable}" >&2
  return 1
}

__main() {
  local _pid _process_cgroup _frozen_cgroup _exec_output _stats_output
  local _list_output

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd jq
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT

  __cleanup
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    "$_process_args" \
    "$_export_name"

  __log "validating OCI create and discovery state"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_oci_lifecycle_id"
  __assert_state created
  sudo nscell --root "$_oci_runtime_root" list --format json |
    jq -e --arg _id "$_oci_lifecycle_id" 'any(.[]; .id == $_id and .status == "created")' >/dev/null
  _pid="$(sudo cat "${_bundle}/init.pid")"
  sudo test -d "/proc/${_pid}"
  __container_capability_exists "$_oci_lifecycle_id"
  sudo findmnt -rn -T "/var/lib/nscellfs/${_oci_lifecycle_id}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'

  __log "validating start, exec, stats, pause, and resume"
  sudo nscell --root "$_oci_runtime_root" start "$_oci_lifecycle_id"
  __assert_state running
  _exec_output="$(sudo nscell --root "$_oci_runtime_root" exec \
    "$_oci_lifecycle_id" /bin/sh -c 'printf oci-exec-ok')"
  printf 'oci-exec-output=%q\n' "$_exec_output"
  if [[ "$_exec_output" != "oci-exec-ok" ]]; then
    echo "unexpected OCI exec output" >&2
    exit 1
  fi
  _stats_output="$(sudo nscell --root "$_oci_runtime_root" events --stats "$_oci_lifecycle_id")"
  printf 'oci-stats=%s\n' "$_stats_output"
  if ! jq -e --arg _id "$_oci_lifecycle_id" \
    '.type == "stats" and .id == $_id and .data.pids.current >= 1' \
    <<<"$_stats_output" >/dev/null; then
    echo "OCI stats did not report the running init process" >&2
    exit 1
  fi

  _process_cgroup="$(__host_cgroup_path "$_pid")"
  sudo test -f "${_process_cgroup}/cgroup.freeze"
  sudo nscell --root "$_oci_runtime_root" pause "$_oci_lifecycle_id"
  __assert_state paused
  if ! _frozen_cgroup="$(__find_ancestor_cgroup_with_value \
    "$_process_cgroup" cgroup.freeze 1)"; then
    echo "no frozen cgroup found for paused container from ${_process_cgroup}" >&2
    exit 1
  fi
  printf 'oci-frozen-cgroup=%s\n' "$_frozen_cgroup"
  sudo nscell --root "$_oci_runtime_root" resume "$_oci_lifecycle_id"
  __assert_state running
  if [[ "$(sudo cat "${_frozen_cgroup}/cgroup.freeze")" != "0" ]]; then
    echo "cgroup.freeze did not report a resumed cgroup" >&2
    exit 1
  fi
  if [[ "$(__state | jq -r '.pid')" != "$_pid" ]]; then
    echo "container init PID changed across pause and resume" >&2
    exit 1
  fi

  __log "validating stop and complete resource release"
  sudo nscell --root "$_oci_runtime_root" kill "$_oci_lifecycle_id" TERM
  __wait_for_state stopped
  sudo nscell --root "$_oci_runtime_root" delete "$_oci_lifecycle_id"
  if ! _list_output="$(sudo nscell --root "$_oci_runtime_root" list --format json)" ||
    ! jq -e 'type == "array"' <<<"${_list_output}" >/dev/null; then
    echo "OCI list --format json did not report a JSON array: ${_list_output}" >&2
    exit 1
  fi
  if jq -e --arg _id "$_oci_lifecycle_id" 'any(.[]; .id == $_id)' \
    <<<"${_list_output}" >/dev/null; then
    echo "deleted container remained in runtime list" >&2
    exit 1
  fi
  if __container_capability_exists "$_oci_lifecycle_id"; then
    echo "container capability survived OCI delete" >&2
    exit 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs | grep -F "/${_oci_lifecycle_id}"; then
    echo "VirtFS mount survived OCI delete" >&2
    exit 1
  fi

  trap - EXIT
  __cleanup
  echo "oci-lifecycle-validation-ok"
}

__main "$@"
