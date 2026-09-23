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
_copy_path="/proc/sys/kernel/hostname"
_metrics_url="http://127.0.0.1:9618/metrics"

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

# Linux 7.0 always sends FUSE_COPY_FILE_RANGE_64 and only drops back to the
# legacy opcode after an -ENOSYS, so a silent fallback would reintroduce the
# 32-bit copy length without anyone noticing. Count both opcodes instead of
# trusting that the request arrived at all.
#
# The copy stays within the same file because views are per-file bind mounts
# (a cross-view copy is EXDEV). A non-overlapping destination beyond EOF writes
# only to the container-scoped proc-sys cache, leaving the host hostname intact.
# What the nonzero count adds - the 64-bit reply shape - is pinned by
# TestCopyFileRange64ResponseCarriesTheFullCount in internal/fuse instead.
__opcode_requests() {
  local _opcode="$1"

  curl -fsS "${_metrics_url}" |
    awk -v _label="opcode=\"${_opcode}\"" '
      index($1, "nscell_virtfs_fuse_requests_by_opcode_total{") == 1 &&
        index($1, _label) { total += $2 }
      END { printf "%d\n", total + 0 }
    '
}

__copy64_requests() {
  __opcode_requests copy_file_range_64
}

__legacy_copy_requests() {
  __opcode_requests copy_file_range
}

__write_copy_program() {
  sudo install -d -m 0755 "${_bundle}/rootfs/tmp"
  sudo tee "${_bundle}/rootfs/tmp/copy_file_range.py" >/dev/null <<'PY'
import os

path = "/proc/sys/kernel/hostname"
result = open("/result", "w", encoding="ascii")
before = open(path, "rb").read()
requested = min(4, len(before))
if requested == 0:
    raise SystemExit("hostname is too short for the copy probe")
source = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
destination = os.open(path, os.O_WRONLY | os.O_CLOEXEC)
count = os.copy_file_range(source, destination, requested, 0, len(before))
after = open(path, "rb").read()
assert count == requested, (count, requested)
assert after == before, (after, before)
result.write(f"fuse-copy-file-range-ok:{count}")
PY
}

__main() {
  local _copy64_after _copy64_before _legacy_after _legacy_before _output _bytes_copied

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd curl
  __require_cmd jq
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT

  __cleanup
  __prepare_oci_bundle \
    "$_fuse_copy_file_range_base_image" \
    "$_bundle" \
    '["/bin/sh", "-c", "exec python3 /tmp/copy_file_range.py"]' \
    "$_export_name"
  __write_copy_program
  __log "issuing copy_file_range over VirtFS"
  _copy64_before="$(__copy64_requests)"
  _legacy_before="$(__legacy_copy_requests)"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_fuse_copy_file_range_name"
  sudo findmnt -rn -T "/var/lib/nscell/virtfs/${_fuse_copy_file_range_name}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'
  sudo nscell --root "$_oci_runtime_root" start "$_fuse_copy_file_range_name"
  if ! __wait_for_stopped; then
    echo "copy_file_range container did not stop" >&2
    exit 1
  fi

  _output="$(sudo cat "${_bundle}/rootfs/result")"
  printf 'copy-file-range-output=%q\n' "$_output"
  if [[ ! "$_output" =~ ^fuse-copy-file-range-ok:([1-9][0-9]*)$ ]]; then
    echo "copy_file_range program did not complete successfully" >&2
    exit 1
  fi
  _bytes_copied="${BASH_REMATCH[1]}"
  _copy64_after="$(__copy64_requests)"
  _legacy_after="$(__legacy_copy_requests)"
  printf 'copy-file-range-opcodes: copy_file_range_64=%s->%s legacy=copy_file_range=%s->%s\n' \
    "${_copy64_before}" "${_copy64_after}" "${_legacy_before}" "${_legacy_after}"
  if ((_copy64_after - _copy64_before < 1)); then
    echo "the kernel did not send the copy as FUSE_COPY_FILE_RANGE_64" >&2
    exit 1
  fi
  if ((_legacy_after != _legacy_before)); then
    echo "the kernel fell back to the legacy FUSE_COPY_FILE_RANGE opcode" >&2
    exit 1
  fi
  if ! sudo grep -F "FUSE copy_file_range handled from ${_copy_path} to ${_copy_path}: bytes=${_bytes_copied} legacy=false" \
    "$_daemon_log" >/dev/null; then
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
