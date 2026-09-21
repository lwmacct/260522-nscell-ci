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

_container_name="nscell-drain-host-control${_workload_resource_id:+-${_workload_resource_id}}"

__cleanup() {
  sudo systemctl start nscell-daemon.service >/dev/null 2>&1 || true
  sudo nscell daemon resume >/dev/null 2>&1 || true
  docker rm -f "$_container_name" >/dev/null 2>&1 || true
}

__main() {
  local _docker_pid _daemon_pid _status
  if [[ "${1:-}" == cleanup ]]; then __cleanup; return; fi
  __require_cmd docker
  __require_cmd jq
  __require_cmd systemctl
  __assert_nscell_ready
  trap __cleanup EXIT

  __ensure_host_image "$_oci_base_image"
  docker run -d --name "$_container_name" --runtime runc "$_oci_base_image" sleep 300 >/dev/null
  _docker_pid="$(systemctl show --property MainPID --value docker.service)"
  _daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
  [[ "$_docker_pid" =~ ^[1-9][0-9]*$ && "$_daemon_pid" =~ ^[1-9][0-9]*$ ]]

  __log "quiescing and draining the empty NSCell epoch"
  _status="$(sudo nscell daemon drain --timeout 30s)"
  jq -e '.drained == true and .acceptingNewContainers == false and (.sessions | length) == 0' <<<"$_status" >/dev/null

  __log "switch boundary restarts only the NSCell daemon"
  sudo systemctl restart nscell-daemon.service
  __assert_nscell_ready
  [[ "$(systemctl show --property MainPID --value docker.service)" == "$_docker_pid" ]] || {
    echo "Docker MainPID changed during daemon-only switch" >&2
    return 1
  }
  [[ "$(systemctl show --property MainPID --value nscell-daemon.service)" != "$_daemon_pid" ]] || {
    echo "NSCell daemon MainPID did not change" >&2
    return 1
  }
  docker inspect "$_container_name" --format '{{.State.Running}}' | grep -Fxq true
  docker exec "$_container_name" true

  trap - EXIT
  __cleanup
  echo drain-and-switch-validation-ok
}

__main "$@"
