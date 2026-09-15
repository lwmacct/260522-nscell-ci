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

_bundle="${_volume_root}/daemon-dial-retry/bundle"
_create_log="${_log_root}/daemon-dial-retry-create.log"
_export_name="nscell-oci-export-${_workload_resource_id:-daemon-dial-retry}"

__restore_daemon() {
  sudo systemctl start nscell-daemon.service >/dev/null 2>&1 || true
  __remove_oci_container "$_oci_runtime_root" "$_daemon_dial_retry_id"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__main() {
  local _create_pid _daemon_start_pid _deadline
  local _started_seconds _elapsed_seconds

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

  __remove_oci_container "$_oci_runtime_root" "$_daemon_dial_retry_id"
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    '["/bin/true"]' \
    "$_export_name"

  __log "stopping an idle daemon before issuing an OCI create request"
  sudo systemctl stop nscell-daemon.service
  if systemctl is-active --quiet nscell-daemon.service; then
    echo "daemon remained active after systemctl stop" >&2
    exit 1
  fi
  _started_seconds=$SECONDS
  # shellcheck disable=SC2024 # The workload log directory is owned by the caller.
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    "$_daemon_dial_retry_id" >"$_create_log" 2>&1 &
  _create_pid=$!
  sleep 1
  if ! kill -0 "$_create_pid" >/dev/null 2>&1; then
    wait "$_create_pid" || true
    echo "OCI create did not wait for the daemon retry window" >&2
    cat "$_create_log" >&2
    exit 1
  fi

  __log "restoring daemon while the OCI create request remains pending"
  sudo systemctl start nscell-daemon.service &
  _daemon_start_pid=$!
  _deadline=$((SECONDS + 30))
  while kill -0 "$_create_pid" >/dev/null 2>&1 && ((SECONDS <= _deadline)); do
    sleep 0.2
  done
  if kill -0 "$_create_pid" >/dev/null 2>&1; then
    echo "OCI create did not finish within 30 seconds after daemon recovery" >&2
    kill "$_create_pid" >/dev/null 2>&1 || true
    wait "$_create_pid" || true
    wait "$_daemon_start_pid" || true
    cat "$_create_log" >&2
    exit 1
  fi
  if ! wait "$_create_pid"; then
    wait "$_daemon_start_pid" || true
    echo "OCI create failed after daemon recovery" >&2
    cat "$_create_log" >&2
    exit 1
  fi
  _elapsed_seconds=$((SECONDS - _started_seconds))
  if ! wait "$_daemon_start_pid"; then
    echo "nscell daemon failed to start during OCI create retry" >&2
    exit 1
  fi
  if ((_elapsed_seconds < 1)); then
    echo "OCI create completed before exercising daemon dial retry: ${_elapsed_seconds}s" >&2
    exit 1
  fi

  sudo nscell --root "$_oci_runtime_root" state "$_daemon_dial_retry_id" |
    jq -e '.status == "created" and .pid > 0' >/dev/null
  sudo nscell --root "$_oci_runtime_root" delete --force "$_daemon_dial_retry_id"
  __assert_nscell_ready

  trap - EXIT
  __restore_daemon
  echo "daemon-dial-retry-validation-ok elapsed=${_elapsed_seconds}s"
}

__main "$@"
