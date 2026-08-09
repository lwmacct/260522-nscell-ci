#!/usr/bin/env python3
import ctypes
import errno
import multiprocessing
import os
import queue
import tempfile


SYS_SYSINFO = 99
SYS_MOUNT = 165
SYS_OPENAT2 = 437

AT_FDCWD = -100
O_RDONLY = 0
O_CLOEXEC = 0o2000000


class OpenHow(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint64),
        ("mode", ctypes.c_uint64),
        ("resolve", ctypes.c_uint64),
    ]


libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long


def getenv_int(name, default):
    value = os.environ.get(name)
    if not value:
        return default
    return int(value)


def check_ret(name, ret, allowed_errno=()):
    if ret >= 0:
        return ret
    err = ctypes.get_errno()
    if err in allowed_errno:
        return ret
    raise OSError(err, f"{name} failed")


def syscall_sysinfo():
    buf = ctypes.create_string_buffer(256)
    ret = libc.syscall(ctypes.c_long(SYS_SYSINFO), ctypes.byref(buf))
    check_ret("sysinfo", ret)


def syscall_openat2(path):
    how = OpenHow(flags=O_RDONLY | O_CLOEXEC, mode=0, resolve=0)
    ret = libc.syscall(
        ctypes.c_long(SYS_OPENAT2),
        ctypes.c_int(AT_FDCWD),
        ctypes.c_char_p(path.encode()),
        ctypes.byref(how),
        ctypes.c_size_t(ctypes.sizeof(how)),
    )
    fd = check_ret("openat2", ret)
    try:
        os.read(fd, 64)
    finally:
        os.close(fd)


def syscall_mount_denied(target):
    ret = libc.syscall(
        ctypes.c_long(SYS_MOUNT),
        ctypes.c_char_p(b"none"),
        ctypes.c_char_p(target.encode()),
        ctypes.c_char_p(b"securityfs"),
        ctypes.c_ulong(0),
        ctypes.c_void_p(0),
    )
    check_ret("mount(securityfs)", ret, allowed_errno=(errno.EPERM,))
    if ret == 0:
        raise RuntimeError("securityfs mount unexpectedly succeeded")


def worker(index, start, errors):
    sysinfo_iterations = getenv_int("CI_SECCOMP_NOTIFY_CONCURRENCY_SYSINFO_ITERATIONS", 32)
    openat2_iterations = getenv_int("CI_SECCOMP_NOTIFY_CONCURRENCY_OPENAT2_ITERATIONS", 8)
    mount_iterations = getenv_int("CI_SECCOMP_NOTIFY_CONCURRENCY_MOUNT_ITERATIONS", 8)
    mount_root = tempfile.mkdtemp(prefix=f"nscell-seccomp-notify-concurrency-{index}-", dir="/tmp")
    mount_target = os.path.join(mount_root, "security")
    os.mkdir(mount_target)

    try:
        start.wait()
        for _ in range(sysinfo_iterations):
            syscall_sysinfo()
        for _ in range(openat2_iterations):
            syscall_openat2("/proc/uptime")
        for _ in range(mount_iterations):
            syscall_mount_denied(mount_target)
    except BaseException as exc:
        errors.put(f"worker {index}: {exc!r}")


def main():
    processes = getenv_int("CI_SECCOMP_NOTIFY_CONCURRENCY_PROCESSES", 24)
    start = multiprocessing.Event()
    errors = multiprocessing.Queue()
    children = [
        multiprocessing.Process(target=worker, args=(index, start, errors))
        for index in range(processes)
    ]
    for child in children:
        child.start()
    start.set()

    failed = False
    for child in children:
        child.join(120)
        if child.is_alive():
            child.terminate()
            failed = True
            print(f"worker pid {child.pid} timed out", flush=True)
        elif child.exitcode != 0:
            failed = True
            print(f"worker pid {child.pid} exited {child.exitcode}", flush=True)

    while True:
        try:
            print(errors.get_nowait(), flush=True)
            failed = True
        except queue.Empty:
            break

    if failed:
        raise SystemExit(1)

    total = processes * (
        getenv_int("CI_SECCOMP_NOTIFY_CONCURRENCY_SYSINFO_ITERATIONS", 32)
        + getenv_int("CI_SECCOMP_NOTIFY_CONCURRENCY_OPENAT2_ITERATIONS", 8)
        + getenv_int("CI_SECCOMP_NOTIFY_CONCURRENCY_MOUNT_ITERATIONS", 8)
    )
    print(f"seccomp-notify-concurrency-probe-ok processes={processes} notifications={total}", flush=True)


if __name__ == "__main__":
    main()
