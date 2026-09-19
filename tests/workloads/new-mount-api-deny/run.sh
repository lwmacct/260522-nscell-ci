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

  for _syscall_name in open_tree fspick fsopen fsconfig fsmount move_mount mount_setattr; do
    if [[ "$_output" != *"new-mount-api-deny-ok:${_syscall_name}"* ]]; then
      echo "missing explicit deny result for ${_syscall_name}" >&2
      return 1
    fi
  done
}

__daemon_has_decision() {
  local _syscall_name="$1"
  local _decision="$2"
  local _deadline _matches

  # The daemon log is read while the mediator is still writing it, so the
  # decision for a syscall can land after the container returned: poll instead
  # of asserting on one snapshot. The pipeline is captured rather than ended in
  # `grep -q`, which would SIGPIPE the earlier stages under `pipefail`.
  _deadline=$((SECONDS + 15))
  while ((SECONDS <= _deadline)); do
    _matches="$(sudo grep -F 'New mount API decision' "$_daemon_log" |
      grep -F "syscall=${_syscall_name}" |
      grep -F "decision=${_decision}" |
      grep -F 'auditSource=seccomp-new-mount' || true)"
    if [[ -n "$_matches" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

__daemon_has_capability_identity() {
  local _syscall_name="$1"
  local _deadline _matches

  _deadline=$((SECONDS + 15))
  while ((SECONDS <= _deadline)); do
    _matches="$(sudo grep -F 'New mount API decision' "$_daemon_log" |
      grep -F "syscall=${_syscall_name}" |
      grep -F 'decision=allow' |
      grep -F 'capabilityId=' |
      grep -F 'callerTgid=' |
      grep -F 'proxyFd=' |
      grep -F 'socketCookie=' |
      grep -F 'seccompFd=' || true)"
    if [[ -n "$_matches" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

__run_deny_case() {
  local _case="$1"
  local _output

  __cleanup
  _output="$(docker run --rm -i \
    --name "$_new_mount_api_deny_name" \
    --runtime nscell \
    --privileged \
    "$_container_security_policy_base_image" \
    python3 - <<'PY'
import ctypes
import fcntl
import os
import platform
import struct

numbers = {
    "x86_64": {
        "open_tree": 428,
        "fsopen": 430,
        "fsconfig": 431,
        "fsmount": 432,
        "fspick": 433,
        "move_mount": 429,
        "mount_setattr": 442,
        "statmount": 457,
        "listmount": 458,
    },
    "aarch64": {
        "open_tree": 428,
        "fsopen": 430,
        "fsconfig": 431,
        "fsmount": 432,
        "fspick": 433,
        "move_mount": 429,
        "mount_setattr": 442,
        "statmount": 457,
        "listmount": 458,
    },
}
machine = platform.machine()
if machine not in numbers:
    raise SystemExit(f"unsupported architecture: {machine}")

# mount-table queries (statmount/listmount) are mediated and answered for every
# container now, so they belong to the authorized case; what is left here is the
# request the mediator has to refuse on its own.
libc = ctypes.CDLL(None, use_errno=True)
for name, number in numbers[machine].items():
    if name in ("statmount", "listmount"):
        continue
    ctypes.set_errno(0)
    result = libc.syscall(ctypes.c_long(number), ctypes.c_int(-1), None, ctypes.c_uint(0))
    errno = ctypes.get_errno()
    if result != -1 or errno != 1:
        raise SystemExit(f"{name}: result={result} errno={errno}, want result=-1 errno=1(EPERM)")
    print(f"new-mount-api-deny-ok:{name}")
PY
  )"
  printf 'new-mount-api-deny-output[%s]=%q\n' "$_case" "$_output"
  __deny_output_has_case "$_output" || return 1

  local _syscall_name
  for _syscall_name in open_tree fspick fsopen fsconfig fsmount move_mount mount_setattr; do
    if ! __daemon_has_decision "$_syscall_name" deny; then
      echo "daemon did not record structured deny for ${_syscall_name}" >&2
      sudo tail -100 "$_daemon_log" >&2
      return 1
    fi
  done
}

__run_authorized_case() {
  local _case="$1"
  local _source_path="$2"
  local _target_path="$3"
  local _fs_target_path="$4"
  local _case_output
  local _expected_output="new-mount-api-${_case}-ok:proxy-attributes-attach"$'\n'"new-mount-api-${_case}-ok:fs-context-attach"$'\n'"new-mount-api-${_case}-ok:thread-handoff"$'\n'"new-mount-api-${_case}-ok:fork-transfer-denied"$'\n'"new-mount-api-${_case}-ok:fd-reuse"$'\n'"new-mount-api-${_case}-ok:multiprocess-same-fd"$'\n'"new-mount-api-${_case}-ok:statmount-7-fields"
  local _syscall_name

  __cleanup
  _case_output="$(docker run --rm -i \
    --name "$_new_mount_api_deny_name" \
    --runtime nscell \
    --privileged \
    --env "CASE_PROFILE=${_case}" \
    --env "CASE_SOURCE=${_source_path}" \
    --env "CASE_TARGET=${_target_path}" \
    --env "CASE_FS_TARGET=${_fs_target_path}" \
    "$_container_security_policy_base_image" \
    python3 - <<'PY'
import ctypes
import fcntl
import os
import platform
import stat
import struct
import sys
import threading

numbers = {
    "x86_64": {
        "open_tree": 428,
        "move_mount": 429,
        "fsopen": 430,
        "fsconfig": 431,
        "fsmount": 432,
        "fspick": 433,
        "mount_setattr": 442,
        "statmount": 457,
        "listmount": 458,
    },
    "aarch64": {
        "open_tree": 428,
        "move_mount": 429,
        "fsopen": 430,
        "fsconfig": 431,
        "fsmount": 432,
        "fspick": 433,
        "mount_setattr": 442,
        "statmount": 457,
        "listmount": 458,
    },
}
syscalls = numbers.get(platform.machine())
if syscalls is None:
    raise SystemExit(f"unsupported architecture: {platform.machine()}")

profile = os.environ["CASE_PROFILE"]
path = os.environ["CASE_SOURCE"]
target = os.environ["CASE_TARGET"]
fs_target = os.environ["CASE_FS_TARGET"]
os.makedirs(path, exist_ok=True)
os.makedirs(target, exist_ok=True)
os.makedirs(fs_target, exist_ok=True)
thread_target = f"{target}-thread"
transfer_target = f"{target}-transfer"
reuse_target = f"{target}-reuse"
process_targets = [f"{target}-process-0", f"{target}-process-1"]
for extra_target in [thread_target, transfer_target, reuse_target, *process_targets]:
    os.makedirs(extra_target, exist_ok=True)
libc = ctypes.CDLL(None, use_errno=True)
mount_setattr = syscalls["mount_setattr"]


def mount_namespace_id():
    fd = os.open("/proc/self/ns/mnt", os.O_RDONLY)
    try:
        info = bytearray(16)
        fcntl.ioctl(fd, (2 << 30) | (16 << 16) | (0xB7 << 8) | 10, info, True)
        return struct.unpack_from("=Q", info, 8)[0]
    finally:
        os.close(fd)


def query_request(mount_id, param, namespace):
    return struct.pack("=IIQQQ", 32, 0, mount_id, param, namespace)


namespace_id = mount_namespace_id()

ids = (ctypes.c_uint64 * 64)()
ctypes.set_errno(0)
list_result = libc.syscall(
    ctypes.c_long(syscalls["listmount"]),
    query_request(0xFFFFFFFFFFFFFFFF, 0, namespace_id),
    ids,
    ctypes.c_size_t(len(ids)),
    ctypes.c_uint(0),
)
list_errno = ctypes.get_errno()
if list_result < 1:
    print(f"authorized listmount failed: result={list_result} errno={list_errno}", file=sys.stderr)
    raise SystemExit(1)

resume_ids = (ctypes.c_uint64 * 64)()
ctypes.set_errno(0)
resume_result = libc.syscall(
    ctypes.c_long(syscalls["listmount"]),
    query_request(0xFFFFFFFFFFFFFFFF, ids[list_result - 1], namespace_id),
    resume_ids,
    ctypes.c_size_t(len(resume_ids)),
    ctypes.c_uint(0),
)
if resume_result != 0 or ctypes.get_errno() != 0:
    raise SystemExit(
        f"listmount resume failed: result={resume_result} errno={ctypes.get_errno()}"
    )

absent_resume_ids = (ctypes.c_uint64 * 64)()
ctypes.set_errno(0)
absent_resume_result = libc.syscall(
    ctypes.c_long(syscalls["listmount"]),
    query_request(0xFFFFFFFFFFFFFFFF, 1 << 63, namespace_id),
    absent_resume_ids,
    ctypes.c_size_t(len(absent_resume_ids)),
    ctypes.c_uint(0),
)
if absent_resume_result != -1 or ctypes.get_errno() != 2:
    raise SystemExit("listmount accepted an absent resume mount")

stat_buffer = ctypes.create_string_buffer(4096)
ctypes.set_errno(0)
stat_result = libc.syscall(
    ctypes.c_long(syscalls["statmount"]),
    query_request(ids[0], 0xFF, namespace_id),
    stat_buffer,
    ctypes.c_size_t(len(stat_buffer)),
    ctypes.c_uint(0),
)
stat_errno = ctypes.get_errno()
if stat_result == -1:
    print(f"authorized statmount failed: errno={stat_errno}", file=sys.stderr)
    raise SystemExit(1)
result_size, options_offset, result_mask = struct.unpack_from("=IIQ", stat_buffer, 0)
result_mount_id = struct.unpack_from("=Q", stat_buffer, 40)[0]
result_namespace = struct.unpack_from("=Q", stat_buffer, 112)[0]
if result_size <= 512 or result_mask != 0xFF or result_mount_id != ids[0] or result_namespace != namespace_id:
    raise SystemExit(
        "authorized statmount returned invalid identity: "
        f"size={result_size} mask={result_mask:#x} mount={result_mount_id} namespace={result_namespace}"
    )

small_stat_buffer = ctypes.create_string_buffer(512)
ctypes.set_errno(0)
small_stat_result = libc.syscall(
    ctypes.c_long(syscalls["statmount"]),
    query_request(ids[0], 0xFF, namespace_id),
    small_stat_buffer,
    ctypes.c_size_t(len(small_stat_buffer)),
    ctypes.c_uint(0),
)
if small_stat_result != -1 or ctypes.get_errno() != 75:
    raise SystemExit("statmount accepted an undersized string buffer")

wrong_namespace_ids = (ctypes.c_uint64 * 8)()
ctypes.set_errno(0)
wrong_namespace_result = libc.syscall(
    ctypes.c_long(syscalls["listmount"]),
    query_request(0xFFFFFFFFFFFFFFFF, 0, namespace_id ^ 1),
    wrong_namespace_ids,
    ctypes.c_size_t(len(wrong_namespace_ids)),
    ctypes.c_uint(0),
)
if wrong_namespace_result != -1 or ctypes.get_errno() != 1:
    raise SystemExit("listmount accepted a foreign mount namespace")

unknown_mask_buffer = ctypes.create_string_buffer(4096)
ctypes.set_errno(0)
unknown_mask_result = libc.syscall(
    ctypes.c_long(syscalls["statmount"]),
    query_request(ids[0], 1 << 63, namespace_id),
    unknown_mask_buffer,
    ctypes.c_size_t(len(unknown_mask_buffer)),
    ctypes.c_uint(0),
)
if unknown_mask_result != -1 or ctypes.get_errno() != 22:
    raise SystemExit("statmount accepted an unknown mask")

future_request = struct.pack("=IIQQQ", 40, 0, 1, 0, namespace_id)
ctypes.set_errno(0)
future_request_result = libc.syscall(
    ctypes.c_long(syscalls["statmount"]),
    future_request,
    unknown_mask_buffer,
    ctypes.c_size_t(len(unknown_mask_buffer)),
    ctypes.c_uint(0),
)
if future_request_result != -1 or ctypes.get_errno() != 22:
    raise SystemExit("statmount accepted a future request size")


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
    ctypes.c_uint(0x88001),
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
    ctypes.c_uint(0x88001),
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


def raw_syscall(name, *args):
    ctypes.set_errno(0)
    value = libc.syscall(ctypes.c_long(syscalls[name]), *args)
    return value, ctypes.get_errno()


def expect_deny(name, *args):
    result, errno = raw_syscall(name, *args)
    if result != -1 or errno != 1:
        raise SystemExit(f"{name}: result={result} errno={errno}, want EPERM")


expect_deny("fsopen", ctypes.c_char_p(b"overlay"), ctypes.c_uint(0))
expect_deny("fsopen", ctypes.c_char_p(b"tmpfs"), ctypes.c_uint(2))

unsafe_fd, errno = raw_syscall("fsopen", ctypes.c_char_p(b"tmpfs"), ctypes.c_uint(1))
if unsafe_fd == -1:
    raise SystemExit(f"pre-create fsopen failed: errno={errno}")
if not stat.S_ISSOCK(os.fstat(unsafe_fd).st_mode):
    raise SystemExit("fsopen exposed a non-proxy descriptor")
expect_deny("fsconfig", ctypes.c_int(unsafe_fd), ctypes.c_uint(1), ctypes.c_char_p(b"size"), ctypes.c_char_p(b"1m"), ctypes.c_int(0))
expect_deny("fsconfig", ctypes.c_int(unsafe_fd), ctypes.c_uint(3), ctypes.c_char_p(b"source"), ctypes.c_char_p(b"/etc"), ctypes.c_int(-100))
expect_deny("fsconfig", ctypes.c_int(unsafe_fd), ctypes.c_uint(2), ctypes.c_char_p(b"mode"), ctypes.c_char_p(b"\x01\x02"), ctypes.c_int(2))
expect_deny("fsconfig", ctypes.c_int(unsafe_fd), ctypes.c_uint(5), ctypes.c_char_p(b"fd"), None, ctypes.c_int(0))
expect_deny("fsmount", ctypes.c_int(unsafe_fd), ctypes.c_uint(1), ctypes.c_uint(0x100000))
expect_deny("fsmount", ctypes.c_int(unsafe_fd), ctypes.c_uint(1), ctypes.c_uint(0x10))
expect_deny("mount_setattr", ctypes.c_int(unsafe_fd), None, ctypes.c_uint(0x1000), struct.pack("=QQQQ", 1, 0, 0, 0), ctypes.c_size_t(32))
expect_deny("move_mount", ctypes.c_int(unsafe_fd), None, ctypes.c_int(-100), ctypes.c_char_p(fs_target.encode()), ctypes.c_uint(4))
expect_deny("fspick", ctypes.c_int(-100), ctypes.c_char_p(target.encode()), ctypes.c_uint(1))
fsfd = unsafe_fd

expect_deny("fsmount", ctypes.c_int(fsfd), ctypes.c_uint(1), ctypes.c_uint(0xE))
created, errno = raw_syscall(
    "fsconfig",
    ctypes.c_int(fsfd),
    ctypes.c_uint(6),
    None,
    None,
    ctypes.c_int(0),
)
if created != 0:
    raise SystemExit(f"authorized fsconfig failed: result={created} errno={errno}")

mntfd, errno = raw_syscall(
    "fsmount",
    ctypes.c_int(fsfd),
    ctypes.c_uint(1),
    ctypes.c_uint(0xE),
)
if mntfd == -1:
    raise SystemExit(f"authorized fsmount failed: errno={errno}")
if not stat.S_ISSOCK(os.fstat(mntfd).st_mode):
    raise SystemExit("authorized fsmount exposed a non-proxy descriptor")

expect_deny("fsconfig", ctypes.c_int(fsfd), ctypes.c_uint(6), None, None, ctypes.c_int(0))
expect_deny("fsmount", ctypes.c_int(fsfd), ctypes.c_uint(1), ctypes.c_uint(0xE))
moved, errno = raw_syscall(
    "move_mount",
    ctypes.c_int(mntfd),
    None,
    ctypes.c_int(-100),
    ctypes.c_char_p(fs_target.encode()),
    ctypes.c_uint(4),
)
if moved != 0:
    raise SystemExit(f"authorized synthetic move_mount failed: result={moved} errno={errno}")
if fs_target not in open("/proc/self/mountinfo", encoding="utf-8").read():
    raise SystemExit("authorized synthetic move_mount did not attach the mount")
os.close(fsfd)
os.close(mntfd)
print(f"new-mount-api-{profile}-ok:fs-context-attach")


def acquire_tree():
    fd, errno = raw_syscall(
        "open_tree",
        ctypes.c_int(-100),
        ctypes.c_char_p(path.encode()),
        ctypes.c_uint(0x88001),
    )
    if fd == -1:
        raise RuntimeError(f"open_tree failed: errno={errno}")
    if not stat.S_ISSOCK(os.fstat(fd).st_mode):
        raise RuntimeError("open_tree exposed a non-proxy descriptor")
    return fd


def attach_tree(fd, destination):
    ctypes.set_errno(0)
    attr_result = setattr_result(
        fd,
        0x1000,
        struct.pack("=QQQQ", 0xF, 0, 0, 0),
    )
    if attr_result == -1:
        raise RuntimeError(f"mount_setattr failed: errno={ctypes.get_errno()}")
    moved, errno = raw_syscall(
        "move_mount",
        ctypes.c_int(fd),
        None,
        ctypes.c_int(-100),
        ctypes.c_char_p(destination.encode()),
        ctypes.c_uint(4),
    )
    if moved != 0:
        raise RuntimeError(f"move_mount failed: result={moved} errno={errno}")


def socket_cookie(fd):
    value = ctypes.c_uint64()
    length = ctypes.c_uint32(ctypes.sizeof(value))
    ctypes.set_errno(0)
    result = libc.getsockopt(
        ctypes.c_int(fd),
        ctypes.c_int(1),
        ctypes.c_int(57),
        ctypes.byref(value),
        ctypes.byref(length),
    )
    if result != 0 or length.value != ctypes.sizeof(value) or value.value == 0:
        raise RuntimeError(
            f"SO_COOKIE failed: result={result} errno={ctypes.get_errno()} length={length.value} value={value.value}"
        )
    return value.value


thread_result = {}


def acquire_on_thread():
    thread_result["tid"] = threading.get_native_id()
    try:
        thread_result["fd"] = acquire_tree()
    except BaseException as exc:
        thread_result["error"] = repr(exc)


worker = threading.Thread(target=acquire_on_thread)
worker.start()
worker.join()
if "error" in thread_result:
    raise SystemExit(f"thread open_tree failed: {thread_result['error']}")
if thread_result.get("tid") == os.getpid():
    raise SystemExit("thread capability was issued by the thread-group leader")
thread_fd = thread_result["fd"]
thread_duplicate = os.dup(thread_fd)
expect_deny(
    "mount_setattr",
    ctypes.c_int(thread_duplicate),
    None,
    ctypes.c_uint(0x1000),
    struct.pack("=QQQQ", 1, 0, 0, 0),
    ctypes.c_size_t(32),
)
os.close(thread_duplicate)
attach_tree(thread_fd, thread_target)
os.close(thread_fd)
print(f"new-mount-api-{profile}-ok:thread-handoff")

transfer_fd = acquire_tree()
transfer_child = os.fork()
if transfer_child == 0:
    transfer_result, transfer_errno = raw_syscall(
        "mount_setattr",
        ctypes.c_int(transfer_fd),
        None,
        ctypes.c_uint(0x1000),
        struct.pack("=QQQQ", 1, 0, 0, 0),
        ctypes.c_size_t(32),
    )
    os._exit(0 if transfer_result == -1 and transfer_errno == 1 else 1)
_, transfer_status = os.waitpid(transfer_child, 0)
if not os.WIFEXITED(transfer_status) or os.WEXITSTATUS(transfer_status) != 0:
    raise SystemExit("forked process used an inherited capability")
attach_tree(transfer_fd, transfer_target)
os.close(transfer_fd)
print(f"new-mount-api-{profile}-ok:fork-transfer-denied")

old_fd = acquire_tree()
old_cookie = socket_cookie(old_fd)
os.close(old_fd)
new_fd = acquire_tree()
new_cookie = socket_cookie(new_fd)
if new_fd != old_fd:
    raise SystemExit(f"proxy fd was not reused: old={old_fd} new={new_fd}")
if new_cookie == old_cookie:
    raise SystemExit(f"reused proxy fd retained socket cookie {new_cookie}")
attach_tree(new_fd, reuse_target)
os.close(new_fd)
print(f"new-mount-api-{profile}-ok:fd-reuse")

start_read, start_write = os.pipe()
report_read, report_write = os.pipe()
children = []
for index in range(2):
    child = os.fork()
    if child == 0:
        os.close(start_write)
        os.close(report_read)
        exit_code = 0
        try:
            if os.read(start_read, 1) != b"x":
                raise RuntimeError("start barrier closed")
            os.close(start_read)
            process_fd = acquire_tree()
            attach_tree(process_fd, process_targets[index])
            os.write(report_write, f"{index}:{process_fd}\n".encode())
            os.close(process_fd)
        except BaseException as exc:
            os.write(report_write, f"{index}:error:{exc!r}\n".encode())
            exit_code = 1
        os.close(report_write)
        os._exit(exit_code)
    children.append(child)

os.close(start_read)
os.close(report_write)
os.write(start_write, b"xx")
os.close(start_write)
report = bytearray()
while True:
    chunk = os.read(report_read, 4096)
    if not chunk:
        break
    report.extend(chunk)
os.close(report_read)
for child in children:
    _, child_status = os.waitpid(child, 0)
    if not os.WIFEXITED(child_status) or os.WEXITSTATUS(child_status) != 0:
        raise SystemExit(f"multiprocess capability child failed: {report.decode()!r}")

records = sorted(line.split(":") for line in report.decode().splitlines())
if len(records) != 2 or any(len(record) != 2 for record in records):
    raise SystemExit(f"invalid multiprocess capability report: {records!r}")
process_fds = [int(record[1]) for record in records]
if process_fds[0] != process_fds[1]:
    raise SystemExit(f"processes received different guest fds: {process_fds!r}")
print(f"new-mount-api-{profile}-ok:multiprocess-same-fd")

# The daemon answers statmount from its own snapshot, so the Linux 7.0 fields
# have to come back as real data: the structured option array, the fields the
# mount actually has, and the kernel mask the daemon supports. Every claimed
# field must also be filled - a field announced with an empty string is worse
# than one left out of the mask.
fields_mask = 0x7FFF
fields_buffer = ctypes.create_string_buffer(4096)
ctypes.set_errno(0)
fields_result = libc.syscall(
    ctypes.c_long(syscalls["statmount"]),
    query_request(ids[0], fields_mask, namespace_id),
    fields_buffer,
    ctypes.c_size_t(len(fields_buffer)),
    ctypes.c_uint(0),
)
if fields_result == -1:
    raise SystemExit(f"statmount with the 7.0 fields failed: errno={ctypes.get_errno()}")

fields_raw = fields_buffer.raw
fields_size, _, fields_answered = struct.unpack_from("=IIQ", fields_raw, 0)
if fields_answered & ~fields_mask:
    raise SystemExit(f"statmount answered unrequested fields: mask={fields_answered:#x}")
if not fields_answered & (1 << 10):
    raise SystemExit(f"statmount did not answer the option array: mask={fields_answered:#x}")
if not fields_answered & (1 << 12):
    raise SystemExit(f"statmount did not answer the supported mask: mask={fields_answered:#x}")
fields_supported = struct.unpack_from("=Q", fields_raw, 144)[0]
if fields_supported & fields_mask != fields_mask:
    raise SystemExit(
        f"statmount reported supported mask {fields_supported:#x}, want {fields_mask:#x}"
    )


def field_string(offset):
    if offset == 0:
        return ""
    start = 512 + offset
    if start >= fields_size:
        raise SystemExit(f"statmount string offset {offset} is outside the result")
    end = fields_raw.index(b"\0", start)
    return fields_raw[start:end].decode()


def field_strings(offset, count):
    values = []
    position = 512 + offset
    for _ in range(count):
        end = fields_raw.index(b"\0", position)
        values.append(fields_raw[position:end].decode())
        position = end + 1
    return values


if fields_answered & (1 << 9) and not field_string(struct.unpack_from("=I", fields_raw, 124)[0]):
    raise SystemExit("statmount claimed a filesystem source but did not fill it")

option_count, option_offset = struct.unpack_from("=II", fields_raw, 128)
if option_count == 0 or not field_strings(option_offset, option_count):
    raise SystemExit("statmount returned an empty option array")

for label, count_offset, list_offset, bit in (
    ("subtype", 0, 120, 1 << 8),
    ("security option array", 136, 140, 1 << 11),
    ("uid map", 152, 156, 1 << 13),
    ("gid map", 160, 164, 1 << 14),
):
    if not fields_answered & bit:
        continue
    if label == "subtype":
        if not field_string(struct.unpack_from("=I", fields_raw, list_offset)[0]):
            raise SystemExit("statmount claimed a subtype but did not fill it")
        continue
    count, offset = struct.unpack_from("=II", fields_raw, count_offset)
    if count and len(field_strings(offset, count)) != count:
        raise SystemExit(f"statmount claimed the {label} but did not fill it")

print(f"new-mount-api-{profile}-ok:statmount-7-fields")
PY
  )"
  printf 'new-mount-api-authorized-output[%s]=%q\n' "$_case" "$_case_output"
  if [[ "$_case_output" != "$_expected_output" ]]; then
    echo "authorized ${_case} new-mount API case failed" >&2
    return 1
  fi

  for _syscall_name in open_tree fsopen fsconfig fsmount mount_setattr move_mount listmount statmount; do
    if ! __daemon_has_decision "$_syscall_name" allow; then
      echo "daemon did not record structured allow for ${_syscall_name}" >&2
      sudo tail -100 "$_daemon_log" >&2
      return 1
    fi
  done
  for _syscall_name in open_tree fsopen fsconfig fsmount mount_setattr move_mount; do
    if ! __daemon_has_capability_identity "$_syscall_name"; then
      echo "daemon did not record capability identity for ${_syscall_name}" >&2
      sudo tail -100 "$_daemon_log" >&2
      return 1
    fi
  done
  for _syscall_name in open_tree fsopen fsconfig fsmount mount_setattr listmount statmount; do
    if ! __daemon_has_decision "$_syscall_name" deny; then
      echo "daemon did not record structured deny for ${_syscall_name}" >&2
      sudo tail -100 "$_daemon_log" >&2
      return 1
    fi
  done
  if ! sudo grep -F 'New mount API decision' "$_daemon_log" |
    grep -F 'syscall=open_tree' |
    grep -F 'decision=allow' |
    grep -F 'flags=0x88001' >/dev/null; then
    echo "daemon did not record recursive open_tree acquisition" >&2
    sudo tail -100 "$_daemon_log" >&2
    return 1
  fi
  if ! sudo grep -F 'New mount API decision' "$_daemon_log" |
    grep -F 'syscall=fsmount' |
    grep -F 'decision=deny' |
    grep -F 'attrFlags=0x100000' >/dev/null; then
    echo "daemon did not record idmap fsmount denial" >&2
    sudo tail -100 "$_daemon_log" >&2
    return 1
  fi
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

  __log "checking structured new-mount denials for requests the mediator refuses"
  __run_deny_case system

  __log "checking proxy acquisition, attributes, and attach for each workload path family"
  __run_authorized_case \
    docker \
    /var/lib/docker/overlay2/nscell-ci/merged \
    /var/lib/docker/overlay2/nscell-ci/attached \
    /var/lib/docker/overlay2/nscell-ci/fscontext
  __run_authorized_case \
    kubelet \
    /var/lib/kubelet/pods/nscell-ci/merged \
    /var/lib/kubelet/pods/nscell-ci/attached \
    /var/lib/kubelet/pods/nscell-ci/fscontext
  __run_authorized_case \
    buildkit \
    /var/lib/buildkit/nscell-ci/merged \
    /var/lib/buildkit/nscell-ci/attached \
    /var/lib/buildkit/nscell-ci/fscontext

  __assert_nscell_ready
  trap - EXIT
  __cleanup
  echo "new-mount-api-mediation-validation-ok"
}

__main "$@"
