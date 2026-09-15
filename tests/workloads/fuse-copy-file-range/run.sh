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

_copy_path="/proc/sys/kernel/printk"

__cleanup() {
  docker rm -f "$_fuse_copy_file_range_name" >/dev/null 2>&1 || true
}

__wait_for_container_exit() {
  local _deadline="$((SECONDS + 60))"

  while ((SECONDS <= _deadline)); do
    if [[ "$(docker inspect "$_fuse_copy_file_range_name" --format '{{.State.Status}}')" == "exited" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

__main() {
  local _exit_code _output

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
  __ensure_host_image "$_container_security_policy_base_image"

  __log "issuing copy_file_range over VirtFS"
  docker run -d \
    --name "$_fuse_copy_file_range_name" \
    --runtime nscell \
    --label io.backend.security.profile=default \
    "$_container_security_policy_base_image" \
    python3 -c \
    'import os; p="'"$_copy_path"'"; before=open(p,"rb").read(); src=os.open(p,os.O_RDONLY|os.O_CLOEXEC); dst=os.open(p,os.O_WRONLY|os.O_CLOEXEC); count=os.copy_file_range(src,dst,len(before),0,0); after=open(p,"rb").read(); assert count==len(before); assert after==before; print("fuse-copy-file-range-ok",count,sep=":")' \
    >/dev/null

  if ! __wait_for_container_exit; then
    echo "copy_file_range container did not exit" >&2
    exit 1
  fi
  _exit_code="$(docker inspect "$_fuse_copy_file_range_name" --format '{{.State.ExitCode}}')"
  _output="$(docker logs "$_fuse_copy_file_range_name" 2>&1)"
  printf 'copy-file-range-output=%q\n' "$_output"
  if [[ "$_exit_code" != "0" || "$_output" != fuse-copy-file-range-ok:* ]]; then
    echo "copy_file_range workload failed with exit code ${_exit_code}" >&2
    exit 1
  fi
  if ! sudo grep -F "FUSE copy_file_range handled from ${_copy_path} to ${_copy_path}" "$_daemon_log" >/dev/null; then
    echo "daemon did not record the VirtFS copy_file_range operation" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi
  if sudo grep -Eq 'panic|runtime error: invalid memory address' "$_daemon_log"; then
    echo "daemon log contains a crash after copy_file_range" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi

  __assert_nscell_ready
  trap - EXIT
  __cleanup
  echo "fuse-copy-file-range-validation-ok"
}

__main "$@"
