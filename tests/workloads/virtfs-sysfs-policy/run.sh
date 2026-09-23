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

_bundle="${_volume_root}/virtfs-sysfs-policy/bundle"
_export_name="nscell-oci-export-${_workload_resource_id:-virtfs-sysfs-policy}"

__cleanup() {
  __remove_oci_container "$_oci_runtime_root" "$_virtfs_sysfs_policy_name"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__state() {
  sudo nscell --root "$_oci_runtime_root" state "$_virtfs_sysfs_policy_name"
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

__write_policy_program() {
  sudo install -d -m 0755 "${_bundle}/rootfs/tmp"
  sudo tee "${_bundle}/rootfs/tmp/virtfs_sysfs_policy.py" >/dev/null <<'PY'
import errno
import os

path = "/sys/module/nf_conntrack/parameters/hashsize"
result = open("/result", "w", encoding="ascii")
before = open(path, "rb").read()
if not before.strip().isdigit():
    raise SystemExit(f"unexpected conntrack hashsize value: {before!r}")
stat = os.stat(path)
if stat.st_mode & 0o777 != 0o444:
    raise SystemExit(f"conntrack hashsize mode is {stat.st_mode & 0o777:#o}, want 0444")
for flags in (os.O_WRONLY, os.O_RDWR):
    try:
        os.open(path, flags | os.O_CLOEXEC)
    except OSError as error:
        if error.errno != errno.EPERM:
            raise
    else:
        raise SystemExit(f"write-capable open was admitted for flags {flags:#x}")
result.write("virtfs-sysfs-policy-ok")
PY
}

__main() {
  local _output

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
  __prepare_oci_bundle \
    "$_virtfs_sysfs_policy_base_image" \
    "$_bundle" \
    '["/bin/sh", "-c", "exec python3 /tmp/virtfs_sysfs_policy.py"]' \
    "$_export_name"
  __write_policy_program

  __log "checking the VirtFS conntrack policy"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_virtfs_sysfs_policy_name"
  sudo findmnt -rn -T "/var/lib/nscell/virtfs/${_virtfs_sysfs_policy_name}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'
  sudo nscell --root "$_oci_runtime_root" start "$_virtfs_sysfs_policy_name"
  if ! __wait_for_stopped; then
    echo "VirtFS sysfs policy container did not stop" >&2
    exit 1
  fi

  _output="$(sudo cat "${_bundle}/rootfs/result")"
  printf 'virtfs-sysfs-policy-output=%q\n' "$_output"
  if [[ "$_output" != "virtfs-sysfs-policy-ok" ]]; then
    echo "VirtFS sysfs policy probe failed" >&2
    exit 1
  fi

  sudo nscell --root "$_oci_runtime_root" delete "$_virtfs_sysfs_policy_name"
  if sudo findmnt -rn -t fuse,fuse.nscellfs |
    grep -F "/${_virtfs_sysfs_policy_name}"; then
    echo "VirtFS mount survived sysfs policy container deletion" >&2
    exit 1
  fi
  __assert_nscell_ready

  trap - EXIT
  __cleanup
  echo "virtfs-sysfs-policy-validation-ok"
}

__main "$@"
