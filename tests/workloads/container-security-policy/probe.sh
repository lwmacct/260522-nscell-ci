#!/bin/sh
set -eu

__check_cgroup() {
	if ! awk '$5 == "/sys/fs/cgroup" {
		for (i = 1; i <= NF; i++) {
			if ($i == "-" && $(i + 1) == "cgroup2" && $4 == "/" && $6 ~ /(^|,)rw(,|$)/) {
				found = 1
			}
		}
	} END { exit !found }' /proc/self/mountinfo; then
		echo "/sys/fs/cgroup is not a rw cgroup2 mount rooted at the cgroup namespace root" >&2
		exit 1
	fi
	_cg_path="$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup)"
	case "$_cg_path" in
		*docker*|*containerd*|*kubepods*|*system.slice*)
			echo "/proc/self/cgroup leaked host cgroup path: $_cg_path" >&2
			exit 1
			;;
	esac
	[ -d /sys/fs/cgroup/init.scope ]
	_test_cg="/sys/fs/cgroup/nscell-ci-delegation-$$"
	trap 'rmdir "$_test_cg" 2>/dev/null || true' EXIT
	mkdir "$_test_cg"
	[ -d "$_test_cg" ]
	rmdir "$_test_cg"
	echo "cgroup-subtree-ok"
}

__check_resources() {
	_base="/tmp/nscell-ci-resource-negative-$$"
	trap 'umount "$_base"/unsafe-* "$_base/cgroup-rw" "$_base/cgroup-root-bind" "$_base/overlay2/id/merged/dev/kmsg" "$_base/netns/not-net" 2>/dev/null || true; rm -rf "$_base"' EXIT
	mkdir -p "$_base/cgroup-rw" "$_base/cgroup-root-bind" "$_base/overlay2/id/merged/dev" "$_base/netns"
	: >"$_base/overlay2/id/merged/dev/kmsg"
	: >"$_base/netns/not-net"

	for _fs in securityfs debugfs tracefs configfs; do
		_target="$_base/unsafe-$_fs"
		mkdir -p "$_target"
		__check_unsafe_mount "$_fs" "$_target"
	done

	if mount -t cgroup2 cgroup "$_base/cgroup-rw" 2>"$_base/cgroup-rw.err"; then
		echo "writable cgroup2 mount unexpectedly succeeded" >&2
		exit 1
	fi

	if mount --bind /sys/fs/cgroup "$_base/cgroup-root-bind" 2>"$_base/cgroup-root-bind.err"; then
		echo "host cgroup root bind unexpectedly succeeded" >&2
		exit 1
	fi

	if mount --bind /dev/null "$_base/overlay2/id/merged/dev/kmsg" 2>"$_base/device.err"; then
		echo "invalid device bind unexpectedly succeeded" >&2
		exit 1
	fi

	if mount --bind /proc/self/ns/mnt "$_base/netns/not-net" 2>"$_base/netns.err"; then
		echo "non-netns namespace bind unexpectedly succeeded" >&2
		exit 1
	fi

	echo "resource-negative-policy-ok"
}

__check_cgroup_subtree_mount_policy() {
	_base="/tmp/nscell-ci-cgroup-subtree-$$"
	_leaf="/sys/fs/cgroup/nscell-ci-bpf-subtree-$$"
	trap 'printf "%s\n" "$$" >/sys/fs/cgroup/cgroup.procs 2>/dev/null || true; umount "$_base"/unsafe-* 2>/dev/null || true; rmdir "$_leaf" 2>/dev/null || true; rm -rf "$_base"' EXIT
	mkdir -p "$_base" "$_leaf"
	printf '%s\n' "$$" >"$_leaf/cgroup.procs"

	for _fs in securityfs debugfs tracefs configfs; do
		_target="$_base/unsafe-$_fs"
		mkdir -p "$_target"
		__check_unsafe_mount "$_fs" "$_target"
	done

	echo "cgroup-subtree-mount-policy-ok"
}

__check_unsafe_mount() {
	python3 - "$1" "$2" <<'PY'
import ctypes
import errno
import sys

fs_type, target = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_void_p]
libc.mount.restype = ctypes.c_int
ctypes.set_errno(0)
result = libc.mount(fs_type.encode(), target.encode(), fs_type.encode(), 0, None)
error = ctypes.get_errno()
if result != -1 or error != errno.EPERM:
    raise SystemExit(f"{fs_type} mount: result={result} errno={error}, want EPERM")
PY
}

__expect_eperm_path() {
	_path="$1"
	_marker="$2"
	_status=0
	set +e
	python3 - "$_path" <<'PY'
import errno
import os
import sys

path = sys.argv[1]
flags = os.O_RDONLY | os.O_CLOEXEC
if os.path.basename(path) == "sysrq-trigger":
    flags = os.O_WRONLY | os.O_CLOEXEC
try:
    fd = os.open(path, flags)
except OSError as exc:
    if exc.errno == errno.ENOENT:
        sys.exit(10)
    if exc.errno == errno.EPERM:
        sys.exit(0)
    print(f"{path}: errno {exc.errno}, want EPERM", file=sys.stderr)
    sys.exit(1)
else:
    os.close(fd)
    print(f"{path}: access unexpectedly succeeded", file=sys.stderr)
    sys.exit(2)
PY
	_status="$?"
	set -e
	if [ "$_status" -eq 0 ]; then
		echo "kernel-interface-denied $_marker"
		return 0
	fi
	if [ "$_status" -eq 10 ]; then
		return 0
	fi
	exit "$_status"
}

__check_kernel_interface_files() {
	__expect_eperm_path /sys/kernel/security/lsm lsm
	awk '
		{
			sep = 0
			for (i = 1; i <= NF; i++) {
				if ($i == "-") {
					sep = i
					break
				}
			}
			if (!sep) {
				next
			}
			fstype = $(sep + 1)
			if (fstype == "securityfs" || fstype == "debugfs" || fstype == "tracefs" || fstype == "configfs") {
				print fstype " " $5
			}
		}
	' /proc/self/mountinfo | while read -r _fs _path; do
		__expect_eperm_path "$_path" "$_fs"
	done
	echo "kernel-interface-file-policy-ok"
}

__check_cgroup_subtree_kernel_interface_files() {
	_leaf="/sys/fs/cgroup/nscell-ci-bpf-file-subtree-$$"
	trap 'printf "%s\n" "$$" >/sys/fs/cgroup/cgroup.procs 2>/dev/null || true; rmdir "$_leaf" 2>/dev/null || true' EXIT
	mkdir -p "$_leaf"
	printf '%s\n' "$$" >"$_leaf/cgroup.procs"
	__check_kernel_interface_files
	echo "cgroup-subtree-kernel-interface-file-policy-ok"
}

__check_xattr_negative_policy() {
	python3 - <<'PY'
import errno
import os
import sys

base = f"/tmp/nscell-ci-xattr-negative-{os.getpid()}"
path = os.path.join(base, "target")
name = b"user.nscell_ci_denied"

os.makedirs(base, exist_ok=True)
with open(path, "wb") as f:
    f.write(b"data")

checks = (
    ("setxattr", lambda: os.setxattr(path, name, b"blocked")),
    ("getxattr", lambda: os.getxattr(path, name)),
    ("removexattr", lambda: os.removexattr(path, name)),
)
for op, fn in checks:
    try:
        fn()
    except OSError as exc:
        if exc.errno == errno.EPERM:
            continue
        print(f"{op} returned errno {exc.errno}, want EPERM", file=sys.stderr)
        raise
    raise RuntimeError(f"{op} unexpectedly succeeded for non-whitelisted xattr")

# Listing is what tools do before they read a name. NSCell mediates named
# operations (the checks above) but has to leave the listing to the kernel:
# turning it into EPERM breaks every caller that enumerates xattrs first
# (docker build's filesync sender is one), and the container only learns the
# names of its own objects. Reading any value still goes through the checks.
os.listxattr(path)

print("xattr-negative-policy-ok")
PY
}

__check_xattr_trusted_overlay_policy() {
	python3 - <<'PY'
import errno
import os
import shutil

base = f"/var/lib/docker/overlay2/nscell-ci-xattr-{os.getpid()}"
diff = os.path.join(base, "diff")
name = b"trusted.overlay.origin"
value = b"y"

try:
    os.makedirs(diff, exist_ok=True)
    try:
        os.setxattr(diff, name, value)
    except OSError as exc:
        if exc.errno == errno.EPERM:
            raise RuntimeError("trusted overlay xattr was denied by BPF policy") from exc
    try:
        os.getxattr(diff, name)
    except OSError as exc:
        if exc.errno == errno.EPERM:
            raise RuntimeError("trusted overlay xattr read was denied by BPF policy") from exc
    try:
        os.removexattr(diff, name)
    except OSError as exc:
        if exc.errno == errno.EPERM:
            raise RuntimeError("trusted overlay xattr removal was denied by BPF policy") from exc
finally:
    shutil.rmtree(base, ignore_errors=True)

print("xattr-trusted-overlay-policy-ok")
PY
}

__reject_write() {
	_path="$1"
	[ -e "$_path" ] || return 0
	if ! awk -v target="$_path" '$5 == target && $6 ~ /(^|,)ro($|,)/ { found = 1 } END { exit !found }' /proc/self/mountinfo; then
		echo "host-global sysctl deny path is not a readonly mount: $_path" >&2
		exit 1
	fi
	_value="$(cat "$_path" 2>/dev/null || true)"
	if sh -c 'printf "%s\n" "$1" > "$2"' sh "$_value" "$_path" 2>/tmp/nscell-sysctl-write.err; then
		echo "host-global sysctl write unexpectedly succeeded: $_path" >&2
		exit 1
	fi
}

__check_proc_sys() {
	if mount | grep -q "nscellfs on /proc/sys "; then
		echo "unexpected nscellfs mount on /proc/sys" >&2
		exit 1
	fi
	for _path in ${real_namespaced_sysctls:-}; do
		[ -e "$_path" ] || continue
		cat "$_path" >/dev/null
	done
	for _path in ${host_global_deny_sysctls:-}; do
		__reject_write "$_path"
	done
	echo "proc-sys-security-ok"
}

__check_control_plane_isolation() {
	for _path in /run/nscell/daemon.sock /run/nscell/containers; do
		if [ -e "$_path" ] || [ -L "$_path" ]; then
			echo "NSCell host control path is visible in the container: $_path" >&2
			exit 1
		fi
	done

	for _fd in /proc/1/fd/*; do
		case "$_fd" in
		/proc/1/fd/0 | /proc/1/fd/1 | /proc/1/fd/2)
			;;
		*)
			_target="$(readlink "$_fd" 2>/dev/null || true)"
			echo "container init inherited unexpected fd: $_fd -> $_target" >&2
			exit 1
			;;
		esac
	done

	for _fd in /proc/self/fd/*; do
		_target="$(readlink "$_fd" 2>/dev/null || true)"
		case "$_target" in
		*/run/nscell/*)
			echo "NSCell host control fd is inherited by the container: $_fd -> $_target" >&2
			exit 1
			;;
		esac
	done

	echo "control-plane-isolation-ok"
}

__check_process_identity_isolation() {
	if [ "$(id -u)" -ne 0 ] || [ "$(id -g)" -ne 0 ]; then
		echo "identity probe must run as container uid/gid 0" >&2
		exit 1
	fi

	read -r _uid_container _uid_host _uid_size </proc/self/uid_map
	read -r _gid_container _gid_host _gid_size </proc/self/gid_map
	for _value in \
		"$_uid_container" "$_uid_host" "$_uid_size" \
		"$_gid_container" "$_gid_host" "$_gid_size"; do
		case "$_value" in
		"" | *[!0-9]*)
			echo "invalid process id mapping value: $_value" >&2
			exit 1
			;;
		esac
	done

	if [ "$_uid_container" -ne 0 ] || [ "$_gid_container" -ne 0 ]; then
		echo "container root mapping does not start at uid/gid 0" >&2
		exit 1
	fi
	if [ "$_uid_host" -eq 0 ] || [ "$_gid_host" -eq 0 ]; then
		echo "container root process maps to host uid/gid 0" >&2
		exit 1
	fi
	if [ "$_uid_host" -ne "$_gid_host" ]; then
		echo "container process uid/gid mappings use different host bases" >&2
		exit 1
	fi
	if [ "$_uid_size" -lt 65536 ] || [ "$_gid_size" -lt 65536 ]; then
		echo "container process uid/gid mapping range is smaller than 65536" >&2
		exit 1
	fi

	echo "process-identity-isolation-ok host-base=${_uid_host} size=${_uid_size}"
}

__main() {
	case "${1:-}" in
		cgroup-delegation)
			__check_cgroup
			;;
		privileged-resource-negative-policy)
			__check_resources
			;;
		cgroup-subtree-mount-policy)
			__check_cgroup_subtree_mount_policy
			;;
		kernel-interface-file-policy)
			__check_kernel_interface_files
			;;
		cgroup-subtree-kernel-interface-file-policy)
			__check_cgroup_subtree_kernel_interface_files
			;;
		xattr-negative-policy)
			__check_xattr_negative_policy
			;;
		xattr-trusted-overlay-policy)
			__check_xattr_trusted_overlay_policy
			;;
		proc-sys-policy)
			__check_proc_sys
			;;
		control-plane-isolation)
			__check_control_plane_isolation
			;;
		process-identity-isolation)
			__check_process_identity_isolation
			;;
		*)
			echo "usage: $0 {cgroup-delegation|privileged-resource-negative-policy|cgroup-subtree-mount-policy|kernel-interface-file-policy|cgroup-subtree-kernel-interface-file-policy|xattr-negative-policy|xattr-trusted-overlay-policy|proc-sys-policy|control-plane-isolation|process-identity-isolation}" >&2
			exit 2
			;;
	esac
}

__main "$@"
