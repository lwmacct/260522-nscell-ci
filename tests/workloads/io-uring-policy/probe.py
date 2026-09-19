#!/usr/bin/env python3
"""Report what a container's io_uring policy admits.

Runs inside the container (the workload image ships python3) and prints one JSON
object so the workload can assert policy without parsing prose.

Modes:
  setup   only try io_uring_setup
  matrix  submit one opcode per ring and try to register a restriction
"""

import ctypes
import json
import mmap
import struct
import sys
import time

libc = ctypes.CDLL(None, use_errno=True)

SYS_io_uring_setup = 425
SYS_io_uring_enter = 426
SYS_io_uring_register = 427

IORING_OFF_SQ_RING = 0x0
IORING_OFF_CQ_RING = 0x8000000
IORING_OFF_SQES = 0x10000000

IORING_REGISTER_RESTRICTIONS = 11
IORING_RESTRICTION_SQE_OP = 1

SQE_SIZE = 64
CQE_SIZE = 16

# enum io_uring_op (include/uapi/linux/io_uring.h), in enum order.
OPCODES = [
    ("NOP", 0),
    ("READ", 22),
    ("WRITE", 23),
    ("FSYNC", 3),
    ("OPENAT2", 28),
    ("SETXATTR", 42),
    ("URING_CMD", 46),
]

EACCES = 13


class SQOffsets(ctypes.Structure):
    _fields_ = [
        ("head", ctypes.c_uint32),
        ("tail", ctypes.c_uint32),
        ("ring_mask", ctypes.c_uint32),
        ("ring_entries", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("dropped", ctypes.c_uint32),
        ("array", ctypes.c_uint32),
        ("resv1", ctypes.c_uint32),
        ("resv2", ctypes.c_uint64),
    ]


class CQOffsets(ctypes.Structure):
    _fields_ = [
        ("head", ctypes.c_uint32),
        ("tail", ctypes.c_uint32),
        ("ring_mask", ctypes.c_uint32),
        ("ring_entries", ctypes.c_uint32),
        ("overflow", ctypes.c_uint32),
        ("cqes", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("resv1", ctypes.c_uint32),
        ("resv2", ctypes.c_uint64),
    ]


class Params(ctypes.Structure):
    _fields_ = [
        ("sq_entries", ctypes.c_uint32),
        ("cq_entries", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("sq_thread_cpu", ctypes.c_uint32),
        ("sq_thread_idle", ctypes.c_uint32),
        ("features", ctypes.c_uint32),
        ("wq_fd", ctypes.c_uint32),
        ("resv", ctypes.c_uint32 * 3),
        ("sq_off", SQOffsets),
        ("cq_off", CQOffsets),
    ]


class Ring(object):
    def __init__(self, entries=8):
        self.params = Params()
        ctypes.set_errno(0)
        self.fd = libc.syscall(SYS_io_uring_setup, entries, ctypes.byref(self.params))
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "io_uring_setup")
        sq_len = self.params.sq_off.array + self.params.sq_entries * 4
        cq_len = self.params.cq_off.cqes + self.params.cq_entries * CQE_SIZE
        self.sq_ring = mmap.mmap(self.fd, sq_len, mmap.MAP_SHARED,
                                 mmap.PROT_READ | mmap.PROT_WRITE, offset=IORING_OFF_SQ_RING)
        self.cq_ring = mmap.mmap(self.fd, cq_len, mmap.MAP_SHARED,
                                 mmap.PROT_READ | mmap.PROT_WRITE, offset=IORING_OFF_CQ_RING)
        self.sqes = mmap.mmap(self.fd, self.params.sq_entries * SQE_SIZE, mmap.MAP_SHARED,
                              mmap.PROT_READ | mmap.PROT_WRITE, offset=IORING_OFF_SQES)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        for mapping in (self.sqes, self.cq_ring, self.sq_ring):
            mapping.close()
        if self.fd >= 0:
            import os
            os.close(self.fd)

    def submit(self, opcode, wait_seconds=2.0):
        """Submit one SQE and classify what the ring did with it.

        Returns (kind, detail) where kind is one of "admitted", "denied" (the
        kernel refused it with EACCES), "no-completion" (nothing was submitted,
        which is also a refusal) or "enter-error".
        """
        tail = struct.unpack_from("<I", self.sq_ring, self.params.sq_off.tail)[0]
        mask = struct.unpack_from("<I", self.sq_ring, self.params.sq_off.ring_mask)[0]
        index = tail & mask

        sqe = bytearray(SQE_SIZE)
        sqe[0] = opcode
        struct.pack_into("<i", sqe, 4, -1)
        struct.pack_into("<Q", sqe, 32, 0x1000 + opcode)
        self.sqes.seek(index * SQE_SIZE)
        self.sqes.write(bytes(sqe))
        struct.pack_into("<I", self.sq_ring, self.params.sq_off.array + index * 4, index)
        struct.pack_into("<I", self.sq_ring, self.params.sq_off.tail, tail + 1)

        ctypes.set_errno(0)
        ret = libc.syscall(SYS_io_uring_enter, self.fd, 1, 1, 0, None, 0)
        errno = ctypes.get_errno()
        if ret < 0:
            if errno == EACCES:
                return ("denied", {"enter": ret, "errno": errno})
            return ("enter-error", {"enter": ret, "errno": errno})

        # A refused SQE is not guaranteed to post a completion, so wait for the
        # kernel to publish one before reading it - otherwise the read would
        # return the previous opcode's result.
        deadline = time.time() + wait_seconds
        while time.time() < deadline:
            head = struct.unpack_from("<I", self.cq_ring, self.params.cq_off.head)[0]
            tail = struct.unpack_from("<I", self.cq_ring, self.params.cq_off.tail)[0]
            if head != tail:
                break
            time.sleep(0.002)
        else:
            return ("no-completion", {"enter": ret, "errno": errno})

        cq_mask = struct.unpack_from("<I", self.cq_ring, self.params.cq_off.ring_mask)[0]
        offset = self.params.cq_off.cqes + (head & cq_mask) * CQE_SIZE
        result = struct.unpack_from("<i", self.cq_ring, offset + 8)[0]
        struct.pack_into("<I", self.cq_ring, self.params.cq_off.head, head + 1)
        if result == -EACCES:
            return ("denied", {"enter": ret, "res": result})
        return ("admitted", {"enter": ret, "res": result})


def register_restriction():
    """Ask for a task-scoped restriction; a container already has one."""
    # struct io_uring_task_restriction { u16 flags; u16 nr_res; u32 resv[3]; }
    # struct io_uring_restriction { u16 opcode; u8 value; u8 resv; u32 resv2[3]; }
    header = struct.pack("<HH3I", 0, 1, 0, 0, 0)
    entry = struct.pack("<HBB3I", IORING_RESTRICTION_SQE_OP, 0, 0, 0, 0, 0)
    if len(header) != 16 or len(entry) != 16:
        raise AssertionError("io_uring restriction structures must be 16 bytes each")
    buffer = ctypes.create_string_buffer(header + entry)
    ctypes.set_errno(0)
    ret = libc.syscall(SYS_io_uring_register, ctypes.c_int(-1), IORING_REGISTER_RESTRICTIONS,
                       ctypes.byref(buffer), 1)
    if ret < 0:
        return "refused:%d" % ctypes.get_errno()
    return "allowed"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "matrix"
    report = {}

    if mode == "setup":
        try:
            with Ring() as ring:
                report["setup"] = "ok"
                report["features"] = ring.params.features
        except OSError as error:
            report["setup"] = "denied:%d" % error.errno
        print(json.dumps(report))
        return 0

    try:
        with Ring() as ring:
            report["setup"] = "ok"
            outcomes = {}
            results = {}
            for name, opcode in OPCODES:
                kind, result = ring.submit(opcode)
                outcomes[name] = kind
                results[name] = result
            report["opcodes"] = outcomes
            report["results"] = results
    except OSError as error:
        report["setup"] = "denied:%d" % error.errno
        print(json.dumps(report))
        return 0

    report["register"] = register_restriction()
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
