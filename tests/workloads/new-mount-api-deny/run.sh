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

__deny_output_has_case() {
  local _output="$1"
  local _syscall_name

  for _syscall_name in open_tree fspick move_mount mount_setattr; do
    if [[ "$_output" != *"new-mount-api-deny-ok:${_syscall_name}"* ]]; then
      echo "missing explicit deny result for ${_syscall_name}" >&2
      return 1
    fi
  done
}

__daemon_has_decision() {
  local _syscall_name="$1"
  local _decision="$2"
  local _profile="$3"

  sudo grep -F 'New mount API decision' "$_daemon_log" |
    grep -F "syscall=${_syscall_name}" |
    grep -F "decision=${_decision}" |
    grep -F "profile=${_profile}" >/dev/null
}

__run_deny_case() {
  local _profile="$1"
  local _output

  __cleanup
  _output="$(docker run --rm -i \
    --name "$_new_mount_api_deny_name" \
    --runtime nscell \
    --annotation "io.backend.security.profile=${_profile}" \
    --label "io.backend.security.profile=${_profile}" \
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
  printf 'new-mount-api-deny-output[%s]=%q\n' "$_profile" "$_output"
  __deny_output_has_case "$_output" || return 1

  local _syscall_name
  for _syscall_name in open_tree fspick move_mount mount_setattr; do
    if ! __daemon_has_decision "$_syscall_name" deny "$_profile"; then
      echo "daemon did not record structured ${_profile} deny for ${_syscall_name}" >&2
      sudo tail -100 "$_daemon_log" >&2
      return 1
    fi
  done
}

__run_authorized_case() {
  local _profile="$1"
  local _source_path="$2"
  local _target_path="$3"
  local _case_output
  local _expected_output="new-mount-api-${_profile}-ok:proxy-attributes-attach"
  local _syscall_name

  __cleanup
  _case_output="$(docker run --rm -i \
    --name "$_new_mount_api_deny_name" \
    --runtime nscell \
    --annotation "io.backend.security.profile=${_profile}" \
    --label "io.backend.security.profile=${_profile}" \
    --env "CASE_PROFILE=${_profile}" \
    --env "CASE_SOURCE=${_source_path}" \
    --env "CASE_TARGET=${_target_path}" \
    "$_container_security_policy_base_image" \
    python3 - <<'PY'
import ctypes
import os
import platform
import stat
import struct
import sys

numbers = {
    "x86_64": {"open_tree": 428, "move_mount": 429, "mount_setattr": 442},
    "aarch64": {"open_tree": 428, "move_mount": 429, "mount_setattr": 442},
}
syscalls = numbers.get(platform.machine())
if syscalls is None:
    raise SystemExit(f"unsupported architecture: {platform.machine()}")

profile = os.environ["CASE_PROFILE"]
path = os.environ["CASE_SOURCE"]
target = os.environ["CASE_TARGET"]
os.makedirs(path, exist_ok=True)
os.makedirs(target, exist_ok=True)
libc = ctypes.CDLL(None, use_errno=True)
mount_setattr = syscalls["mount_setattr"]


def setattr_result(fd, flags, attr):
    return libc.syscall(
        ctypes.c_long(mount_setattr),
        ctypes.c_int(fd),
        None,
        ctypes.c_uint(flags),
        attr,
        ctypes.c_size_t(struct.calcsize("=QQQQ")),
    )


ctypes.set_errno(0)
denied_result = libc.syscall(
    ctypes.c_long(syscalls["open_tree"]),
    ctypes.c_int(-100),
    ctypes.c_char_p(b"/etc"),
    ctypes.c_uint(0x80001),
)
if denied_result != -1 or ctypes.get_errno() != 1:
    print(
        f"unauthorized open_tree: result={denied_result} errno={ctypes.get_errno()}",
        file=sys.stderr,
    )
    raise SystemExit(1)

ctypes.set_errno(0)
result = libc.syscall(
    ctypes.c_long(syscalls["open_tree"]),
    ctypes.c_int(-100),
    ctypes.c_char_p(path.encode()),
    ctypes.c_uint(0x80001),
)
errno = ctypes.get_errno()
if result == -1:
    print(f"authorized open_tree failed: errno={errno}", file=sys.stderr)
    raise SystemExit(1)
if not stat.S_ISSOCK(os.fstat(result).st_mode):
    raise SystemExit("authorized open_tree exposed a non-proxy descriptor", file=sys.stderr)

unsafe_attributes = (
    ("idmap", struct.pack("=QQQQ", 0x100000, 0, 0, 0)),
    ("propagation", struct.pack("=QQQQ", 0, 0, 0x10000, 0)),
    ("userns", struct.pack("=QQQQ", 0, 0, 0, 1)),
)
for label, unsafe_attr in unsafe_attributes:
    ctypes.set_errno(0)
    unsafe_result = setattr_result(result, 0x1000, unsafe_attr)
    unsafe_errno = ctypes.get_errno()
    if unsafe_result != -1 or unsafe_errno != 1:
        print(
            f"unsafe mount_setattr {label}: result={unsafe_result} errno={unsafe_errno}",
            file=sys.stderr,
        )
        raise SystemExit(1)

ctypes.set_errno(0)
recursive_result = setattr_result(
    result,
    0x1000 | 0x8000,
    struct.pack("=QQQQ", 0, 0, 0, 0),
)
if recursive_result != -1 or ctypes.get_errno() != 1:
    print(
        f"recursive mount_setattr: result={recursive_result} errno={ctypes.get_errno()}",
        file=sys.stderr,
    )
    raise SystemExit(1)

ctypes.set_errno(0)
attr_result = setattr_result(
    result,
    0x1000,
    struct.pack("=QQQQ", 0xF, 0, 0, 0),
)
if attr_result == -1:
    print(
        f"authorized mount_setattr failed: errno={ctypes.get_errno()}",
        file=sys.stderr,
    )
    raise SystemExit(1)

ctypes.set_errno(0)
move_result = libc.syscall(
    ctypes.c_long(syscalls["move_mount"]),
    ctypes.c_int(result),
    None,
    ctypes.c_int(-100),
    ctypes.c_char_p(target.encode()),
    ctypes.c_uint(4),
)
if move_result == -1:
    print(
        f"authorized move_mount failed: errno={ctypes.get_errno()}",
        file=sys.stderr,
    )
    raise SystemExit(1)
if target not in open("/proc/self/mountinfo", encoding="utf-8").read():
    print("authorized move_mount did not attach the mount", file=sys.stderr)
    raise SystemExit(1)
os.close(result)
print(f"new-mount-api-{profile}-ok:proxy-attributes-attach")
PY
  )"
  printf 'new-mount-api-authorized-output[%s]=%q\n' "$_profile" "$_case_output"
  if [[ "$_case_output" != "$_expected_output" ]]; then
    echo "authorized ${_profile} new-mount API case failed" >&2
    return 1
  fi

  for _syscall_name in open_tree mount_setattr move_mount; do
    if ! __daemon_has_decision "$_syscall_name" allow "$_profile"; then
      echo "daemon did not record structured ${_profile} allow for ${_syscall_name}" >&2
      sudo tail -100 "$_daemon_log" >&2
      return 1
    fi
  done
  for _syscall_name in open_tree mount_setattr; do
    if ! __daemon_has_decision "$_syscall_name" deny "$_profile"; then
      echo "daemon did not record structured ${_profile} deny for ${_syscall_name}" >&2
      sudo tail -100 "$_daemon_log" >&2
      return 1
    fi
  done
}

__main() {
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

  __log "checking structured default new-mount denials"
  __run_deny_case default

  __log "checking profile-scoped proxy acquisition, attributes, and attach"
  __run_authorized_case \
    dind \
    /var/lib/docker/overlay2/nscell-ci/merged \
    /var/lib/docker/overlay2/nscell-ci/attached
  __run_authorized_case \
    k8s-node \
    /var/lib/kubelet/pods/nscell-ci/merged \
    /var/lib/kubelet/pods/nscell-ci/attached
  __run_authorized_case \
    buildkit \
    /var/lib/buildkit/nscell-ci/merged \
    /var/lib/buildkit/nscell-ci/attached

  __assert_nscell_ready
  trap - EXIT
  __cleanup
  echo "new-mount-api-mediation-validation-ok"
}

__main "$@"
