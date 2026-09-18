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

_metrics_url="http://127.0.0.1:9618/metrics"
_read_rounds=200

__cleanup() {
	docker rm -f "$_fuse_cost_attribution_name" >/dev/null 2>&1 || true
}

__metric_value() {
	local _name="$1"
	local _body="$2"
	local _value

	_value="$(awk -v _metric="${_name}" '$1 == _metric { print $2; exit }' <<<"${_body}")"
	if [[ -z "${_value}" ]]; then
		echo "metrics endpoint did not expose ${_name}" >&2
		return 1
	fi
	printf '%s\n' "${_value}"
}

__daemon_cpu_seconds() {
	local _daemon_pid _ns _ticks

	_ns="$(systemctl show nscell-daemon.service -p CPUUsageNSec --value 2>/dev/null || true)"
	if [[ "${_ns}" =~ ^[0-9]+$ ]]; then
		awk -v _ns="${_ns}" 'BEGIN { printf "%.9f", _ns / 1000000000 }'
		return
	fi
	_daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
	if [[ ! "${_daemon_pid}" =~ ^[1-9][0-9]*$ ]] || ! sudo test -r "/proc/${_daemon_pid}/stat"; then
		echo "cannot read the nscell daemon CPU time" >&2
		return 1
	fi
	# utime and stime are aggregated over the whole thread group.
	_ticks="$(sudo awk '{ print $14 + $15 }' "/proc/${_daemon_pid}/stat")"
	awk -v _ticks="${_ticks}" -v _clock="$(getconf CLK_TCK)" 'BEGIN { printf "%.9f", _ticks / _clock }'
}

__snapshot() {
	local _body _cpu

	_body="$(curl -fsS "${_metrics_url}")"
	_cpu="$(__daemon_cpu_seconds)"
	jq -n \
		--argjson _timestamp "$(date +%s)" \
		--argjson _cpu_seconds "${_cpu}" \
		--argjson _requests "$(__metric_value nscell_virtfs_fuse_requests_total "${_body}")" \
		--argjson _replies "$(__metric_value nscell_virtfs_fuse_replies_total "${_body}")" \
		--argjson _reply_bytes "$(__metric_value nscell_virtfs_fuse_reply_bytes_total "${_body}")" \
		--argjson _reply_bytes_max "$(__metric_value nscell_virtfs_fuse_reply_bytes_max "${_body}")" \
		--argjson _request_bytes_max "$(__metric_value nscell_virtfs_fuse_request_bytes_max "${_body}")" \
		'{
			timestamp: $_timestamp,
			cpuSeconds: $_cpu_seconds,
			requests: $_requests,
			replies: $_replies,
			replyBytes: $_reply_bytes,
			replyBytesMax: $_reply_bytes_max,
			requestBytesMax: $_request_bytes_max
		}'
}

__main() {
	local _after _before _report

	if [[ "${1:-}" == "cleanup" ]]; then
		__require_cmd docker
		__cleanup
		return
	fi

	__require_cmd awk
	__require_cmd curl
	__require_cmd docker
	__require_cmd jq
	__require_cmd systemctl
	__assert_nscell_ready
	__init_ci_dirs
	trap __cleanup EXIT

	__ensure_host_image "$_oci_base_image"
	__cleanup

	# The container sleeps before and after its read loop so the measurement
	# window contains serving work, not container lifecycle work.
	__log "reading VirtFS views inside a container for the cost window"
	docker run -d \
		--name "$_fuse_cost_attribution_name" \
		--runtime nscell \
		--cgroupns=private \
		--label io.backend.security.profile=default \
		"$_oci_base_image" \
		/bin/sh -c '
			set -e
			sleep 3
			_round=0
			while [ "${_round}" -lt '"${_read_rounds}"' ]; do
				cat /proc/cpuinfo /proc/meminfo /proc/stat /proc/uptime >/dev/null
				cat /proc/self/maps >/dev/null
				cat /sys/devices/system/cpu/online >/dev/null 2>&1 || true
				cat /sys/devices/system/cpu/cpu0/cache/index0/size >/dev/null 2>&1 || true
				_round=$((_round + 1))
			done
			sleep 3
		' >/dev/null

	_before="$(__snapshot)"
	if ! docker wait "$_fuse_cost_attribution_name" >/dev/null; then
		echo "cost window container did not exit cleanly" >&2
		return 1
	fi
	_after="$(__snapshot)"

	_report="$(jq -n \
		--argjson _before "${_before}" \
		--argjson _after "${_after}" \
		--argjson _us_per_roundtrip "${_fuse_cost_us_per_roundtrip}" '
		($_after.timestamp - $_before.timestamp) as $_seconds
		| ($_after.replies - $_before.replies) as $_replies
		| ($_after.cpuSeconds - $_before.cpuSeconds) as $_cpu_seconds
		| (if $_seconds > 0 then $_replies / $_seconds else 0 end) as $_rate
		| (if $_seconds > 0 then $_cpu_seconds / $_seconds else 0 end) as $_daemon_cores
		| ($_rate * $_us_per_roundtrip / 1000000) as $_fuse_cores
		| (if $_daemon_cores > 0 then $_fuse_cores / $_daemon_cores else 0 end) as $_share
		| {
			windowSeconds: $_seconds,
			replies: $_replies,
			requests: ($_after.requests - $_before.requests),
			roundtripRate: $_rate,
			daemonCpuSeconds: $_cpu_seconds,
			daemonCpuCores: $_daemon_cores,
			usPerRoundtrip: $_us_per_roundtrip,
			fuseCpuCoresEstimate: $_fuse_cores,
			fuseShareEstimate: $_share,
			replyBytesTotal: ($_after.replyBytes - $_before.replyBytes),
			replyBytesMax: $_after.replyBytesMax,
			requestBytesMax: $_after.requestBytesMax
		}')"

	if ! jq -e '
		.windowSeconds > 0 and
		.replies > 0 and
		.requests > 0 and
		.daemonCpuSeconds >= 0 and
		.fuseShareEstimate >= 0
	' <<<"${_report}" >/dev/null; then
		echo "implausible FUSE cost window: ${_report}" >&2
		return 1
	fi

	printf '%s\n' "${_report}" |
		sudo install -m 0644 /dev/stdin "${_log_root}/fuse-cost-attribution.json"

	jq -r '
		"fuse-cost-attribution window=\(.windowSeconds)s replies=\(.replies) rate=\(.roundtripRate | . * 100 | round / 100)/s",
		"  daemon CPU: \(.daemonCpuSeconds | . * 1000 | round / 1000)s = \(.daemonCpuCores * 100 | round / 100) cores",
		"  FUSE estimate: \(.usPerRoundtrip) us/roundtrip = \(.fuseCpuCoresEstimate * 1000 | round / 1000) cores",
		"  estimated FUSE share of daemon CPU: \(.fuseShareEstimate * 1000 | round / 10)%",
		"  payload maxima: request=\(.requestBytesMax)B reply=\(.replyBytesMax)B"
	' <<<"${_report}"

	trap - EXIT
	__cleanup
	echo "fuse-cost-attribution-ok"
}

__main "$@"
