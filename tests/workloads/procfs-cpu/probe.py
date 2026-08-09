#!/usr/bin/env python3
import os
import re
import subprocess
import threading
import time


CGROUP_ROOT = "/sys/fs/cgroup"
IDLE_USAGE_LIMIT_PERCENT = 10.0
IDLE_BUSY_TICK_TOLERANCE = 1


def optional_env_int(name):
    value = os.environ.get(name)
    if value is None:
        return None
    return int(value)


def read_text(path):
    with open(path, "r", encoding="utf-8") as file:
        return file.read().strip()


def parse_cpuinfo_processors():
    processors = []
    with open("/proc/cpuinfo", "r", encoding="utf-8") as file:
        for line in file:
            if not line.startswith("processor"):
                continue
            fields = line.split(":", 1)
            if len(fields) != 2:
                raise RuntimeError(f"malformed processor line: {line.rstrip()}")
            processors.append(int(fields[1].strip()))
    return processors


def parse_proc_stat_cpu_indices():
    indices = []
    with open("/proc/stat", "r", encoding="utf-8") as file:
        for line in file:
            match = re.match(r"^cpu([0-9]+)\s", line)
            if match:
                indices.append(int(match.group(1)))
    return indices


def read_proc_stat_total():
    with open("/proc/stat", "r", encoding="utf-8") as file:
        line = file.readline()
    fields = line.split()
    if not fields or fields[0] != "cpu":
        raise RuntimeError(f"malformed /proc/stat cpu line: {line.rstrip()}")
    values = [int(value) for value in fields[1:]]
    if len(values) < 4:
        raise RuntimeError(f"/proc/stat cpu line has too few fields: {line.rstrip()}")
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    total = sum(values)
    busy = total - idle
    return busy, total


def cpu_usage_percent(first, second):
    busy_delta = second[0] - first[0]
    total_delta = second[1] - first[1]
    if total_delta <= 0:
        raise RuntimeError(f"non-positive /proc/stat total delta: {total_delta}")
    return busy_delta * 100.0 / total_delta


def affinity_count():
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        output = subprocess.check_output(["nproc"], text=True).strip()
        return int(output)


def assert_visible_cpu_count(expected):
    processors = parse_cpuinfo_processors()
    stat_indices = parse_proc_stat_cpu_indices()
    print(f"cpuinfo processors={processors}")
    print(f"proc_stat cpu_indices={stat_indices}")

    if len(processors) != expected:
        raise RuntimeError(f"/proc/cpuinfo exposes {len(processors)} processors, want {expected}")
    if processors != list(range(expected)):
        raise RuntimeError(f"/proc/cpuinfo processors are not renumbered from 0: {processors}")
    if len(stat_indices) != expected:
        raise RuntimeError(f"/proc/stat exposes {len(stat_indices)} per-CPU lines, want {expected}")
    if stat_indices != list(range(expected)):
        raise RuntimeError(f"/proc/stat CPU lines are not trimmed from 0: {stat_indices}")


def assert_affinity(expected_visible, should_match):
    count = affinity_count()
    cpuset = read_text(os.path.join(CGROUP_ROOT, "cpuset.cpus"))
    effective = read_text(os.path.join(CGROUP_ROOT, "cpuset.cpus.effective"))
    print(f"affinity_count={count} cpuset.cpus={cpuset!r} cpuset.cpus.effective={effective!r}")

    if should_match and count != expected_visible:
        raise RuntimeError(f"affinity CPU count={count}, want {expected_visible}")


def assert_cpu_max_present():
    cpu_max = read_text(os.path.join(CGROUP_ROOT, "cpu.max"))
    print(f"cpu.max={cpu_max}")
    if not cpu_max:
        raise RuntimeError("cpu.max is empty")


def assert_idle_cpu_usage_low():
    first = read_proc_stat_total()
    time.sleep(1.0)
    second = read_proc_stat_total()
    busy_delta = second[0] - first[0]
    total_delta = second[1] - first[1]
    if total_delta <= 0:
        if busy_delta <= IDLE_BUSY_TICK_TOLERANCE:
            print(f"idle_proc_stat_usage=0.00% first={first} second={second} zero_total_delta=true")
            return
        raise RuntimeError(f"non-positive /proc/stat total delta: {total_delta}, busy_delta={busy_delta}")

    usage = busy_delta * 100.0 / total_delta
    print(f"idle_proc_stat_usage={usage:.2f}% first={first} second={second}")
    if usage > IDLE_USAGE_LIMIT_PERCENT and busy_delta > IDLE_BUSY_TICK_TOLERANCE:
        raise RuntimeError(
            f"idle /proc/stat CPU usage is {usage:.2f}% ({busy_delta}/{total_delta} busy ticks), "
            f"want <= {IDLE_USAGE_LIMIT_PERCENT:.0f}% or <= {IDLE_BUSY_TICK_TOLERANCE} busy tick"
        )


def burn_cpu(stop_event):
    value = 0
    while not stop_event.is_set():
        value = (value * 1664525 + 1013904223) & 0xFFFFFFFF
    return value


def assert_busy_cpu_usage_near_quota():
    stop = threading.Event()
    worker = threading.Thread(target=burn_cpu, args=(stop,), daemon=True)
    worker.start()
    try:
        time.sleep(0.2)
        first = read_proc_stat_total()
        time.sleep(2.0)
        second = read_proc_stat_total()
    finally:
        stop.set()
        worker.join(timeout=1.0)

    usage = cpu_usage_percent(first, second)
    print(f"busy_proc_stat_usage={usage:.2f}% first={first} second={second}")
    if usage < 75.0 or usage > 125.0:
        raise RuntimeError(f"busy /proc/stat CPU usage is {usage:.2f}%, want near 100% of quota")


def main():
    expected_visible = optional_env_int("CI_PROCFS_CPU_EXPECT_VISIBLE")
    if expected_visible is None and os.environ.get("CI_PROCFS_CPU_EXPECT_VISIBLE_FROM_AFFINITY") == "1":
        expected_visible = affinity_count()
    if expected_visible is None:
        raise RuntimeError("missing CPU expectation: set CI_PROCFS_CPU_EXPECT_VISIBLE or CI_PROCFS_CPU_EXPECT_VISIBLE_FROM_AFFINITY=1")
    should_match = os.environ.get("CI_PROCFS_CPU_EXPECT_AFFINITY_MATCH") == "1"
    check_usage = os.environ.get("CI_PROCFS_CPU_CHECK_USAGE") == "1"
    check_idle = os.environ.get("CI_PROCFS_CPU_CHECK_IDLE") == "1"

    assert_cpu_max_present()
    assert_visible_cpu_count(expected_visible)
    assert_affinity(expected_visible, should_match)
    if check_idle:
        assert_idle_cpu_usage_low()
    if check_usage:
        assert_idle_cpu_usage_low()
        assert_busy_cpu_usage_near_quota()
    print("procfs-cpu-probe-ok")


if __name__ == "__main__":
    main()
