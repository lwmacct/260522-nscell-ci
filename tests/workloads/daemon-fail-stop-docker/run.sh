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

# The OCI runtime's state root comes from whoever invokes it: docker goes
# through containerd's shim, which passes a root of its own. A container created
# that way therefore lives outside the daemon's default runtime root, and the
# startup reaper used to miss it - the daemon restarted healthy while the
# container kept running and unmanaged. This workload keeps that disagreement
# under test instead of relying on the daemon's configured root matching.
_shim_runtime_root="${NSCELL_CI_SHIM_RUNTIME_ROOT:-/var/run/docker/runtime-runc/moby}"
_runtime_root_hint_dir="${NSCELL_CI_RUNTIME_ROOT_HINT_DIR:-/run/nscell/runtime-roots}"
_daemon_log_offset=0

__cleanup() {
  sudo systemctl reset-failed nscell-daemon.service >/dev/null 2>&1 || true
  sudo systemctl start nscell-daemon.service >/dev/null 2>&1 || true
  docker rm -f "$_daemon_fail_stop_docker_name" >/dev/null 2>&1 || true
}

__daemon_pid() {
  systemctl show --property MainPID --value nscell-daemon.service
}

__wait_for_daemon_stop() {
  local _deadline=$((SECONDS + 20))

  while ((SECONDS <= _deadline)); do
    if ! systemctl is-active --quiet nscell-daemon.service; then
      return 0
    fi
    sleep 0.2
  done

  echo "daemon stayed active after SIGKILL" >&2
  return 1
}

__container_running() {
  docker inspect "$_daemon_fail_stop_docker_name" --format '{{.State.Running}}' 2>/dev/null |
    grep -Fxq true
}

__wait_for_container_stop() {
  local _deadline=$((SECONDS + 30))

  while ((SECONDS <= _deadline)); do
    if ! __container_running; then
      return 0
    fi
    sleep 0.5
  done

  echo "container ${_daemon_fail_stop_docker_name} survived the daemon restart" >&2
  return 1
}

# A container created with docker leaves its snapshot behind, so the daemon's
# recovery can finish on its own; if a run still ends up degraded, the
# documented operator path has to bring it back to accepting.
__assert_daemon_accepting() {
  local _deadline=$((SECONDS + 30))
  local _admission=""

  while ((SECONDS <= _deadline)); do
    _admission="$(sudo nscell daemon status 2>/dev/null | jq -r '.admission // empty' || true)"
    if [[ "$_admission" == "Accepting" ]]; then
      return 0
    fi
    if [[ "$_admission" == "Degraded" ]]; then
      sudo nscell daemon state prune >/dev/null 2>&1 || true
    fi
    sleep 0.5
  done

  echo "daemon did not return to accepting after the reap; admission=${_admission:-unknown}" >&2
  sudo nscell daemon status >&2 || true
  return 1
}

__main() {
  local _container_id _daemon_pid _new_lines

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd jq
  __require_cmd systemctl
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT

  docker rm -f "$_daemon_fail_stop_docker_name" >/dev/null 2>&1 || true
  __ensure_host_image "$_oci_base_image"

  __log "starting a container through docker, whose state root is the shim's"
  docker run -d \
    --name "$_daemon_fail_stop_docker_name" \
    --runtime nscell \
    "$_oci_base_image" \
    sleep 300 >/dev/null

  _container_id="$(docker inspect "$_daemon_fail_stop_docker_name" --format '{{.Id}}')"
  if [[ ! "$_container_id" =~ ^[0-9a-f]{64}$ ]]; then
    echo "docker container id is invalid: ${_container_id:-empty}" >&2
    return 1
  fi

  if sudo test -d "${_oci_runtime_root}/${_container_id}"; then
    echo "container state landed in the daemon's runtime root ${_oci_runtime_root}; this workload needs the disagreement" >&2
    return 1
  fi
  if ! sudo test -d "${_shim_runtime_root}/${_container_id}"; then
    echo "container state not found under the shim runtime root ${_shim_runtime_root}" >&2
    return 1
  fi
  if ! sudo test -d "$_runtime_root_hint_dir"; then
    echo "runtime did not record its state root under ${_runtime_root_hint_dir}" >&2
    return 1
  fi

  # The daemon log is root-owned, and a redirect would be performed by this
  # unprivileged shell, so read the line count through sudo itself.
  _daemon_log_offset="$(sudo wc -l "${_daemon_log}" | awk '{ print $1 }')"

  __log "killing the daemon without running its shutdown reconciliation"
  _daemon_pid="$(__daemon_pid)"
  if [[ ! "$_daemon_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "daemon main pid is unavailable: ${_daemon_pid:-empty}" >&2
    return 1
  fi
  sudo kill -9 "$_daemon_pid"
  __wait_for_daemon_stop

  sudo systemctl reset-failed nscell-daemon.service >/dev/null 2>&1 || true
  sudo systemctl start nscell-daemon.service
  systemctl is-active --quiet nscell-daemon.service

  __log "asserting the restart reaped the container it was never told about"
  _new_lines="$(sudo tail -n +"$((_daemon_log_offset + 1))" "${_daemon_log}")"
  if ! grep -Fq "stopping NSCell container ${_container_id:0:12}" <<<"${_new_lines}"; then
    echo "daemon did not reap the container left behind by the kill" >&2
    printf '%s\n' "${_new_lines}" | tail -20 >&2
    return 1
  fi

  __wait_for_container_stop
  if sudo test -d "${_shim_runtime_root}/${_container_id}"; then
    echo "runtime state survived the reap: ${_shim_runtime_root}/${_container_id}" >&2
    return 1
  fi
  if __container_running; then
    echo "container ${_daemon_fail_stop_docker_name} is still running after the reap" >&2
    return 1
  fi
  __assert_daemon_accepting

  trap - EXIT
  __cleanup
  echo "daemon-fail-stop-docker-validation-ok"
}

__main "$@"
