#!/usr/bin/env python3
import os
import select
import signal
import shutil
import subprocess
import sys
import textwrap
import time


CGROUP_ROOT = "/sys/fs/cgroup"
SYSINFO_BINARY = None


def read_text(path):
    with open(path, "r", encoding="utf-8") as file:
        return file.read().strip()


def env_int(name):
    value = os.environ.get(name)
    if value is None:
        raise RuntimeError(f"missing environment variable: {name}")
    return int(value)


def read_cgroup_uint(name):
    return int(read_text(os.path.join(CGROUP_ROOT, name)))


def parse_meminfo():
    meminfo = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as file:
        for line in file:
            fields = line.split()
            if len(fields) < 2:
                continue
            meminfo[fields[0].rstrip(":")] = int(fields[1])
    return meminfo


def parse_swaps():
    with open("/proc/swaps", "r", encoding="utf-8") as file:
        lines = [line.split() for line in file if line.strip()]

    if not lines:
        raise RuntimeError("/proc/swaps is empty")
    header = lines[0]
    if header != ["Filename", "Type", "Size", "Used", "Priority"]:
        raise RuntimeError(f"unexpected /proc/swaps header: {header}")

    entries = []
    for fields in lines[1:]:
        if len(fields) != 5:
            raise RuntimeError(f"unexpected /proc/swaps row: {fields}")
        entries.append(
            {
                "filename": fields[0],
                "type": fields[1],
                "size": int(fields[2]),
                "used": int(fields[3]),
                "priority": int(fields[4]),
            }
        )
    return entries


def assert_visible_memory(expected_memtotal_kib):
    meminfo = parse_meminfo()
    memtotal_kib = meminfo.get("MemTotal")
    memfree_kib = meminfo.get("MemFree")
    memavailable_kib = meminfo.get("MemAvailable")
    memory_max = read_text(os.path.join(CGROUP_ROOT, "memory.max"))

    print(f"meminfo MemTotal={memtotal_kib}kB MemFree={memfree_kib}kB MemAvailable={memavailable_kib}kB")
    print(f"cgroup memory.max={memory_max}")

    if memory_max != str(expected_memtotal_kib * 1024):
        raise RuntimeError(f"memory.max={memory_max}, want {expected_memtotal_kib * 1024}")
    if memtotal_kib != expected_memtotal_kib:
        raise RuntimeError(f"MemTotal={memtotal_kib}kB, want {expected_memtotal_kib}kB")
    if memfree_kib is None or memfree_kib > expected_memtotal_kib:
        raise RuntimeError(f"MemFree={memfree_kib}kB is outside visible limit {expected_memtotal_kib}kB")
    if memavailable_kib is None or memavailable_kib > expected_memtotal_kib:
        raise RuntimeError(f"MemAvailable={memavailable_kib}kB is outside visible limit {expected_memtotal_kib}kB")


def assert_visible_swaps(expected_swap_total_kib=None):
    meminfo = parse_meminfo()
    entries = parse_swaps()
    swap_total_kib = meminfo.get("SwapTotal")
    swap_free_kib = meminfo.get("SwapFree")

    print(f"meminfo SwapTotal={swap_total_kib}kB SwapFree={swap_free_kib}kB")
    print(f"/proc/swaps entries={entries}")

    if swap_total_kib is None or swap_free_kib is None:
        raise RuntimeError("/proc/meminfo does not expose SwapTotal/SwapFree")
    if expected_swap_total_kib is not None and swap_total_kib != expected_swap_total_kib:
        raise RuntimeError(f"SwapTotal={swap_total_kib}kB, want {expected_swap_total_kib}kB")
    if swap_total_kib == 0:
        if entries:
            raise RuntimeError(f"/proc/swaps has entries despite SwapTotal=0: {entries}")
        return swap_total_kib, swap_free_kib, entries

    if len(entries) != 1:
        raise RuntimeError(f"/proc/swaps has {len(entries)} entries, want 1")
    entry = entries[0]
    expected_used_kib = swap_total_kib - swap_free_kib
    if entry["filename"] != "/nscell.swap" or entry["type"] != "file" or entry["priority"] != -2:
        raise RuntimeError(f"unexpected synthetic /proc/swaps entry: {entry}")
    if entry["size"] != swap_total_kib:
        raise RuntimeError(f"/proc/swaps Size={entry['size']}kB, want {swap_total_kib}kB")
    if entry["used"] != expected_used_kib:
        raise RuntimeError(f"/proc/swaps Used={entry['used']}kB, want {expected_used_kib}kB")
    if entry["used"] > entry["size"]:
        raise RuntimeError(f"/proc/swaps Used exceeds Size: {entry}")
    return swap_total_kib, swap_free_kib, entries


def compile_sysinfo_probe():
    global SYSINFO_BINARY
    if SYSINFO_BINARY is not None:
        return SYSINFO_BINARY

    compiler = shutil.which("cc")
    if compiler is None:
        raise RuntimeError("cc is required for sysinfo validation")

    source = "/tmp/nscell-ci-sysinfo-probe.c"
    binary = "/tmp/nscell-ci-sysinfo-probe"
    with open(source, "w", encoding="utf-8") as file:
        file.write(
            r"""
#include <stdio.h>
#include <sys/sysinfo.h>

int main(void) {
    struct sysinfo info;
    if (sysinfo(&info) != 0) {
        perror("sysinfo");
        return 1;
    }

    printf("sysinfo totalram=%llu freeram=%llu totalswap=%llu freeswap=%llu mem_unit=%u\n",
           (unsigned long long)info.totalram * info.mem_unit,
           (unsigned long long)info.freeram * info.mem_unit,
           (unsigned long long)info.totalswap * info.mem_unit,
           (unsigned long long)info.freeswap * info.mem_unit,
           info.mem_unit);
    return 0;
}
"""
        )
    subprocess.run([compiler, source, "-o", binary], check=True)
    SYSINFO_BINARY = binary
    return binary


def read_sysinfo():
    binary = compile_sysinfo_probe()
    result = subprocess.run([binary], check=True, capture_output=True, text=True)
    output = result.stdout.strip()
    print(output)

    return dict(
        field.split("=", 1)
        for field in output.split()
        if "=" in field
    )


def assert_sysinfo_memory(expected_memory_bytes, expected_swap_bytes=None, expected_free_swap_bytes=None):
    fields = read_sysinfo()
    totalram = int(fields["totalram"])
    totalswap = int(fields["totalswap"])
    freeswap = int(fields["freeswap"])
    mem_unit = int(fields["mem_unit"])
    if totalram != expected_memory_bytes:
        raise RuntimeError(f"sysinfo totalram={totalram}, want {expected_memory_bytes}")
    if expected_swap_bytes is not None and totalswap != expected_swap_bytes:
        raise RuntimeError(f"sysinfo totalswap={totalswap}, want {expected_swap_bytes}")
    if expected_free_swap_bytes is not None and freeswap != expected_free_swap_bytes:
        raise RuntimeError(f"sysinfo freeswap={freeswap}, want {expected_free_swap_bytes}")
    if mem_unit != 1:
        raise RuntimeError(f"sysinfo mem_unit={mem_unit}, want 1")


def cgroup_events():
    events_path = os.path.join(CGROUP_ROOT, "memory.events")
    return dict(
        line.split()
        for line in read_text(events_path).splitlines()
        if len(line.split()) == 2
    )


def run_overflow_child(alloc_bytes):
    child_code = r"""
import sys
import time

alloc_bytes = int(sys.argv[1])

chunks = []
chunk_size = 1024 * 1024
allocated = 0
while allocated < alloc_bytes:
    chunk = bytearray(chunk_size)
    for offset in range(0, len(chunk), 4096):
        chunk[offset] = 1
    chunks.append(chunk)
    allocated += len(chunk)
time.sleep(2)
sys.exit(42)
"""
    return subprocess.run(
        [sys.executable, "-c", child_code, str(alloc_bytes)],
        check=False,
    )


def start_swap_exercise_child(alloc_bytes):
    child_code = r"""
import sys
import time

alloc_bytes = int(sys.argv[1])
chunk_size = 1024 * 1024
chunks = []
allocated = 0

try:
    while allocated < alloc_bytes:
        size = min(chunk_size, alloc_bytes - allocated)
        chunk = bytearray(size)
        for offset in range(0, len(chunk), 4096):
            chunk[offset] = 1
        chunks.append(chunk)
        allocated += len(chunk)
except MemoryError:
    print(f"memory-error allocated={allocated}", flush=True)
    time.sleep(2)
    sys.exit(23)

print(f"allocated={allocated}", flush=True)
time.sleep(30)
sys.exit(0)
"""
    return subprocess.Popen(
        [sys.executable, "-c", child_code, str(alloc_bytes)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def stop_child(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def wait_for_child_allocation(process, timeout_seconds=20):
    deadline = time.monotonic() + timeout_seconds
    output = []
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], 0.1)
        if ready:
            line = process.stdout.readline()
            if line:
                output.append(line.strip())
                if line.startswith("allocated="):
                    return True, output
                if line.startswith("memory-error"):
                    return False, output
        if process.poll() is not None:
            remaining = process.stdout.read()
            if remaining:
                output.extend(line.strip() for line in remaining.splitlines())
            return False, output
        time.sleep(0.1)
    return False, output


def assert_swap_view_matches_cgroup(expected_memtotal_kib, expected_swap_total_kib):
    last_error = None
    for _ in range(20):
        try:
            swap_total_kib, swap_free_kib, entries = assert_visible_swaps(expected_swap_total_kib)
            swap_current_kib = read_cgroup_uint("memory.swap.current") // 1024
            expected_used_kib = min(swap_current_kib, swap_total_kib)
            expected_free_kib = swap_total_kib - expected_used_kib

            print(f"cgroup memory.swap.current={swap_current_kib}kB")

            if swap_free_kib != expected_free_kib:
                raise RuntimeError(f"SwapFree={swap_free_kib}kB, want {expected_free_kib}kB from memory.swap.current")
            if entries:
                entry = entries[0]
                if entry["used"] != expected_used_kib:
                    raise RuntimeError(
                        f"/proc/swaps Used={entry['used']}kB, want {expected_used_kib}kB from memory.swap.current"
                    )

            assert_sysinfo_memory(expected_memtotal_kib * 1024, swap_total_kib * 1024, swap_free_kib * 1024)
            return expected_used_kib
        except RuntimeError as error:
            message = str(error)
            if (
                "/proc/swaps Used=" not in message
                and "SwapFree=" not in message
                and "sysinfo freeswap=" not in message
            ):
                raise
            last_error = error
            time.sleep(0.25)

    raise last_error


def exercise_swap_if_requested(expected_memtotal_kib, expected_swap_total_kib, alloc_bytes):
    if os.environ.get("CI_PROCFS_MEMORY_EXERCISE_SWAP") != "1":
        return
    if expected_swap_total_kib == 0:
        print("swap-exercise-skipped reason=no-visible-swap")
        return
    if not os.path.exists(os.path.join(CGROUP_ROOT, "memory.swap.current")):
        print("swap-exercise-skipped reason=missing-memory.swap.current")
        return

    before_used_kib = read_cgroup_uint("memory.swap.current") // 1024
    process = start_swap_exercise_child(alloc_bytes)
    try:
        allocated, output = wait_for_child_allocation(process)
        if output:
            print("swap exercise child output:")
            print(textwrap.indent("\n".join(output), "  "))
        if not allocated:
            returncode = process.poll()
            print(f"swap-exercise-skipped reason=allocation-failed returncode={returncode}")
            return

        used_kib = 0
        for _ in range(20):
            used_kib = assert_swap_view_matches_cgroup(expected_memtotal_kib, expected_swap_total_kib)
            if used_kib > before_used_kib:
                print("swap-exercise-used-ok")
                return
            time.sleep(0.25)

        print(f"swap-exercise-skipped reason=no-swap-growth before={before_used_kib}kB after={used_kib}kB")
    finally:
        stop_child(process)


def assert_overflow_is_enforced(alloc_bytes):
    if not os.path.exists(os.path.join(CGROUP_ROOT, "memory.events")):
        raise RuntimeError("cgroup v2 memory.events is required for overflow validation")

    before = cgroup_events()
    result = run_overflow_child(alloc_bytes)
    after = cgroup_events()

    print(f"overflow child returncode={result.returncode}")
    if result.returncode == 42:
        raise RuntimeError("overflow child allocated beyond the container memory limit")
    if result.returncode not in (-signal.SIGKILL, 137):
        raise RuntimeError(f"overflow child was not killed by cgroup OOM: {result.returncode}")

    print("overflow memory.events:")
    print(textwrap.indent(read_text(os.path.join(CGROUP_ROOT, "memory.events")), "  "))
    before_oom_kill = int(before.get("oom_kill", "0"))
    after_oom_kill = int(after.get("oom_kill", "0"))
    if after_oom_kill <= before_oom_kill:
        raise RuntimeError(f"memory.events did not record a new oom_kill: before={before} after={after}")


def main():
    expected_memtotal_kib = env_int("CI_PROCFS_MEMORY_EXPECT_MEMTOTAL_KIB")
    overflow_alloc_bytes = env_int("CI_PROCFS_MEMORY_OVERFLOW_ALLOC_BYTES")
    expected_swap_total_kib = int(os.environ.get("CI_PROCFS_MEMORY_EXPECT_SWAPTOTAL_KIB", "0"))
    swap_exercise_alloc_bytes = int(os.environ.get("CI_PROCFS_MEMORY_EXERCISE_ALLOC_BYTES", "201326592"))
    skip_overflow = os.environ.get("CI_PROCFS_MEMORY_SKIP_OVERFLOW") == "1"

    assert_visible_memory(expected_memtotal_kib)
    swap_total_kib, swap_free_kib, _ = assert_visible_swaps(expected_swap_total_kib)
    assert_sysinfo_memory(expected_memtotal_kib * 1024, swap_total_kib * 1024, swap_free_kib * 1024)
    exercise_swap_if_requested(expected_memtotal_kib, expected_swap_total_kib, swap_exercise_alloc_bytes)
    if skip_overflow:
        print("overflow-validation-skipped")
    else:
        assert_overflow_is_enforced(overflow_alloc_bytes)
    print("procfs-memory-probe-ok")


if __name__ == "__main__":
    main()
