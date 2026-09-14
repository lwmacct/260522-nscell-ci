#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"

__require_kernel_floor() {
  local _release _version_floor

  _release="$(uname -r)"
  _version_floor="$(printf '%s\n%s\n' '6.12.0' "${_release%%-*}" | sort -V | head -1)"
  [[ "${_version_floor}" == '6.12.0' ]]
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
  test -r /sys/kernel/btf/vmlinux
  grep -qw bpf /sys/kernel/security/lsm
}

__probe_mount_namespace_apis() {
  sudo python3 - <<'PY'
import ctypes
import errno
import os
import platform
import struct

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
    f"mounts={info.nr_mounts} listed={count} pidfd=available"
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
