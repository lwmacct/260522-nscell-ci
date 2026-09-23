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

_bundle="${_volume_root}/daemon-fail-stop/bundle"
_export_name="nscell-oci-export-${_workload_resource_id:-daemon-fail-stop}"

__restore_daemon() {
  sudo systemctl start nscell-daemon.service >/dev/null 2>&1 || true
  __remove_oci_container "$_oci_runtime_root" "$_daemon_fail_stop_id"
  __remove_oci_container "$_oci_runtime_root" "${_daemon_fail_stop_id}-fresh"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__wait_for_process_exit() {
  local _pid="$1"
  local _deadline=$((SECONDS + 20))

  while ((SECONDS <= _deadline)); do
    if ! sudo test -d "/proc/${_pid}"; then
      return 0
    fi
    sleep 0.2
  done
  echo "container init process ${_pid} survived daemon shutdown" >&2
  return 1
}

__main() {
  local _pid

  if [[ "${1:-}" == "cleanup" ]]; then
    __restore_daemon
    return
  fi

  __require_cmd docker
  __require_cmd jq
  __require_cmd systemctl
  __assert_nscell_ready
  __init_ci_dirs
  trap __restore_daemon EXIT

  __remove_oci_container "$_oci_runtime_root" "$_daemon_fail_stop_id"
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' \
    "$_export_name"

  __log "creating an active OCI container in the daemon-owned runtime root"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_daemon_fail_stop_id"
  sudo nscell --root "$_oci_runtime_root" start "$_daemon_fail_stop_id"
  sudo nscell --root "$_oci_runtime_root" state "$_daemon_fail_stop_id" |
    jq -e '.status == "running" and .pid > 0' >/dev/null
  _pid="$(sudo cat "${_bundle}/init.pid")"
  sudo test -d "/proc/${_pid}"
  __container_capability_exists "$_daemon_fail_stop_id"
  sudo findmnt -rn -T "/var/lib/nscell/virtfs/${_daemon_fail_stop_id}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'

  __log "stopping daemon and verifying the fail-stop contract"
  sudo systemctl stop nscell-daemon.service
  if systemctl is-active --quiet nscell-daemon.service; then
    echo "daemon remained active after systemctl stop" >&2
    exit 1
  fi
  __wait_for_process_exit "$_pid"
  if sudo test -e "${_oci_runtime_root}/${_daemon_fail_stop_id}"; then
    echo "runtime state survived daemon shutdown: ${_oci_runtime_root}/${_daemon_fail_stop_id}" >&2
    exit 1
  fi
  if __container_capability_exists "$_daemon_fail_stop_id"; then
    echo "container capability survived daemon shutdown" >&2
    exit 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs | grep -F "/${_daemon_fail_stop_id}"; then
    echo "VirtFS mount survived daemon shutdown" >&2
    exit 1
  fi

  __log "restarting daemon and validating a fresh container"
  sudo systemctl start nscell-daemon.service
  __assert_nscell_ready
  sudo nscell daemon gate status | jq -e '.registeredContainers == 0' >/dev/null
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' \
    "$_export_name"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    "${_daemon_fail_stop_id}-fresh"
  sudo nscell --root "$_oci_runtime_root" start "${_daemon_fail_stop_id}-fresh"
  sudo nscell --root "$_oci_runtime_root" state "${_daemon_fail_stop_id}-fresh" |
    jq -e '.status == "running" and .pid > 0' >/dev/null
  __remove_oci_container "$_oci_runtime_root" "${_daemon_fail_stop_id}-fresh"

  trap - EXIT
  __restore_daemon
  echo "daemon-fail-stop-validation-ok"
}

__main "$@"
