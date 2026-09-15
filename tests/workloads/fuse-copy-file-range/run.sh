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

_bundle="${_volume_root}/fuse-copy-file-range/bundle"
_export_name="nscell-oci-export-${_workload_resource_id:-fuse-copy-file-range}"
_fuse_copy_path="/var/lib/nscellfs/${_fuse_copy_file_range_name}/proc/sys/kernel/printk"
_virtfs_copy_path="/proc/sys/kernel/printk"

__cleanup() {
  __remove_oci_container "$_oci_runtime_root" "$_fuse_copy_file_range_name"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__run_copy_probe() {
  sudo python3 - "$_fuse_copy_path" <<'PY'
import os
import sys

path = sys.argv[1]
before = open(path, "rb").read()
source = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
destination = os.open(path, os.O_WRONLY | os.O_CLOEXEC)
count = os.copy_file_range(source, destination, len(before), 0, 0)
after = open(path, "rb").read()
assert count == len(before)
assert after == before
print(f"fuse-copy-file-range-ok:{count}")
PY
}

__main() {
  local _output

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd python3
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT

  __cleanup
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    '["/bin/sh", "-c", "cat /proc/sys/kernel/printk >/dev/null; sleep 60"]' \
    "$_export_name"

  __log "creating the VirtFS mount for copy_file_range"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_fuse_copy_file_range_name"
  sudo findmnt -rn -T "/var/lib/nscellfs/${_fuse_copy_file_range_name}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'
  sudo nscell --root "$_oci_runtime_root" start "$_fuse_copy_file_range_name"
  sudo nscell --root "$_oci_runtime_root" state "$_fuse_copy_file_range_name" |
    jq -e '.status == "running" and .pid > 0' >/dev/null

  __log "issuing copy_file_range over VirtFS"
  if ! _output="$(__run_copy_probe)"; then
    echo "copy_file_range probe failed" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi
  printf 'copy-file-range-output=%q\n' "$_output"
  if [[ "$_output" != fuse-copy-file-range-ok:* ]]; then
    echo "copy_file_range returned an unexpected result" >&2
    exit 1
  fi
  if ! sudo grep -F "FUSE copy_file_range handled from ${_virtfs_copy_path} to ${_virtfs_copy_path}" "$_daemon_log" >/dev/null; then
    echo "daemon did not record the VirtFS copy_file_range operation" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi
  if sudo grep -Eq 'panic|runtime error: invalid memory address' "$_daemon_log"; then
    echo "daemon log contains a crash after copy_file_range" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi

  sudo nscell --root "$_oci_runtime_root" delete "$_fuse_copy_file_range_name"
  if sudo findmnt -rn -t fuse,fuse.nscellfs |
    grep -F "/${_fuse_copy_file_range_name}"; then
    echo "VirtFS mount survived copy_file_range container deletion" >&2
    exit 1
  fi
  __assert_nscell_ready

  trap - EXIT
  __cleanup
  echo "fuse-copy-file-range-validation-ok"
}

__main "$@"
