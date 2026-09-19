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
_leak_bundle="${_volume_root}/oci-lifecycle/leak-bundle"
_export_name="nscell-oci-export-${_workload_resource_id:-oci-lifecycle}"
_process_args='["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]'
_holder_pgid=""

__cleanup() {
  if [[ -n "$_holder_pgid" ]]; then
    sudo kill -- "-${_holder_pgid}" >/dev/null 2>&1 || true
    _holder_pgid=""
  fi
  __remove_oci_container "$_oci_runtime_root" "$_oci_lifecycle_id"
  __remove_oci_container "$_oci_runtime_root" "${_oci_lifecycle_id}-leak"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
  __remove_oci_bundle "$_leak_bundle"
}

__daemon_log_offset() {
  sudo wc -l "${_daemon_log}" | awk '{ print $1 }'
}

__wait_for_new_log_line() {
  local _offset="$1"
  local _pattern="$2"
  local _deadline=$((SECONDS + 20))

  while ((SECONDS <= _deadline)); do
    if sudo tail -n +"$((_offset + 1))" "${_daemon_log}" | grep -qF "${_pattern}"; then
      return 0
    fi
    sleep 0.2
  done

  return 1
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
  local _list_output _leak_pid _daemon_log_offset

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
  _daemon_log_offset="$(__daemon_log_offset)"
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

  # A finished removal has to be visible as such: the daemon observes the
  # container's user namespace and reports that nothing is left. Without that,
  # "cleanup happened" is only assumed. For a raw OCI container the removal
  # signal is its rootfs going away - the daemon watches it and only then
  # finalizes the retained lease - so this workload, which owns the bundle,
  # removes the rootfs and requires the report that follows.
  __log "validating that the daemon observed the namespace teardown"
  sudo rm -rf "$_bundle"
  if ! __wait_for_new_log_line "$_daemon_log_offset" \
    'teardown observed: its user namespace owns no active namespace'; then
    echo "daemon did not observe the container's namespace teardown" >&2
    sudo tail -n +"$((_daemon_log_offset + 1))" "${_daemon_log}" | tail -20 >&2
    exit 1
  fi
  if sudo tail -n +"$((_daemon_log_offset + 1))" "${_daemon_log}" | grep -qF 'still owns'; then
    echo "daemon reported leftover namespaces after a clean removal" >&2
    exit 1
  fi

  # The other side of the same observation: a namespace that outlives its
  # container must be reported instead of assumed away. A holder on the host
  # keeps one of the container's namespaces alive, so the same removal path has
  # to warn instead of reporting a clean teardown.
  __log "validating that a namespace outliving its container is reported"
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_leak_bundle" \
    "$_process_args" \
    "$_export_name"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_leak_bundle" \
    --pid-file "${_leak_bundle}/init.pid" \
    "${_oci_lifecycle_id}-leak"
  sudo nscell --root "$_oci_runtime_root" start "${_oci_lifecycle_id}-leak"
  _leak_pid="$(sudo cat "${_leak_bundle}/init.pid")"
  # setsid gives the holder its own process group, so the whole holder can be
  # taken down with one signal and the workload cannot leave it behind.
  sudo setsid sh -c "exec 3</proc/${_leak_pid}/ns/net; sleep 60" >/dev/null 2>&1 &
  _holder_pgid=$!
  sleep 1

  _daemon_log_offset="$(__daemon_log_offset)"
  sudo nscell --root "$_oci_runtime_root" kill "${_oci_lifecycle_id}-leak" TERM
  __wait_for_state stopped "${_oci_lifecycle_id}-leak"
  sudo nscell --root "$_oci_runtime_root" delete "${_oci_lifecycle_id}-leak"
  sudo rm -rf "$_leak_bundle"
  if ! __wait_for_new_log_line "$_daemon_log_offset" 'still owns'; then
    echo "daemon did not report the namespace that outlived its container" >&2
    sudo tail -n +"$((_daemon_log_offset + 1))" "${_daemon_log}" | tail -20 >&2
    exit 1
  fi
  sudo kill -- "-${_holder_pgid}" >/dev/null 2>&1 || true
  _holder_pgid=""

  trap - EXIT
  __cleanup
  echo "oci-lifecycle-validation-ok"
}

__main "$@"
