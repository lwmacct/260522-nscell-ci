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

__cleanup() {
  docker rm -f "$_oci_tty_lifecycle_name" >/dev/null 2>&1 || true
}

__assert_running() {
  docker inspect "$_oci_tty_lifecycle_name" \
    --format '{{.State.Running}}' |
    grep -qx true
}

__wait_for_exited() {
  local _deadline=$((SECONDS + 20))
  local _state=""

  while ((SECONDS <= _deadline)); do
    _state="$(docker inspect "$_oci_tty_lifecycle_name" \
      --format '{{.State.Status}}' 2>/dev/null || true)"
    if [[ "$_state" == "exited" ]]; then
      return 0
    fi
    sleep 0.2
  done

  echo "TTY container did not stop; last state: ${_state:-unavailable}" >&2
  return 1
}

__wait_for_tty_output() {
  local _deadline=$((SECONDS + 10))

  while ((SECONDS <= _deadline)); do
    _tty_output="$(docker logs "$_oci_tty_lifecycle_name" 2>&1 || true)"
    if [[ "$_tty_output" == *"tty stdin=True stdout=True stderr=True"* ]]; then
      return 0
    fi
    sleep 0.2
  done

  echo "TTY output was not observed; last output: ${_tty_output:-unavailable}" >&2
  return 1
}

__main() {
  local _tty_output

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT
  __cleanup
  __ensure_host_image "$_oci_base_image"

  __log "starting a detached container with an NSCell-managed TTY"
  docker run -d \
    --name "$_oci_tty_lifecycle_name" \
    --runtime nscell \
    --tty \
    "$_oci_base_image" \
    python -c 'import os, time; print(f"tty stdin={os.isatty(0)} stdout={os.isatty(1)} stderr={os.isatty(2)}", flush=True); time.sleep(86400)' \
    >/dev/null
  __assert_running

  __wait_for_tty_output
  printf '%s\n' "$_tty_output"
  if [[ "$_tty_output" != *"tty stdin=True stdout=True stderr=True"* ]]; then
    echo "container stdio was not connected to the NSCell TTY" >&2
    exit 1
  fi
  if grep -Eq 'failed to close (post-start fd|tty fd)' <<<"$_tty_output"; then
    echo "TTY lifecycle emitted descriptor ownership warnings" >&2
    exit 1
  fi

  docker stop --timeout 10 "$_oci_tty_lifecycle_name" >/dev/null
  __wait_for_exited
  docker rm "$_oci_tty_lifecycle_name" >/dev/null
  __assert_nscell_ready

  trap - EXIT
  echo "oci-tty-lifecycle-validation-ok"
}

__main "$@"
