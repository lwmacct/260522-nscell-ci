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

__wait_for_container() {
	local _name="$1"
	local _state

	for _i in $(seq 1 90); do
		if ! docker inspect "$_name" --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
			docker inspect "$_name" \
				--format 'container-exited exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' >&2 || true
			docker logs "$_name" >&2 || true
			return 1
		fi
		if docker exec "$_name" test -S /run/systemd/private >/dev/null 2>&1; then
			_state="$(docker exec "$_name" systemctl is-system-running 2>/dev/null || true)"
			case "$_state" in
				running|degraded)
					echo "container-systemd-state ${_state}"
					return 0
					;;
			esac
		fi
		sleep 2
	done

	docker logs "$_name" >&2 || true
	docker exec "$_name" systemctl --no-pager --full status >&2 || true
	return 1
}

__main() {
	local _root="${_volume_root}/systemd-pid1"

	if [[ "${1:-}" == "cleanup" ]]; then
		__require_cmd docker
		docker rm -f "$_systemd_pid1_name" >/dev/null 2>&1 || true
		rm -rf "$_root"
		return
	fi

	__require_cmd docker
	__require_cmd systemctl
	__assert_nscell_ready
	__init_ci_dirs
	docker rm -f "$_systemd_pid1_name" >/dev/null 2>&1 || true
	rm -rf "$_root"
	install -d -m 0755 "$_root"
	__ensure_host_image "$_systemd_pid1_image"

	__log "running systemd as pid 1 under nscell"
	docker run -d \
		--name "$_systemd_pid1_name" \
		--hostname "$_systemd_pid1_name" \
		--runtime nscell \
		--cgroupns=private \
		--entrypoint /usr/lib/systemd/systemd \
		--tmpfs /run:rw,nosuid,nodev,mode=755,size=64m \
		--tmpfs /run/lock:rw,nosuid,nodev,noexec,mode=755,size=16m \
		--tmpfs /tmp:rw,nosuid,nodev,mode=1777,size=64m \
		-v "${_root}:/work" \
		"$_systemd_pid1_image" >/dev/null

	__wait_for_container "$_systemd_pid1_name"
	docker exec -i "$_systemd_pid1_name" sh -c \
		'cat > /usr/local/bin/nscell-ci-systemd-pid1-probe' < \
		"${_workload_path}/probe.sh"
	docker exec -i "$_systemd_pid1_name" sh -c \
		'cat > /etc/systemd/system/nscell-ci-probe.service' < \
		"${_workload_path}/probe.service"
	docker exec "$_systemd_pid1_name" sh -lc '
		set -eu
		chmod 0755 /usr/local/bin/nscell-ci-systemd-pid1-probe
		systemctl daemon-reload
	'

	docker exec "$_systemd_pid1_name" sh -lc '
	set -eu
	dpkg --audit
	test -L /lib
	test "$(readlink /lib)" = "usr/lib"
	apt-get -qq update >/dev/null
	DEBIAN_FRONTEND=noninteractive apt-get -y -qq install apparmor >/dev/null
	test -d /usr/lib/apparmor
	dpkg --audit
	_comm="$(cat /proc/1/comm)"
	if [ "$_comm" != systemd ]; then
		echo "pid 1 is not systemd: $_comm" >&2
		exit 1
	fi
	if ! awk '\''$5 == "/sys/fs/cgroup" {
		for (i = 1; i <= NF; i++) {
			if ($i == "-" && $(i + 1) == "cgroup2" && $4 == "/" && $6 ~ /(^|,)rw(,|$)/) {
				found = 1
			}
		}
	} END { exit !found }'\'' /proc/self/mountinfo; then
		echo "/sys/fs/cgroup is not delegated rw cgroup2" >&2
		exit 1
	fi
	_test_cg="/sys/fs/cgroup/nscell-ci-systemd-$$"
	trap '\''rmdir "$_test_cg" 2>/dev/null || true'\'' EXIT
	mkdir "$_test_cg"
	rmdir "$_test_cg"
	systemctl start nscell-ci-probe.service
	systemctl is-active --quiet nscell-ci-probe.service
	systemctl show nscell-ci-probe.service -p ActiveState -p SubState -p Result --no-pager
	systemctl is-active --quiet dbus.service
	systemctl is-active --quiet cron.service
	systemctl is-active --quiet rsyslog.service
	systemctl is-active --quiet ssh.service
	test -f /work/systemd-unit-probe
	stat -c "systemd-container-work %u:%g %n" /work /work/systemd-unit-probe
	systemctl list-units --type=service --no-pager | grep -F nscell-ci-probe.service
	systemctl list-units --type=service --state=running --no-pager
	echo "systemd-container-cgroup-ok"
	echo "systemd-unit-ok"
'

	stat -c 'systemd-pid1-host-probe %u:%g %n' "${_root}/systemd-unit-probe"
	__assert_nscell_ready
	echo "systemd-pid1-validation-ok"
}

__main "$@"
