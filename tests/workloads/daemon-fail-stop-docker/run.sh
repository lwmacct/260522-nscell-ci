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

__identity_value() {
  local _field="$1"

  sudo jq -r --arg _id "$_container_id" --arg _field "$_field" \
    '.entries[] | select(.containerId == $_id) | .[$_field]' \
    /var/lib/nscell/identity.json
}

__identity_entry_exists() {
	sudo jq -e --arg _id "$_container_id" '
		.version == 2 and any(.entries[]; .containerId == $_id)
	' /var/lib/nscell/identity.json >/dev/null
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

# A container created with docker leaves its snapshot outside the daemon epoch.
# The new epoch must reap it before accepting new work; there is no recovery
# prune path and no session reconstruction.
__assert_daemon_accepting() {
  local _deadline=$((SECONDS + 30))
  local _admission=""

  while ((SECONDS <= _deadline)); do
    _admission="$(sudo nscell daemon status 2>/dev/null | jq -r '.admission // empty' || true)"
    if [[ "$_admission" == "Accepting" ]]; then
      return 0
    fi
    sleep 0.5
  done

  echo "daemon did not return to accepting after the reap; admission=${_admission:-unknown}" >&2
  sudo nscell daemon status >&2 || true
  return 1
}

__main() {
  local _container_id _daemon_pid _new_lines _identity_start _identity_anchor

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

  __log "capturing the Docker overlay durable identity anchor"
  sudo jq -e '.version == 2' /var/lib/nscell/identity.json >/dev/null
  _identity_start="$(__identity_value start)"
  _identity_anchor="$(__identity_value storageAnchor)"
  [[ "$_identity_start" =~ ^[1-9][0-9]+$ && -n "$_identity_anchor" ]] || {
    echo "identity entry is invalid: start=${_identity_start:-empty} anchor=${_identity_anchor:-empty}" >&2
    return 1
  }
  sudo test -d "$_identity_anchor" || {
    echo "identity storage anchor is missing while Docker runs: $_identity_anchor" >&2
    return 1
  }
  sudo test -d "/var/lib/docker/rootfs/overlayfs/${_container_id}" || {
    echo "temporary Docker rootfs is missing while the container runs" >&2
    return 1
  }

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

  __log "asserting the stopped Docker definition keeps its subordinate identity"
  sudo test -d "$_identity_anchor" || {
    echo "storage anchor disappeared after Docker stop: $_identity_anchor" >&2
    return 1
  }
  [[ "$(__identity_value start)" == "$_identity_start" ]] || {
    echo "stopped container subordinate start changed" >&2
    return 1
  }
  [[ "$(__identity_value storageAnchor)" == "$_identity_anchor" ]] || {
    echo "stopped container storage anchor changed" >&2
    return 1
  }

  __log "asserting daemon restart collects the identity after Docker removal"
  docker rm -f "$_daemon_fail_stop_docker_name" >/dev/null
  sudo test ! -e "$_identity_anchor" || {
    echo "storage anchor survived Docker removal: $_identity_anchor" >&2
    return 1
  }
  __identity_entry_exists || {
    echo "identity was deleted before anchor garbage collection ran" >&2
    return 1
  }
  sudo systemctl restart nscell-daemon.service
  __assert_nscell_ready
  if __identity_entry_exists; then
    echo "deleted Docker container survived identity garbage collection" >&2
    return 1
  fi

  trap - EXIT
  __cleanup
  echo "daemon-fail-stop-docker-validation-ok"
}

__main "$@"
