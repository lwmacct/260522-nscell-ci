#!/usr/bin/env bash
# shellcheck disable=SC2154 # Variables are initialized by tests/library/env.sh.

__assert_nscell_ready() {
	__log "checking nscell services"
	systemctl is-active --quiet nscell-daemon.service
	grep -q "Ready ..." "$_daemon_log"
	! grep -q "ID-mapped mounts are required" "$_daemon_log"
	! grep -q "overlayfs on ID-mapped mounts is required" "$_daemon_log"
	__wait_for_docker_runtime
}

__wait_for_docker_runtime() {
	local _attempt

	for _attempt in $(seq 1 30); do
		if docker info --format '{{json .Runtimes}}' 2>/dev/null |
			jq -e 'has("nscell")' >/dev/null; then
			return 0
		fi
		sleep 2
	done

	docker info --format '{{json .Runtimes}}' | jq -e 'has("nscell")' >/dev/null
}
