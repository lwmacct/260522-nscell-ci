#!/usr/bin/env bash
# shellcheck disable=SC2154 # Variables are initialized by tests/library/env.sh.
set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"

# The daemon names a container by its first twelve characters, and a bundled
# group runs several workloads against one daemon log, so the diagnostic scan
# below has to name the container it is about: a container another workload
# tears down on purpose is not a defect of this one.
__short_id() {
	local _id="${1#*:}"

	printf '%s\n' "${_id:0:12}"
}

__main() {
	local _log_start
	local _short_id

	if [[ "${1:-}" == "cleanup" ]]; then
		__require_cmd docker
		docker rm -f "$_seccomp_notify_concurrency_name" >/dev/null 2>&1 || true
		return
	fi

	__require_cmd docker
	__assert_nscell_ready
	__init_ci_dirs

	_log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
	docker rm -f "$_seccomp_notify_concurrency_name" >/dev/null 2>&1 || true
	__build_ci_image "$_seccomp_notify_concurrency_image" "${_workload_dir}/workloads/seccomp-notify-concurrency" --build-arg "BASE_IMAGE=${_seccomp_notify_concurrency_base_image}"

	__log "running concurrent seccomp notification workload"
	docker run \
		--name "$_seccomp_notify_concurrency_name" \
		--hostname "$_seccomp_notify_concurrency_name" \
		--runtime nscell \
		--cgroupns=private \
		-e "CI_SECCOMP_NOTIFY_CONCURRENCY_PROCESSES=${_seccomp_notify_concurrency_processes}" \
		-e "CI_SECCOMP_NOTIFY_CONCURRENCY_SYSINFO_ITERATIONS=${_seccomp_notify_concurrency_sysinfo_iterations}" \
		-e "CI_SECCOMP_NOTIFY_CONCURRENCY_OPENAT2_ITERATIONS=${_seccomp_notify_concurrency_openat2_iterations}" \
		-e "CI_SECCOMP_NOTIFY_CONCURRENCY_MOUNT_ITERATIONS=${_seccomp_notify_concurrency_mount_iterations}" \
		"$_seccomp_notify_concurrency_image"
	_short_id="$(__short_id "$(docker inspect --format '{{.Id}}' "$_seccomp_notify_concurrency_name")")"
	docker rm -f "$_seccomp_notify_concurrency_name" >/dev/null

	__log "checking seccomp notify concurrency diagnostics"
	if tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null |
		grep -E "Seccomp notification timed out|nsenter broker concurrency limit reached|in-flight limit reached|dispatcher queue full|invalid tracee|seccomp response already sent" |
		grep -F "container ${_short_id}" >&2; then
		echo "seccomp notify concurrency workload produced forbidden daemon diagnostics" >&2
		exit 1
	fi

	__assert_nscell_ready
	echo "seccomp-notify-concurrency-validation-ok"
}

__main "$@"
