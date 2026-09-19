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
  _version_floor="$(printf '%s\n%s\n' '7.0.0' "${_release%%-*}" | sort -V | head -1)"
  [[ "${_version_floor}" == '7.0.0' ]]
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
  local _kernel_config

  _kernel_config="/boot/config-$(uname -r)"

  test -c /dev/fuse
  test -r "$_kernel_config"
  grep -q '^CONFIG_FUSE_PASSTHROUGH=y$' "$_kernel_config"
  sudo nscell daemon host status |
    jq -e '
      .version == 3 and
      .capabilities.fuse == true and
      .capabilities.fusePassthrough == true and
      ([.probes[].id] | index("fuse-passthrough") != null)
    ' >/dev/null
}

__probe_mount_namespace_apis() {
  sudo python3 - <<'PY'
import ctypes
import errno
import fcntl
import os
import platform
import signal
import socket
import struct
import threading
import time

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

class NsIDReq(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("spare", ctypes.c_uint32),
        ("ns_id", ctypes.c_uint64),
        ("ns_type", ctypes.c_uint32),
        ("spare2", ctypes.c_uint32),
        ("user_ns_id", ctypes.c_uint64),
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
clone3_number = {"x86_64": 435, "aarch64": 435}.get(machine)
if clone3_number is None:
    raise SystemExit(f"unsupported architecture for clone3 probe: {machine}")

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

class CloneArgs(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint64),
        ("pidfd", ctypes.c_uint64),
        ("child_tid", ctypes.c_uint64),
        ("parent_tid", ctypes.c_uint64),
        ("exit_signal", ctypes.c_uint64),
        ("stack", ctypes.c_uint64),
        ("stack_size", ctypes.c_uint64),
        ("tls", ctypes.c_uint64),
        ("set_tid", ctypes.c_uint64),
        ("set_tid_size", ctypes.c_uint64),
        ("cgroup", ctypes.c_uint64),
    ]

current_cgroup = None
with open("/proc/self/cgroup", encoding="utf-8") as cgroup_file:
    for line in cgroup_file:
        hierarchy, controllers, path = line.rstrip("\n").split(":", 2)
        if hierarchy == "0" and controllers == "":
            current_cgroup = os.path.join("/sys/fs/cgroup", path.lstrip("/"))
            break
if current_cgroup is None:
    raise SystemExit("current process has no cgroup v2 membership")

CLONE_PIDFD = 0x00001000
CLONE_INTO_CGROUP = 0x200000000
clone_pidfd = ctypes.c_int(-1)
cgroup_fd = os.open(current_cgroup, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
try:
    clone_args = CloneArgs(
        flags=CLONE_PIDFD | CLONE_INTO_CGROUP,
        pidfd=ctypes.addressof(clone_pidfd),
        exit_signal=signal.SIGCHLD,
        cgroup=cgroup_fd,
    )
    ctypes.set_errno(0)
    clone_pid = libc.syscall(
        ctypes.c_long(clone3_number),
        ctypes.byref(clone_args),
        ctypes.c_size_t(ctypes.sizeof(clone_args)),
    )
    if clone_pid == 0:
        os._exit(0)
    if clone_pid == -1:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if clone_pidfd.value < 0:
        raise SystemExit("clone3 did not return a pidfd")
    try:
        waited_pid, status = os.waitpid(clone_pid, 0)
        if waited_pid != clone_pid or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise SystemExit(f"clone3 child status invalid: pid={waited_pid} status={status}")
    finally:
        os.close(clone_pidfd.value)
finally:
    os.close(cgroup_fd)

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

FUSE_DEV_IOC_SYNC_INIT = 0xE503
fuse_fd = os.open("/dev/fuse", os.O_RDWR | os.O_CLOEXEC)
try:
    ctypes.set_errno(0)
    if libc.ioctl(ctypes.c_int(fuse_fd), ctypes.c_ulong(FUSE_DEV_IOC_SYNC_INIT)) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
finally:
    os.close(fuse_fd)

OPEN_TREE_NAMESPACE = 1 << 1
OPEN_TREE_CLOEXEC = 0x80000
FSMOUNT_CLOEXEC = 1
NS_GET_NSTYPE = 0xB703
CLONE_NEWNS = 0x00020000
tree_namespace_fd = syscall(
    428,
    ctypes.c_int(-100),
    b"/",
    ctypes.c_uint(OPEN_TREE_NAMESPACE | OPEN_TREE_CLOEXEC),
)
try:
    ctypes.set_errno(0)
    namespace_type = libc.ioctl(ctypes.c_int(tree_namespace_fd), ctypes.c_ulong(NS_GET_NSTYPE))
    if namespace_type != CLONE_NEWNS:
        raise SystemExit(f"OPEN_TREE_NAMESPACE returned type {namespace_type:#x}")
finally:
    os.close(tree_namespace_fd)

pidns_fd = os.open("/proc/self/ns/pid", os.O_RDONLY | os.O_CLOEXEC)
fsfd = syscall(430, b"proc", ctypes.c_uint(1))
try:
    syscall(
        431,
        ctypes.c_int(fsfd),
        ctypes.c_uint(5),
        b"pidns",
        None,
        ctypes.c_int(pidns_fd),
    )
    syscall(431, ctypes.c_int(fsfd), ctypes.c_uint(6), None, None, ctypes.c_int(0))
    detached_proc_fd = syscall(432, ctypes.c_int(fsfd), ctypes.c_uint(FSMOUNT_CLOEXEC), ctypes.c_uint(0))
    detached_by_fd_mount = None
finally:
    os.close(pidns_fd)
    os.close(fsfd)

STATMOUNT_BY_FD = 1
STATMOUNT_MNT_POINT = 0x10
STATMOUNT_FS_TYPE = 0x20

def statmount_by_fd(fd, attached):
    param = STATMOUNT_MNT_BASIC | STATMOUNT_FS_TYPE
    if attached:
        param |= STATMOUNT_MNT_POINT | STATMOUNT_MNT_NS_ID
    output = ctypes.create_string_buffer(4096)
    request = MntIDReq(
        size=ctypes.sizeof(MntIDReq),
        spare=fd,
        mnt_id=0,
        param=param,
        mnt_ns_id=0,
    )
    syscall(
        457,
        ctypes.byref(request),
        output,
        ctypes.c_size_t(ctypes.sizeof(output)),
        ctypes.c_ulong(STATMOUNT_BY_FD),
    )
    returned = struct.unpack_from("=Q", output, 8)[0]
    returned_mount = struct.unpack_from("=Q", output, 40)[0]
    returned_namespace = struct.unpack_from("=Q", output, 112)[0]
    if returned & (STATMOUNT_MNT_BASIC | STATMOUNT_FS_TYPE) != (
        STATMOUNT_MNT_BASIC | STATMOUNT_FS_TYPE
    ) or returned_mount == 0:
        raise SystemExit(f"STATMOUNT_BY_FD fields unavailable: fd={fd} mask={returned:#x}")
    if attached and (
        returned & (STATMOUNT_MNT_POINT | STATMOUNT_MNT_NS_ID)
        != (STATMOUNT_MNT_POINT | STATMOUNT_MNT_NS_ID)
        or returned_namespace == 0
    ):
        raise SystemExit(f"attached STATMOUNT_BY_FD namespace unavailable: mask={returned:#x}")
    if not attached and (
        returned & (STATMOUNT_MNT_POINT | STATMOUNT_MNT_NS_ID) != 0
        or returned_namespace != 0
    ):
        raise SystemExit(f"detached STATMOUNT_BY_FD leaked namespace fields: mask={returned:#x}")
    return returned_mount

def statx_mount_id_by_fd(fd):
    output = ctypes.create_string_buffer(256)
    syscall(
        statx_number,
        ctypes.c_int(fd),
        ctypes.c_char_p(b""),
        ctypes.c_uint(0x1000),
        ctypes.c_uint(STATX_MNT_ID_UNIQUE),
        output,
    )
    returned_mask = struct.unpack_from("=I", output, 0)[0]
    returned_mount = struct.unpack_from("=Q", output, 144)[0]
    if returned_mask & STATX_MNT_ID_UNIQUE == 0 or returned_mount == 0:
        raise SystemExit(
            f"detached STATX_MNT_ID_UNIQUE unavailable: fd={fd} mask={returned_mask:#x}"
        )
    return returned_mount

attached_root_fd = os.open("/", os.O_PATH | os.O_CLOEXEC)
try:
    attached_by_fd_mount = statmount_by_fd(attached_root_fd, True)
finally:
    os.close(attached_root_fd)

try:
    try:
        detached_by_fd_mount = statmount_by_fd(detached_proc_fd, False)
    except OSError as error:
        if error.errno != errno.ENOENT:
            raise
    detached_proc_statx_mount = statx_mount_id_by_fd(detached_proc_fd)
finally:
    os.close(detached_proc_fd)

if attached_by_fd_mount != mount_id:
    raise SystemExit(
        f"STATMOUNT_BY_FD identity mismatch: attached={attached_by_fd_mount} statx={mount_id}"
    )
if detached_by_fd_mount is not None:
    raise SystemExit("detached procfs STATMOUNT_BY_FD unexpectedly exposed a mount namespace")

tmpfs_fsfd = syscall(430, b"tmpfs", ctypes.c_uint(1))
try:
    syscall(431, ctypes.c_int(tmpfs_fsfd), ctypes.c_uint(6), None, None, ctypes.c_int(0))
    detached_tmpfs_fd = syscall(
        432,
        ctypes.c_int(tmpfs_fsfd),
        ctypes.c_uint(FSMOUNT_CLOEXEC),
        ctypes.c_uint(0),
    )
    try:
        try:
            statmount_by_fd(detached_tmpfs_fd, False)
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise
        detached_tmpfs_statx_mount = statx_mount_id_by_fd(detached_tmpfs_fd)
    finally:
        os.close(detached_tmpfs_fd)
finally:
    os.close(tmpfs_fsfd)

listns_request = NsIDReq(
    size=ctypes.sizeof(NsIDReq),
    user_ns_id=0xFFFFFFFFFFFFFFFF,
)
namespace_ids = (ctypes.c_uint64 * 16)()
namespace_count = syscall(
    470,
    ctypes.byref(listns_request),
    namespace_ids,
    ctypes.c_size_t(len(namespace_ids)),
    ctypes.c_uint(0),
)
if namespace_count <= 0:
    raise SystemExit(f"listns returned no namespaces: count={namespace_count}")

pidfd = syscall(434, os.getpid(), 0, 0)
if pidfd < 0:
    raise OSError(errno.EBADF, "pidfd_open returned an invalid descriptor")
os.close(pidfd)

# NS_GET_ID is the kernel-owned namespace identity. It has to agree with the
# mount namespace id NS_MNT_GET_INFO reports, and it has to work for namespace
# types that have no such ioctl of their own.
def namespace_id(fd):
    raw = bytearray(8)
    fcntl.ioctl(fd, (2 << 30) | (8 << 16) | (0xB7 << 8) | 13, raw, True)
    return struct.unpack_from("=Q", raw, 0)[0]


mount_fd = os.open("/proc/self/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
try:
    if namespace_id(mount_fd) != info.mnt_ns_id:
        raise SystemExit("NS_GET_ID disagrees with NS_MNT_GET_INFO for the mount namespace")
finally:
    os.close(mount_fd)

for ns_type in ("net", "user", "pid"):
    fd = os.open(f"/proc/self/ns/{ns_type}", os.O_RDONLY | os.O_CLOEXEC)
    try:
        if namespace_id(fd) == 0:
            raise SystemExit(f"NS_GET_ID returned zero for the {ns_type} namespace")
    finally:
        os.close(fd)

# nsfs exports file handles keyed by {ns_id, ns_type, ns_inum}. A namespace must
# be reopenable from that handle without any path, and from the identity alone
# (type and inode unset, which the kernel resolves through its unified namespace
# tree) - but only while it still has a user.
name_to_handle_at = {"x86_64": 303, "aarch64": 264}.get(machine)
open_by_handle_at = {"x86_64": 304, "aarch64": 265}.get(machine)
if name_to_handle_at is None or open_by_handle_at is None:
    raise SystemExit(f"unsupported architecture for the nsfs handle probe: {machine}")

AT_EMPTY_PATH = 0x1000
FILEID_NSFS = 0xF1
MAX_HANDLE_SZ = 128
CLONE_NEWNS_FLAG = 1 << 17


def nsfs_handle(fd):
    buffer = bytearray(8 + MAX_HANDLE_SZ)
    struct.pack_into("=I", buffer, 0, MAX_HANDLE_SZ)
    mount_id_value = ctypes.c_int(0)
    syscall(
        name_to_handle_at,
        ctypes.c_int(fd),
        ctypes.c_char_p(b""),
        (ctypes.c_char * len(buffer)).from_buffer(buffer),
        ctypes.byref(mount_id_value),
        ctypes.c_int(AT_EMPTY_PATH),
    )
    handle_bytes, handle_type = struct.unpack_from("=Ii", buffer, 0)
    if handle_type != FILEID_NSFS or handle_bytes != 16:
        raise SystemExit(
            f"nsfs handle has type={handle_type:#x} bytes={handle_bytes}, want 0xf1/16"
        )
    return bytes(buffer[8 : 8 + handle_bytes])


def reopen_nsfs_handle(mountdir_fd, handle):
    request = bytearray(8 + len(handle))
    struct.pack_into("=Ii", request, 0, len(handle), FILEID_NSFS)
    request[8:] = handle
    return syscall(
        open_by_handle_at,
        ctypes.c_int(mountdir_fd),
        (ctypes.c_char * len(request)).from_buffer(request),
        ctypes.c_int(os.O_RDONLY | os.O_CLOEXEC),
    )


mount_fd = os.open("/proc/self/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
try:
    handle = nsfs_handle(mount_fd)
    handle_ns_id, handle_ns_type, _ = struct.unpack_from("=QII", handle, 0)
    if handle_ns_id != info.mnt_ns_id or handle_ns_type != CLONE_NEWNS_FLAG:
        raise SystemExit(
            f"nsfs handle identity mismatch: id={handle_ns_id} type={handle_ns_type:#x}"
        )

    for label, candidate in (
        ("decoded", handle),
        ("identity-only", struct.pack("=QII", info.mnt_ns_id, 0, 0)),
    ):
        reopened = reopen_nsfs_handle(mount_fd, candidate)
        try:
            if namespace_id(reopened) != info.mnt_ns_id:
                raise SystemExit(f"a {label} nsfs handle reopened a different namespace")
        finally:
            os.close(reopened)
finally:
    os.close(mount_fd)

# A namespace with no user left must not come back: the handle is data, not a
# reference, so once the last descriptor goes away the kernel drops the
# namespace from its trees and refuses to reopen it. This is the boundary that
# says a handle proves a namespace exists, not that one ever existed.
#
# The namespace is built with OPEN_TREE_NAMESPACE rather than unshare(2) for a
# reason: unshare(CLONE_NEWNET) fails with EINVAL in a multithreaded process,
# and this probe has already started threads by now.
gone_namespace_fd = syscall(
    428,
    ctypes.c_int(-100),
    b"/",
    ctypes.c_uint(OPEN_TREE_NAMESPACE | OPEN_TREE_CLOEXEC),
)
try:
    gone_handle = nsfs_handle(gone_namespace_fd)
finally:
    os.close(gone_namespace_fd)

deadline = time.time() + 5
while True:
    mount_fd = os.open("/proc/self/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
    try:
        try:
            reopened = reopen_nsfs_handle(mount_fd, gone_handle)
        except OSError as error:
            if error.errno not in (errno.ESTALE, errno.ENOENT, errno.EINVAL):
                raise
            break
        os.close(reopened)
        if time.time() >= deadline:
            raise SystemExit("nsfs kept reopening a namespace that no longer has a user")
        time.sleep(0.05)
    finally:
        os.close(mount_fd)

print(
    "kernel-capability-probe-ok "
    f"release={platform.release()} mount_id={mount_id} mount_ns={info.mnt_ns_id} "
    f"mounts={info.nr_mounts} listed={count} pidfd=available pidfd_getfd=available "
    f"clone3_cgroup=available open_tree_namespace=available statmount_by_fd=available "
    "proc_pidns=available detached_statmount=enoent "
    f"detached_statx={detached_proc_statx_mount}/{detached_tmpfs_statx_mount} "
    "fuse_sync_init=available "
    f"listns={namespace_count} ns_get_id=available nsfs_handle=available "
    "nsfs_handle_identity_only=available nsfs_inactive_refused=available"
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
