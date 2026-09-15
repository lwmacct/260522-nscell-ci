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
  local _acquire_output _output

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

  __log "checking that an authorized dind open_tree receives only a proxy descriptor"
  _acquire_output="$(docker run --rm -i \
    --name "$_new_mount_api_deny_name" \
    --runtime nscell \
    --annotation io.backend.security.profile=dind \
    --label io.backend.security.profile=dind \
    "$_container_security_policy_base_image" \
    python3 - <<'PY'
import ctypes
import os
import platform
import stat
import sys

numbers = {
    "x86_64": {"open_tree": 428, "move_mount": 429},
    "aarch64": {"open_tree": 428, "move_mount": 429},
}
syscalls = numbers.get(platform.machine())
if syscalls is None:
    raise SystemExit(f"unsupported architecture: {platform.machine()}")
number = syscalls["open_tree"]

path = "/var/lib/docker/overlay2/nscell-ci/merged"
target = "/var/lib/docker/overlay2/nscell-ci/attached"
os.makedirs(path, exist_ok=True)
os.makedirs(target, exist_ok=True)
libc = ctypes.CDLL(None, use_errno=True)
ctypes.set_errno(0)
result = libc.syscall(
    ctypes.c_long(number),
    ctypes.c_int(-100),
    ctypes.c_char_p(path.encode()),
    ctypes.c_uint(0x80001),
)
errno = ctypes.get_errno()
if result == -1:
    print(f"authorized open_tree failed: errno={errno}", file=sys.stderr)
    raise SystemExit(1)
info = os.fstat(result)
if not stat.S_ISSOCK(info.st_mode):
    raise SystemExit("authorized open_tree exposed a non-proxy descriptor", file=sys.stderr)
move_mount = syscalls["move_mount"]
ctypes.set_errno(0)
move_result = libc.syscall(
    ctypes.c_long(move_mount),
    ctypes.c_int(result),
    None,
    ctypes.c_int(-100),
    ctypes.c_char_p(target.encode()),
    ctypes.c_uint(4),
)
move_errno = ctypes.get_errno()
if move_result == -1:
    print(f"authorized move_mount failed: errno={move_errno}", file=sys.stderr)
    raise SystemExit(1)
mountinfo = open("/proc/self/mountinfo", encoding="utf-8").read()
if target not in mountinfo:
    print("authorized move_mount did not attach the mount", file=sys.stderr)
    raise SystemExit(1)
os.umount(target)
mountinfo = open("/proc/self/mountinfo", encoding="utf-8").read()
if target in mountinfo:
    print("authorized move_mount cleanup failed", file=sys.stderr)
    raise SystemExit(1)
os.close(result)
print("new-mount-api-acquire-ok:proxy-socket-and-attach")
PY
  )"
  printf 'new-mount-acquire-output=%q\n' "$_acquire_output"
  if [[ "$_acquire_output" != "new-mount-api-acquire-ok:proxy-socket-and-attach" ]]; then
    echo "authorized open_tree did not return a proxy descriptor" >&2
    exit 1
  fi
  if ! sudo grep -F 'New mount API tree capability issued: syscall=open_tree' \
    "$_daemon_log" >/dev/null; then
    echo "daemon did not record the authorized open_tree capability" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi
  if ! sudo grep -F 'New mount API attach completed:' \
    "$_daemon_log" >/dev/null; then
    echo "daemon did not record the authorized move_mount completion" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi

  __assert_nscell_ready
  trap - EXIT
  __cleanup
  echo "new-mount-api-deny-validation-ok"
}

__main "$@"
