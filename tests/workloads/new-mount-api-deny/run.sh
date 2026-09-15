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
  docker rm -f "$_new_mount_api_deny_name" >/dev/null 2>&1 || true
}

__main() {
  local _output

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT
  __cleanup
  __ensure_host_image "$_container_security_policy_base_image"

  __log "checking that new mount API calls reach the explicit deny mediator"
  _output="$(docker run --rm -i \
    --name "$_new_mount_api_deny_name" \
    --runtime nscell \
    --label io.backend.security.profile=default \
    "$_container_security_policy_base_image" \
    python3 - <<'PY'
import ctypes
import platform

numbers = {
    "x86_64": {"open_tree": 428, "fspick": 433, "move_mount": 429, "mount_setattr": 442},
    "aarch64": {"open_tree": 428, "fspick": 433, "move_mount": 429, "mount_setattr": 442},
}
machine = platform.machine()
if machine not in numbers:
    raise SystemExit(f"unsupported architecture: {machine}")

libc = ctypes.CDLL(None, use_errno=True)
for name, number in numbers[machine].items():
    ctypes.set_errno(0)
    result = libc.syscall(ctypes.c_long(number), ctypes.c_int(-1), None, ctypes.c_uint(0))
    errno = ctypes.get_errno()
    if result != -1 or errno != 1:
        raise SystemExit(f"{name}: result={result} errno={errno}, want result=-1 errno=1(EPERM)")
    print(f"new-mount-api-deny-ok:{name}")
PY
  )"
  printf 'new-mount-api-output=%q\n' "$_output"

  for syscall_name in open_tree fspick move_mount mount_setattr; do
    if [[ "$_output" != *"new-mount-api-deny-ok:${syscall_name}"* ]]; then
      echo "missing explicit deny result for ${syscall_name}" >&2
      exit 1
    fi
    if ! sudo grep -F "New mount API denied pending mediation: syscall=${syscall_name}" \
      "$_daemon_log" >/dev/null; then
      echo "daemon did not record explicit deny for ${syscall_name}" >&2
      sudo tail -100 "$_daemon_log" >&2
      exit 1
    fi
  done

  __assert_nscell_ready
  trap - EXIT
  __cleanup
  echo "new-mount-api-deny-validation-ok"
}

__main "$@"
