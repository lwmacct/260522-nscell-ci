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

_daemon_pid=""
_container_pid=""

__resume_daemon() {
  if [[ -n "$_daemon_pid" ]] && sudo test -d "/proc/${_daemon_pid}"; then
    sudo kill -CONT "$_daemon_pid" >/dev/null 2>&1 || true
  fi
  sudo systemctl reset-failed nscell-daemon.service >/dev/null 2>&1 || true
  sudo systemctl start nscell-daemon.service >/dev/null 2>&1 || true
}

__cleanup() {
  __resume_daemon
  docker rm -f "$_fuse_request_timeout_name" >/dev/null 2>&1 || true
}

__daemon_main_pid() {
  local _pid

  _pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ ]] || ! sudo test -d "/proc/${_pid}"; then
    echo "invalid nscell daemon MainPID: ${_pid:-empty}" >&2
    return 1
  fi
  printf '%s\n' "$_pid"
}

__wait_for_pid_exit() {
  local _pid="$1"
  local _deadline="$((SECONDS + 110))"

  while ((SECONDS <= _deadline)); do
    if ! sudo test -d "/proc/${_pid}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

__wait_for_docker_exit() {
  local _deadline="$((SECONDS + 30))"

  while ((SECONDS <= _deadline)); do
    if [[ "$(docker inspect "$_fuse_request_timeout_name" --format '{{.State.Status}}')" == "exited" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

__main() {
  local _exit_code _finished_at _mount_point _started_at
  local -a _mounts_after _mounts_before

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

  __cleanup
  __ensure_host_image "$_oci_base_image"
  mapfile -t _mounts_before < <(sudo findmnt -rn -t fuse,fuse.nscellfs -o TARGET)

  __log "starting a container whose first VirtFS read is delayed"
  docker run -d \
    --name "$_fuse_request_timeout_name" \
    --runtime nscell \
    "$_oci_base_image" \
    /bin/sh -c 'sleep 2; cat /proc/uptime >/dev/null' \
    >/dev/null

  _container_pid="$(docker inspect "$_fuse_request_timeout_name" --format '{{.State.Pid}}')"
  if [[ ! "$_container_pid" =~ ^[1-9][0-9]*$ ]] || ! sudo test -d "/proc/${_container_pid}"; then
    echo "FUSE timeout container did not start with a valid PID: ${_container_pid:-empty}" >&2
    exit 1
  fi

  mapfile -t _mounts_after < <(sudo findmnt -rn -t fuse,fuse.nscellfs -o TARGET)
  _mount_point="$(comm -13 \
    <(printf '%s\n' "${_mounts_before[@]}") \
    <(printf '%s\n' "${_mounts_after[@]}"))"
  if [[ -z "$_mount_point" || "$(printf '%s\n' "$_mount_point" | wc -l)" -ne 1 ]]; then
    echo "unable to identify the new FUSE mount for the timeout container" >&2
    sudo findmnt -rn -t fuse,fuse.nscellfs -o TARGET >&2
    exit 1
  fi

  for _ in $(seq 1 50); do
    if sudo grep -F "FUSE request timeout negotiated for ${_mount_point}" "$_daemon_log" >/dev/null; then
      break
    fi
    sleep 0.2
  done
  if ! sudo grep -F "FUSE request timeout negotiated for ${_mount_point}" "$_daemon_log" >/dev/null; then
    echo "kernel did not negotiate FUSE request timeout for ${_mount_point}" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi

  _started_at="$(date +%s)"
  _daemon_pid="$(__daemon_main_pid)"
  sudo kill -STOP "$_daemon_pid"

  __log "waiting for the kernel to abort the blocked VirtFS request"
  if ! __wait_for_pid_exit "$_container_pid"; then
    echo "container init survived the negotiated FUSE request timeout" >&2
    exit 1
  fi

  __resume_daemon
  __assert_nscell_ready
  if ! __wait_for_docker_exit; then
    echo "Docker did not observe the timed-out container exit" >&2
    exit 1
  fi

  _exit_code="$(docker inspect "$_fuse_request_timeout_name" --format '{{.State.ExitCode}}')"
  _finished_at="$(date +%s)"
  if [[ "$_exit_code" == "0" ]]; then
    echo "timed-out VirtFS read unexpectedly succeeded" >&2
    exit 1
  fi
  if ((_finished_at - _started_at < 55)); then
    echo "container exited before the FUSE request timeout could expire" >&2
    exit 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs | grep -F "${_mount_point}"; then
    echo "timed-out VirtFS mount survived server recovery" >&2
    exit 1
  fi
  if sudo grep -Eq 'panic|runtime error: invalid memory address' "$_daemon_log"; then
    echo "daemon log contains a crash after FUSE request timeout recovery" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi

  __assert_nscell_ready
  trap - EXIT
  __cleanup
  echo "fuse-request-timeout-validation-ok"
}

__main "$@"
