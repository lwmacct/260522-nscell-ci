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

_max_write_bytes=1048576
_entry_header_bytes=288

__cleanup() {
	docker rm -f "$_fuse_transport_baseline_name" >/dev/null 2>&1 || true
}

__metric_value() {
	local _name="$1"

	curl -fsS http://127.0.0.1:9618/metrics |
		awk -v _metric="$_name" '$1 == _metric { print $2; found = 1 } END { exit !found }'
}

__possible_cpus() {
	awk '{
		_total = 0
		_ranges = split($0, _range, ",")
		for (_index = 1; _index <= _ranges; _index++) {
			_bound = _range[_index]
			_dash = index(_bound, "-")
			if (_dash > 0) {
				_total += substr(_bound, _dash + 1) - substr(_bound, 1, _dash - 1) + 1
			} else {
				_total += 1
			}
		}
		print _total
	}' /sys/devices/system/cpu/possible
}

__assert_metric_bounded() {
	local _name="$1"
	local _value="$2"
	local _limit="$3"

	if ((_value <= 0 || _value > _limit)); then
		echo "${_name} is outside the negotiated FUSE write budget: ${_value}" >&2
		return 1
	fi
}

__main() {
	local _possible_cpus _payload _reply_bytes_max _request_bytes_max
	local _replies _requests

	if [[ "${1:-}" == "cleanup" ]]; then
		__require_cmd docker
		__cleanup
		return
	fi

	__require_cmd curl
	__require_cmd docker
	__assert_nscell_ready
	__init_ci_dirs
	trap __cleanup EXIT

	__ensure_host_image "$_oci_base_image"
	__cleanup

	__log "reading VirtFS views inside a container to size the FUSE transport"
	docker run --rm \
		--name "$_fuse_transport_baseline_name" \
		--runtime nscell \
		--cgroupns=private \
		"$_oci_base_image" \
		/bin/sh -c '
			set -e
			for _round in 1 2 3; do
				cat /proc/cpuinfo /proc/meminfo /proc/stat /proc/uptime >/dev/null
				cat /proc/self/maps >/dev/null
				cat /sys/devices/system/cpu/online >/dev/null 2>&1 || true
				cat /sys/devices/system/cpu/cpu0/cache/index0/size >/dev/null 2>&1 || true
				cat /sys/devices/system/cpu/cpu0/topology/physical_package_id >/dev/null 2>&1 || true
			done
		' >/dev/null

	_requests="$(__metric_value nscell_virtfs_fuse_requests_total)"
	_replies="$(__metric_value nscell_virtfs_fuse_replies_total)"
	_request_bytes_max="$(__metric_value nscell_virtfs_fuse_request_bytes_max)"
	_reply_bytes_max="$(__metric_value nscell_virtfs_fuse_reply_bytes_max)"
	_possible_cpus="$(__possible_cpus)"

	# A request message carries the FUSE and op headers on top of its payload,
	# a reply payload does not.
	__assert_metric_bounded \
		nscell_virtfs_fuse_request_bytes_max "$_request_bytes_max" "$((_max_write_bytes + 4096))"
	__assert_metric_bounded \
		nscell_virtfs_fuse_reply_bytes_max "$_reply_bytes_max" "$_max_write_bytes"

	__log "FUSE transport baseline"
	printf 'possibleCPUs=%s entryHeaderBytes=%s requests=%s replies=%s requestBytesMax=%s replyBytesMax=%s\n' \
		"$_possible_cpus" "$_entry_header_bytes" "$_requests" "$_replies" \
		"$_request_bytes_max" "$_reply_bytes_max"
	for _payload in 1048576 262144 65536 8192; do
		printf 'payloadBytes=%s perConnectionBytes=%s\n' \
			"$_payload" "$((_possible_cpus * (_entry_header_bytes + _payload)))"
	done

	printf '{"possibleCPUs":%s,"entryHeaderBytes":%s,"requests":%s,"replies":%s,"requestBytesMax":%s,"replyBytesMax":%s}\n' \
		"$_possible_cpus" "$_entry_header_bytes" "$_requests" "$_replies" \
		"$_request_bytes_max" "$_reply_bytes_max" |
		sudo install -m 0644 /dev/stdin "${_log_root}/fuse-transport-baseline.json"

	trap - EXIT
	__cleanup
	echo "fuse-transport-baseline-ok"
}

__main "$@"
