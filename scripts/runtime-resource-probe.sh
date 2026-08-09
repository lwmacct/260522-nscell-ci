#!/usr/bin/env bash
set -euo pipefail

_strict="${STRICT:-1}"
_log_dir="${PROBE_LOG_DIR:-/tmp/runtime-resource-probe}"
_summary="${_log_dir}/summary.log"
_failures=()
_cleanup_actions=()

__log() {
	printf '\n==> %s\n' "$*" | tee -a "$_summary"
}

__record_failure() {
	local _name="$1"
	local _detail="${2:-}"

	_failures+=("$_name")
	{
		printf 'FAILED: %s\n' "$_name"
		if [[ -n "$_detail" ]]; then
			printf '%s\n' "$_detail"
		fi
	} | tee -a "$_summary" >&2
}

__run_required() {
	local _name="$1"
	shift

	__log "$_name"
	if "$@" >"${_log_dir}/${_name}.log" 2>&1; then
		tee -a "$_summary" <"${_log_dir}/${_name}.log"
		return
	fi
	__record_failure "$_name" "$(cat "${_log_dir}/${_name}.log")"
}

__cleanup() {
	local _action

	for _action in "${_cleanup_actions[@]}"; do
		eval "$_action" >/dev/null 2>&1 || true
	done
}

__probe_host() {
	id
	uname -a
	cat /etc/os-release
	df -h /
	free -h || true
	nproc
	systemctl --version | head -1
	docker version
	docker info
}

__probe_bpf() {
	test -r /sys/kernel/btf/vmlinux
	findmnt /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
	findmnt /sys/fs/bpf
	test -r /sys/kernel/security/lsm
	cat /sys/kernel/security/lsm
	grep -qw bpf /sys/kernel/security/lsm
}

__probe_docker_runtime() {
	local _runtime="/usr/local/bin/ci-runtime-wrapper"
	local _runc
	local _daemon_config="/etc/docker/daemon.json"
	local _backup="${_log_dir}/docker-daemon.json.before"

	_runc="$(command -v runc)"
	cp "$_daemon_config" "$_backup" 2>/dev/null || true
	_cleanup_actions+=("cp '$_backup' '$_daemon_config' 2>/dev/null || rm -f '$_daemon_config'; systemctl restart docker")

	cat >"$_runtime" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s %q\n' "\$(date -Is)" "\$*" >>/tmp/ci-runtime-wrapper.log
exec "$_runc" "\$@"
EOF
	chmod 0755 "$_runtime"

	if [[ -s "$_daemon_config" ]]; then
		jq '.runtimes = ((.runtimes // {}) | .["ci-runtime-wrapper"] = {"path": "/usr/local/bin/ci-runtime-wrapper", "runtimeArgs": []})' \
			"$_daemon_config" >"${_daemon_config}.tmp"
	else
		jq -n '{"runtimes": {"ci-runtime-wrapper": {"path": "/usr/local/bin/ci-runtime-wrapper", "runtimeArgs": []}}}' \
			>"${_daemon_config}.tmp"
	fi
	install -m 0644 "${_daemon_config}.tmp" "$_daemon_config"
	rm -f "${_daemon_config}.tmp"

	systemctl restart docker
	docker info --format '{{json .Runtimes}}' | jq -e 'has("ci-runtime-wrapper")'
	docker run --rm --runtime ci-runtime-wrapper alpine:3.20 true
	test -s /tmp/ci-runtime-wrapper.log
	cat /tmp/ci-runtime-wrapper.log
}

__probe_privileged_container() {
	docker run --rm --privileged alpine:3.20 sh -lc '
		set -eu
		mkdir -p /mnt/probe
		mount -t tmpfs tmpfs /mnt/probe
		touch /mnt/probe/ok
		umount /mnt/probe
	'
}

__probe_idmapped_mount() {
	local _tmp
	local _probe_c="${_log_dir}/idmap_probe.c"
	local _probe_bin="${_log_dir}/idmap_probe"

	_tmp="$(mktemp -d)"
	_cleanup_actions+=("umount -l '$_tmp/overlay' 2>/dev/null || true; umount -l '$_tmp/idmap' 2>/dev/null || true; rm -rf '$_tmp'")
	mkdir -p "$_tmp/src" "$_tmp/idmap" "$_tmp/upper" "$_tmp/work" "$_tmp/overlay"
	touch "$_tmp/src/file"

	cat >"$_probe_c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/mount.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static int write_file(const char *path, const char *data) {
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		perror(path);
		return -1;
	}
	size_t len = strlen(data);
	if (write(fd, data, len) != (ssize_t)len) {
		perror(path);
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

int main(int argc, char **argv) {
	if (argc != 3) {
		fprintf(stderr, "usage: %s <source> <target>\n", argv[0]);
		return 2;
	}

	pid_t child = syscall(SYS_clone, CLONE_NEWUSER | SIGCHLD, NULL, NULL, NULL, 0);
	if (child < 0) {
		perror("clone(CLONE_NEWUSER)");
		return 1;
	}
	if (child == 0) {
		pause();
		_exit(0);
	}

	char path[128];
	snprintf(path, sizeof(path), "/proc/%d/setgroups", child);
	write_file(path, "deny\n");
	snprintf(path, sizeof(path), "/proc/%d/uid_map", child);
	if (write_file(path, "0 100000 1\n") != 0) {
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}
	snprintf(path, sizeof(path), "/proc/%d/gid_map", child);
	if (write_file(path, "0 100000 1\n") != 0) {
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}
	snprintf(path, sizeof(path), "/proc/%d/ns/user", child);
	int userns_fd = open(path, O_RDONLY | O_CLOEXEC);
	if (userns_fd < 0) {
		perror("open user namespace");
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}

	int mount_fd = syscall(SYS_open_tree, AT_FDCWD, argv[1], OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC);
	if (mount_fd < 0) {
		perror("open_tree");
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}

	struct mount_attr attr = {
		.attr_set = MOUNT_ATTR_IDMAP,
		.userns_fd = (unsigned long long)userns_fd,
	};
	if (syscall(SYS_mount_setattr, mount_fd, "", AT_EMPTY_PATH, &attr, sizeof(attr)) != 0) {
		perror("mount_setattr(MOUNT_ATTR_IDMAP)");
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}

	if (syscall(SYS_move_mount, mount_fd, "", AT_FDCWD, argv[2], MOVE_MOUNT_F_EMPTY_PATH) != 0) {
		perror("move_mount");
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}

	kill(child, SIGKILL);
	waitpid(child, NULL, 0);
	return 0;
}
EOF
	gcc -Wall -Wextra -O2 -o "$_probe_bin" "$_probe_c"
	"$_probe_bin" "$_tmp/src" "$_tmp/idmap"
	findmnt -T "$_tmp/idmap"
	mount -t overlay overlay \
		-o "lowerdir=$_tmp/idmap,upperdir=$_tmp/upper,workdir=$_tmp/work" \
		"$_tmp/overlay"
	findmnt -T "$_tmp/overlay"
	test -f "$_tmp/overlay/file"
}

__main() {
	install -d -m 0755 "$_log_dir"
	: >"$_summary"
	trap __cleanup EXIT

	__run_required host __probe_host
	__run_required bpf __probe_bpf
	__run_required docker-runtime __probe_docker_runtime
	__run_required privileged-container __probe_privileged_container
	__run_required idmapped-overlay __probe_idmapped_mount

	if (( ${#_failures[@]} > 0 )); then
		printf '\nMissing runtime capabilities:\n' | tee -a "$_summary" >&2
		printf '  %s\n' "${_failures[@]}" | tee -a "$_summary" >&2
		if [[ "$_strict" == "1" ]]; then
			exit 1
		fi
	fi

	printf '\nruntime-resource-probe-ok\n' | tee -a "$_summary"
}

__main "$@"
