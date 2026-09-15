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
_copy_path="/proc/sys/kernel/printk"
_copy_program='
import os

path = "/proc/sys/kernel/printk"
before = open(path, "rb").read()
source = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
destination = os.open(path, os.O_WRONLY | os.O_CLOEXEC)
count = os.copy_file_range(source, destination, len(before), 0, 0)
after = open(path, "rb").read()
assert count == len(before)
assert after == before
with open("/result", "w", encoding="ascii") as result:
    result.write(f"fuse-copy-file-range-ok:{count}")
'
_copy_program_with_diagnostics='
import os

path = "/proc/sys/kernel/printk"
try:
    before = open(path, "rb").read()
    source = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    destination = os.open(path, os.O_WRONLY | os.O_CLOEXEC)
    count = os.copy_file_range(source, destination, len(before), 0, 0)
    after = open(path, "rb").read()
    assert count == len(before)
    assert after == before
    output = f"fuse-copy-file-range-ok:{count}"
except OSError as error:
    stat = os.stat(path)
    output = (
        f"copy-error:{error.errno}:uids={os.getuid()}:{os.geteuid()}:"
        f"stat={stat.st_mode:o}:{stat.st_uid}:{stat.st_gid}"
    )
with open("/result", "w", encoding="ascii") as result:
    result.write(output)
'

__cleanup() {
  __remove_oci_container "$_oci_runtime_root" "$_fuse_copy_file_range_name"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__state() {
  sudo nscell --root "$_oci_runtime_root" state "$_fuse_copy_file_range_name"
}

__wait_for_stopped() {
  local _deadline="$((SECONDS + 30))"

  while ((SECONDS <= _deadline)); do
    if __state 2>/dev/null | jq -e '.status == "stopped"' >/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

__main() {
  local _args _output

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
  _args="$(jq -cn --arg program "$_copy_program_with_diagnostics" '["/usr/local/bin/python3","-c",$program]')"
  __prepare_oci_bundle \
    "$_fuse_copy_file_range_base_image" \
    "$_bundle" \
    "$_args" \
    "$_export_name"

  __log "issuing copy_file_range over VirtFS"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_fuse_copy_file_range_name"
  sudo findmnt -rn -T "/var/lib/nscellfs/${_fuse_copy_file_range_name}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'
  sudo nscell --root "$_oci_runtime_root" start "$_fuse_copy_file_range_name"
  if ! __wait_for_stopped; then
    echo "copy_file_range container did not stop" >&2
    exit 1
  fi

  _output="$(sudo cat "${_bundle}/rootfs/result")"
  printf 'copy-file-range-output=%q\n' "$_output"
  if [[ "$_output" != fuse-copy-file-range-ok:* ]]; then
    echo "copy_file_range program did not complete successfully" >&2
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
