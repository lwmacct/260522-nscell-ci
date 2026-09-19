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

_probe_container_path="/tmp/io_uring_probe.py"
_probe_host_path=""

__cleanup() {
  docker rm -f \
    "${_io_uring_policy_name}-exec" \
    "${_io_uring_policy_name}-init" >/dev/null 2>&1 || true
  if [[ -n "$_probe_host_path" ]]; then
    rm -f "$_probe_host_path"
  fi
}

__copy_probe() {
  local _container="$1"

  docker cp "$_probe_host_path" "${_container}:${_probe_container_path}"
}

__assert_admitted_set() {
  local _json="$1"

  jq -e '.setup == "ok"' <<<"${_json}" >/dev/null || {
    echo "io_uring_setup did not succeed inside the container: ${_json}" >&2
    return 1
  }
  jq -e '[.opcodes.NOP, .opcodes.READ, .opcodes.WRITE, .opcodes.FSYNC] | all(. == "admitted")' \
    <<<"${_json}" >/dev/null || {
    echo "an allowed opcode was refused: ${_json}" >&2
    return 1
  }
  # The event-loop family is what makes the ring usable by an async runtime, so
  # the policy has to admit these as well - and the poll/timeout pair is driven
  # for real below, because being admitted is not the same as completing.
  jq -e '[.opcodes.POLL_ADD, .opcodes.POLL_REMOVE, .opcodes.TIMEOUT,
    .opcodes.TIMEOUT_REMOVE, .opcodes.LINK_TIMEOUT] | all(. == "admitted")' \
    <<<"${_json}" >/dev/null || {
    echo "an event-loop opcode was refused: ${_json}" >&2
    return 1
  }
}

__assert_refused_set() {
  local _json="$1"

  # The ring must not reach an operation whose syscall form is trapped, and the
  # task must not be able to widen the restriction it inherited.
  jq -e '[.opcodes.OPENAT2, .opcodes.SETXATTR, .opcodes.URING_CMD] | all(. == "denied")' \
    <<<"${_json}" >/dev/null || {
    echo "a trapped-form opcode was admitted: ${_json}" >&2
    return 1
  }
  jq -e '.register | startswith("refused")' <<<"${_json}" >/dev/null || {
    echo "a container could register its own io_uring restriction: ${_json}" >&2
    return 1
  }
}

__main() {
  local _exec_json _init_json

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
  __ensure_host_image "$_oci_base_image"
  _probe_host_path="${_volume_root}/io_uring-policy/probe.py"
  install -d -m 0755 "$(dirname "$_probe_host_path")"
  install -m 0644 "${_workload_path}/probe.py" "$_probe_host_path"

  __log "probing the container policy through docker exec (the setns init path)"
  docker run -d \
    --name "${_io_uring_policy_name}-exec" \
    --runtime nscell \
    "$_oci_base_image" \
    sleep 120 >/dev/null
  __copy_probe "${_io_uring_policy_name}-exec"
  _exec_json="$(docker exec "${_io_uring_policy_name}-exec" python3 "$_probe_container_path" matrix)"
  __assert_admitted_set "$_exec_json"
  __assert_refused_set "$_exec_json"

  __log "driving a real poll and timeout through the ring"
  _event_json="$(
    docker exec "${_io_uring_policy_name}-exec" python3 "$_probe_container_path" eventloop
  )"
  printf 'io-uring-eventloop=%s\n' "$_event_json"
  jq -e '.poll == "pollin" and .timeout == "etime"' <<<"${_event_json}" >/dev/null || {
    echo "the ring could not drive an event loop: ${_event_json}" >&2
    return 1
  }

  __log "probing the container policy with the probe as the container init"
  docker create \
    --name "${_io_uring_policy_name}-init" \
    --runtime nscell \
    "$_oci_base_image" \
    python3 "$_probe_container_path" matrix >/dev/null
  __copy_probe "${_io_uring_policy_name}-init"
  _init_json="$(docker start -a "${_io_uring_policy_name}-init")"
  __assert_admitted_set "$_init_json"
  __assert_refused_set "$_init_json"

  trap - EXIT
  __cleanup
  echo "io-uring-policy-validation-ok"
}

__main "$@"
