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
_copy_path="/sys/module/nf_conntrack/parameters/hashsize"
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
# The copy itself stays a denied, zero-byte one: views are per-file bind mounts
# (a cross-view copy is EXDEV) and the writable ones only accept offset 0, which
# a same-file copy cannot use without overlapping the source range. What a
# nonzero count would add - the 64-bit reply shape - is pinned by
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

path = "/sys/module/nf_conntrack/parameters/hashsize"
result = open("/result", "w", encoding="ascii")
stage = "read"
try:
    before = open(path, "rb").read()
    source = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    stage = "open-write"
    destination = os.open(path, os.O_WRONLY | os.O_CLOEXEC)
    stage = "copy"
    requested = min(4, len(before))
    if requested == 0:
        raise OSError("empty copy source")
    count = os.copy_file_range(source, destination, requested, 0, requested)
    after = open(path, "rb").read()
    assert count == 0
    assert after == before
    output = f"fuse-copy-file-range-ok:{count}"
except Exception as error:
    try:
        stat = os.stat(path)
        detail = (
            f"errno={getattr(error, 'errno', '-')}:uids={os.getuid()}:{os.geteuid()}:"
            f"stat={stat.st_mode:o}:{stat.st_uid}:{stat.st_gid}"
        )
    except OSError:
        detail = repr(error)
    output = f"copy-error:stage={stage}:{type(error).__name__}:{detail}"
result.write(output)
PY
}

__main() {
  local _config_tmp _copy64_after _copy64_before _legacy_after _legacy_before _output

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
  sudo findmnt -rn -T "/var/lib/nscellfs/${_fuse_copy_file_range_name}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'
  sudo nscell --root "$_oci_runtime_root" start "$_fuse_copy_file_range_name"
  if ! __wait_for_stopped; then
    echo "copy_file_range container did not stop" >&2
    exit 1
  fi

  _output="$(sudo cat "${_bundle}/rootfs/result")"
  printf 'copy-file-range-output=%q\n' "$_output"
  if [[ "$_output" != "fuse-copy-file-range-ok:0" ]]; then
    echo "copy_file_range program did not complete successfully" >&2
    exit 1
  fi
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
  if ! sudo grep -F "FUSE copy_file_range handled from ${_copy_path} to ${_copy_path}: bytes=0 legacy=false" \
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
