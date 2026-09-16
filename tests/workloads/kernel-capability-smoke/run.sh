#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"

__require_kernel_floor() {
  local _profile _release _version_floor

  _release="$(uname -r)"
  _version_floor="$(printf '%s\n%s\n' '6.18.0' "${_release%%-*}" | sort -V | head -1)"
  [[ "${_version_floor}" == '6.18.0' ]]
  _profile="$(cat /etc/test-vm-profile 2>/dev/null || true)"
  if [[ "${_profile}" == *"IMAGE_PROFILE=linux-6-18"* ]]; then
    [[ "${_release}" == 6.18.52-061852-generic ]]
  fi
}

__require_cgroup_v2() {
  awk '$5 == "/sys/fs/cgroup" {
    for (i = 1; i <= NF; i++) {
      if ($i == "-" && $(i + 1) == "cgroup2" && $4 == "/") {
        found = 1
      }
    }
  } END { exit !found }' /proc/self/mountinfo
  test -r /sys/fs/cgroup/cgroup.controllers
}

__require_kernel_interfaces() {
  test -c /dev/fuse
}

__probe_mount_namespace_apis() {
  sudo python3 - <<'PY'
import ctypes
import errno
import fcntl
import os
import platform
import socket
import struct
import threading

libc = ctypes.CDLL(None, use_errno=True)

def syscall(number, *args):
    result = libc.syscall(ctypes.c_long(number), *args)
    if result == -1:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return result

machine = platform.machine()
statx_number = {"x86_64": 332, "aarch64": 291}.get(machine)
if statx_number is None:
    raise SystemExit(f"unsupported architecture for statx probe: {machine}")

statx = ctypes.create_string_buffer(256)
STATX_MNT_ID_UNIQUE = 0x4000
syscall(
    statx_number,
    ctypes.c_int(-100),
    b"/",
    ctypes.c_uint(0),
    ctypes.c_uint(STATX_MNT_ID_UNIQUE),
    statx,
)
mask = struct.unpack_from("=I", statx, 0)[0]
mount_id = struct.unpack_from("=Q", statx, 144)[0]
if not mask & STATX_MNT_ID_UNIQUE or mount_id == 0:
    raise SystemExit(f"STATX_MNT_ID_UNIQUE unavailable: mask={mask:#x} mount_id={mount_id}")

class MntIDReq(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("spare", ctypes.c_uint32),
        ("mnt_id", ctypes.c_uint64),
        ("param", ctypes.c_uint64),
        ("mnt_ns_id", ctypes.c_uint64),
    ]

class MntNSInfo(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("nr_mounts", ctypes.c_uint32),
        ("mnt_ns_id", ctypes.c_uint64),
    ]

nsfd = os.open("/proc/self/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
try:
    info = MntNSInfo()
    NS_MNT_GET_INFO = 0x8010B70A
    if libc.ioctl(ctypes.c_int(nsfd), ctypes.c_ulong(NS_MNT_GET_INFO), ctypes.byref(info)) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if info.size < ctypes.sizeof(MntNSInfo) or info.mnt_ns_id == 0:
        raise SystemExit(f"invalid mount namespace info: {info.size} {info.nr_mounts} {info.mnt_ns_id}")
finally:
    os.close(nsfd)

pidfd_open_number = {"x86_64": 434, "aarch64": 434}.get(machine)
if pidfd_open_number is None:
    raise SystemExit(f"unsupported architecture for pidfd probe: {machine}")
pidfd_getfd_number = {"x86_64": 438, "aarch64": 438}.get(machine)
if pidfd_getfd_number is None:
    raise SystemExit(f"unsupported architecture for pidfd_getfd probe: {machine}")

PIDFD_THREAD = 0x80
thread_result = {}

def probe_thread_pidfd():
    tid = threading.get_native_id()
    if tid == os.getpid():
        raise RuntimeError("thread pidfd probe ran on the thread-group leader")
    ctypes.set_errno(0)
    thread_fd = libc.syscall(
        ctypes.c_long(pidfd_open_number),
        ctypes.c_int(tid),
        ctypes.c_uint(PIDFD_THREAD),
    )
    if thread_fd == -1:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    os.close(thread_fd)
    thread_result["tid"] = tid

thread = threading.Thread(target=probe_thread_pidfd)
thread.start()
thread.join()
if "tid" not in thread_result:
    raise SystemExit("PIDFD_THREAD probe did not return a thread identity")

probe_sockets = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    source_fd = probe_sockets[0].fileno()

    def socket_cookie(fd):
        value = ctypes.c_uint64()
        length = ctypes.c_uint32(ctypes.sizeof(value))
        ctypes.set_errno(0)
        result = libc.getsockopt(
            ctypes.c_int(fd),
            ctypes.c_int(socket.SOL_SOCKET),
            ctypes.c_int(57),
            ctypes.byref(value),
            ctypes.byref(length),
        )
        if result != 0 or length.value != ctypes.sizeof(value) or value.value == 0:
            raise RuntimeError(
                "SO_COOKIE failed: "
                f"result={result} errno={ctypes.get_errno()} length={length.value} value={value.value}"
            )
        return value.value

    source_cookie = socket_cookie(source_fd)
    getfd_result = {}

    def probe_pidfd_getfd():
        tid = threading.get_native_id()
        if tid == os.getpid():
            getfd_result["error"] = "pidfd_getfd probe ran on the thread-group leader"
            return
        ctypes.set_errno(0)
        thread_pidfd = libc.syscall(
            ctypes.c_long(pidfd_open_number),
            ctypes.c_int(tid),
            ctypes.c_uint(PIDFD_THREAD),
        )
        if thread_pidfd == -1:
            getfd_result["error"] = f"thread pidfd open errno={ctypes.get_errno()}"
            return
        try:
            ctypes.set_errno(0)
            duplicate_fd = libc.syscall(
                ctypes.c_long(pidfd_getfd_number),
                ctypes.c_int(thread_pidfd),
                ctypes.c_int(source_fd),
                ctypes.c_uint(0),
            )
            if duplicate_fd == -1:
                getfd_result["error"] = f"pidfd_getfd errno={ctypes.get_errno()}"
                return
            try:
                duplicate_cookie = socket_cookie(duplicate_fd)
                if duplicate_cookie != source_cookie:
                    getfd_result["error"] = (
                        f"SO_COOKIE mismatch source={source_cookie} duplicate={duplicate_cookie}"
                    )
                else:
                    getfd_result["ok"] = True
            finally:
                os.close(duplicate_fd)
        finally:
            os.close(thread_pidfd)

    getfd_thread = threading.Thread(target=probe_pidfd_getfd)
    getfd_thread.start()
    getfd_thread.join()
    if "ok" not in getfd_result:
        raise SystemExit(f"pidfd_getfd probe failed: {getfd_result.get('error', 'unknown error')}")
finally:
    probe_sockets[0].close()
    probe_sockets[1].close()

process_pidfd = syscall(
    pidfd_open_number,
    ctypes.c_int(os.getpid()),
    ctypes.c_uint(0),
)
try:
    PIDFD_GET_MNT_NAMESPACE = 0xFF03
    pidfd_nsfd = fcntl.ioctl(process_pidfd, PIDFD_GET_MNT_NAMESPACE)
    try:
        pidfd_info = MntNSInfo()
        if libc.ioctl(
            ctypes.c_int(pidfd_nsfd),
            ctypes.c_ulong(NS_MNT_GET_INFO),
            ctypes.byref(pidfd_info),
        ) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        if pidfd_info.mnt_ns_id != info.mnt_ns_id:
            raise SystemExit(
                "pidfd mount namespace identity mismatch: "
                f"{pidfd_info.mnt_ns_id} != {info.mnt_ns_id}"
            )
    finally:
        os.close(pidfd_nsfd)
finally:
    os.close(process_pidfd)

STATMOUNT_MNT_BASIC = 0x2
STATMOUNT_MNT_NS_ID = 0x40
statmount_buffer = ctypes.create_string_buffer(512)
request = MntIDReq(
    size=ctypes.sizeof(MntIDReq),
    spare=0,
    mnt_id=mount_id,
    param=STATMOUNT_MNT_BASIC | STATMOUNT_MNT_NS_ID,
    mnt_ns_id=info.mnt_ns_id,
)
syscall(
    457,
    ctypes.byref(request),
    statmount_buffer,
    ctypes.c_size_t(ctypes.sizeof(statmount_buffer)),
    0,
)
# statmount layout from linux/mount.h: fixed header is followed by mnt_ns_id.
statmount_size = struct.unpack_from("=I", statmount_buffer, 0)[0]
returned_mask = struct.unpack_from("=Q", statmount_buffer, 8)[0]
returned_mount_id = struct.unpack_from("=Q", statmount_buffer, 40)[0]
namespace_id = struct.unpack_from("=Q", statmount_buffer, 112)[0]
required_mask = STATMOUNT_MNT_BASIC | STATMOUNT_MNT_NS_ID
if returned_mask & required_mask != required_mask:
    raise SystemExit(f"statmount fields unavailable: mask={returned_mask:#x}")
if returned_mount_id != mount_id or namespace_id != info.mnt_ns_id:
    raise SystemExit(
        f"statmount identity mismatch: requested={mount_id} returned={returned_mount_id} "
        f"namespace={namespace_id} expected={info.mnt_ns_id}"
    )

mount_ids = (ctypes.c_uint64 * 32)()
request = MntIDReq(
    size=ctypes.sizeof(MntIDReq),
    spare=0,
    mnt_id=0xFFFFFFFFFFFFFFFF,
    param=0,
    mnt_ns_id=info.mnt_ns_id,
)
count = syscall(
    458,
    ctypes.byref(request),
    mount_ids,
    ctypes.c_size_t(len(mount_ids)),
    0,
)
if count <= 0 or mount_ids[0] == 0:
    raise SystemExit(f"listmount returned no mounts: count={count}")
if statmount_size == 0:
    raise SystemExit("statmount returned a zero result size")

pidfd = syscall(434, os.getpid(), 0, 0)
if pidfd < 0:
    raise OSError(errno.EBADF, "pidfd_open returned an invalid descriptor")
os.close(pidfd)

print(
    "kernel-capability-probe-ok "
    f"release={platform.release()} mount_id={mount_id} mount_ns={info.mnt_ns_id} "
    f"mounts={info.nr_mounts} listed={count} pidfd=available pidfd_getfd=available"
)
PY
}

__main() {
  if [[ "${1:-}" == "cleanup" ]]; then
    return
  fi

  __require_cmd sudo
  __require_cmd python3
  __require_kernel_floor
  __require_cgroup_v2
  __require_kernel_interfaces
  __probe_mount_namespace_apis
  echo "kernel-capability-smoke-validation-ok"
}

__main "$@"
