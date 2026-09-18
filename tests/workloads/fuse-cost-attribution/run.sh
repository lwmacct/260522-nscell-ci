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
_perf_seconds=12

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
	local _audit _body _cpu _opcodes

	_body="$(curl -fsS "${_metrics_url}")"
	_cpu="$(__daemon_cpu_seconds)"
	_audit="$(awk '/^nscell_bpf_gate_audit_events_total/ { _sum += $2 } END { print _sum + 0 }' <<<"${_body}")"
	_opcodes="$(awk '
		match($1, /^nscell_virtfs_fuse_requests_by_opcode_total/) {
			_label = $1
			sub(/^.*opcode="/, "", _label)
			sub(/".*$/, "", _label)
			printf "%s %s\n", _label, $2
		}
	' <<<"${_body}" | jq -R -s '
		split("\n")
		| map(select(length > 0) | split(" "))
		| map({key: .[0], value: (.[1] | tonumber)})
		| from_entries
	')"
	jq -n \
		--argjson _timestamp "$(date +%s)" \
		--argjson _cpu_seconds "${_cpu}" \
		--argjson _requests "$(__metric_value nscell_virtfs_fuse_requests_total "${_body}")" \
		--argjson _replies "$(__metric_value nscell_virtfs_fuse_replies_total "${_body}")" \
		--argjson _reply_bytes "$(__metric_value nscell_virtfs_fuse_reply_bytes_total "${_body}")" \
		--argjson _reply_bytes_max "$(__metric_value nscell_virtfs_fuse_reply_bytes_max "${_body}")" \
		--argjson _request_bytes_max "$(__metric_value nscell_virtfs_fuse_request_bytes_max "${_body}")" \
		--argjson _audit "$_audit" \
		--argjson _opcodes "${_opcodes}" \
		'{
			timestamp: $_timestamp,
			cpuSeconds: $_cpu_seconds,
			requests: $_requests,
			replies: $_replies,
			replyBytes: $_reply_bytes,
			replyBytesMax: $_reply_bytes_max,
			requestBytesMax: $_request_bytes_max,
			auditEvents: $_audit,
			opcodes: $_opcodes
		}'
}

# perf is optional: the standard VM may not ship a matching linux-tools build.
__perf_available() {
	command -v perf >/dev/null 2>&1
}

__perf_record() {
	local _file="$1"
	local _mode_file="$2"
	local _pid="$3"
	local _seconds="$4"

	if sudo perf record -F 99 -g -o "${_file}" -p "${_pid}" -- sleep "${_seconds}" >/dev/null 2>&1; then
		printf 'full\n' >"${_mode_file}"
		return 0
	fi
	# Some kernels restrict kernel sampling even for root; user stacks still
	# separate VirtFS serving work from everything else.
	if sudo perf record -F 99 -g -e cycles:u -o "${_file}" -p "${_pid}" -- \
		sleep "${_seconds}" >/dev/null 2>&1; then
		printf 'user\n' >"${_mode_file}"
		return 0
	fi
	printf 'unavailable\n' >"${_mode_file}"
}

__perf_report() {
	local _file="$1"

	if [[ ! -s "${_file}" ]]; then
		printf 'unavailable\n'
		return
	fi
	sudo perf script -i "${_file}" 2>/dev/null |
		awk '
			/^[^ \t]/ { if (_hit) { _hits++ } ; _total++ ; _hit = 0 ; next }
			/internal\/fuse|fuse_dev|fuse_simple|fuse_lookup|fuse_perform|fuse_read|fuse_write|fuse_uring/ { _hit = 1 }
			END { if (_hit) { _hits++ } ; printf "%d %d\n", (_total + 0), (_hits + 0) }
		'
}

# __perf_open_callers attributes the samples that end in openat(2) to the first
# userspace frame of their stack, so a cache that still misses shows its caller.
__perf_open_callers() {
	local _file="$1"

	sudo perf script -i "${_file}" 2>/dev/null | awk '
		/^[^ \t]/ {
			if (_saw_open && _caller != "") { _counts[_caller]++ }
			_saw_open = 0
			_caller = ""
			next
		}
		/openat|openFileNolog|hostFileCache/ { _saw_open = 1 }
		/internal\/[a-z]+\// && _caller == "" { _caller = $NF }
		END {
			if (_saw_open && _caller != "") { _counts[_caller]++ }
			for (_name in _counts) { printf "%d %s\n", _counts[_name], _name }
		}
	' | sort -rn | awk 'NR <= 5' || true
}

__main() {
	local _after _before _perf_pid _perf_samples _report

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

	_daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
	_perf_file="${_log_root}/fuse-cost-attribution.perf.data"
	_perf_mode_file="${_log_root}/fuse-cost-attribution.perf.mode"
	rm -f "${_perf_file}" "${_perf_mode_file}"
	_before="$(__snapshot)"
	if __perf_available; then
		__perf_record "${_perf_file}" "${_perf_mode_file}" "${_daemon_pid}" "${_perf_seconds}" &
		_perf_pid=$!
	fi
	if ! docker wait "$_fuse_cost_attribution_name" >/dev/null; then
		echo "cost window container did not exit cleanly" >&2
		return 1
	fi
	_after="$(__snapshot)"
	_perf_mode="unavailable"
	_perf_samples="unavailable"
	if [[ -n "${_perf_pid:-}" ]]; then
		wait "${_perf_pid}" 2>/dev/null || true
		_perf_mode="$(cat "${_perf_mode_file}" 2>/dev/null || printf 'unavailable')"
		if [[ "${_perf_mode}" != "unavailable" ]]; then
			_perf_samples="$(__perf_report "${_perf_file}")"
			# The released binary is stripped and UPX-compressed, so symbol
			# names only resolve for the kernel side; the DSO split still
			# separates daemon code from kernel and libc.
			sudo perf report --stdio -i "${_perf_file}" --sort dso --percent-limit 1 \
				>"${_log_root}/fuse-cost-attribution.perf-dso.txt" 2>/dev/null || true
			sudo perf report --stdio -i "${_perf_file}" --sort symbol --percent-limit 1 \
				>"${_log_root}/fuse-cost-attribution.perf-symbol.txt" 2>/dev/null || true
			sudo perf report --stdio -i "${_perf_file}" --sort symbol --percent-limit 20 \
				>"${_log_root}/fuse-cost-attribution.perf-open-callers.txt" 2>/dev/null || true
			__perf_open_callers "${_perf_file}" \
				>"${_log_root}/fuse-cost-attribution.perf-open-attribution.txt" 2>/dev/null || true
		fi
	fi

	_report="$(jq -n \
		--argjson _before "${_before}" \
		--argjson _after "${_after}" \
		--arg _perf_samples "${_perf_samples}" \
		--arg _perf_mode "${_perf_mode}" \
		--argjson _us_per_roundtrip "${_fuse_cost_us_per_roundtrip}" '
		($_after.timestamp - $_before.timestamp) as $_seconds
		| ($_after.replies - $_before.replies) as $_replies
		| ($_after.cpuSeconds - $_before.cpuSeconds) as $_cpu_seconds
		| (if $_seconds > 0 then $_replies / $_seconds else 0 end) as $_rate
		| (if $_seconds > 0 then $_cpu_seconds / $_seconds else 0 end) as $_daemon_cores
		| ($_rate * $_us_per_roundtrip / 1000000) as $_fuse_cores
		| (if $_daemon_cores > 0 then $_fuse_cores / $_daemon_cores else 0 end) as $_share
		| ($_perf_samples | split(" ")) as $_perf_parts
		| (if $_perf_samples == "unavailable" then "unavailable" else "ok" end) as $_perf_status
		| (if $_perf_status == "ok" then ($_perf_parts[0] | tonumber) else 0 end) as $_perf_total
		| (if $_perf_status == "ok" then ($_perf_parts[1] | tonumber) else 0 end) as $_perf_hits
		| {
			windowSeconds: $_seconds,
			replies: $_replies,
			requests: ($_after.requests - $_before.requests),
			roundtripRate: $_rate,
			daemonCpuSeconds: $_cpu_seconds,
			daemonCpuCores: $_daemon_cores,
			daemonUsPerRoundtrip: (if $_replies > 0 then $_cpu_seconds * 1000000 / $_replies else 0 end),
			usPerRoundtrip: $_us_per_roundtrip,
			fuseCpuCoresEstimate: $_fuse_cores,
			fuseShareEstimate: $_share,
			replyBytesTotal: ($_after.replyBytes - $_before.replyBytes),
			replyBytesMax: $_after.replyBytesMax,
			requestBytesMax: $_after.requestBytesMax,
			auditEvents: ($_after.auditEvents - $_before.auditEvents),
			perfStatus: $_perf_status,
			perfMode: $_perf_mode,
			perfSamples: $_perf_total,
			perfFuseSamples: $_perf_hits,
			perfFuseShare: (if $_perf_total > 0 then $_perf_hits / $_perf_total else 0 end),
			opcodeDeltas: (
				($_after.opcodes // {}) as $_after_opcodes
				| ($_before.opcodes // {}) as $_before_opcodes
				| (($_after_opcodes | keys) + ($_before_opcodes | keys) | unique)
				| map({key: ., value: (($_after_opcodes[.] // 0) - ($_before_opcodes[.] // 0))})
				| map(select(.value > 0))
				| from_entries
			)
		}')"

	if ! jq -e '
		.windowSeconds > 0 and
		.replies > 0 and
		.requests > 0 and
		.daemonCpuSeconds >= 0 and
		.fuseShareEstimate >= 0 and
		.auditEvents >= 0
	' <<<"${_report}" >/dev/null; then
		echo "implausible FUSE cost window: ${_report}" >&2
		return 1
	fi

	printf '%s\n' "${_report}" |
		sudo install -m 0644 /dev/stdin "${_log_root}/fuse-cost-attribution.json"

	jq -r '
		"fuse-cost-attribution window=\(.windowSeconds)s replies=\(.replies) rate=\(.roundtripRate | . * 100 | round / 100)/s",
		"  daemon CPU: \(.daemonCpuSeconds | . * 1000 | round / 1000)s = \(.daemonCpuCores * 100 | round / 100) cores",
		"  daemon CPU per round trip (measured, model free): \(.daemonUsPerRoundtrip | . * 10 | round / 10) us",
		"  FUSE estimate: \(.usPerRoundtrip) us/roundtrip = \(.fuseCpuCoresEstimate * 1000 | round / 1000) cores",
		"  estimated FUSE share of daemon CPU: \(.fuseShareEstimate * 1000 | round / 10)%",
		"  top opcodes: \(.opcodeDeltas | to_entries | sort_by(-.value) | .[0:5] | map("\(.key)=\(.value)") | join(", "))",
		"  BPF gate audit events in window: \(.auditEvents) (per FUSE round trip: \(if .replies > 0 then (.auditEvents / .replies * 100 | round / 100) else 0 end))",
		(if .perfStatus == "ok" then
			"  perf attribution (\(.perfMode)): \(.perfFuseSamples)/\(.perfSamples) samples in FUSE frames = \(.perfFuseShare * 1000 | round / 10)%"
		else
			"  perf attribution: unavailable (no usable perf in this VM)"
		end),
		"  payload maxima: request=\(.requestBytesMax)B reply=\(.replyBytesMax)B"
	' <<<"${_report}"

	if [[ "${_perf_mode}" != "unavailable" ]]; then
		printf '\n==> perf DSO split (daemon binary vs kernel vs libc)\n'
		awk '! /^#/ && ! /^$/ && _shown < 8 { print; _shown++ }' \
			"${_log_root}/fuse-cost-attribution.perf-dso.txt"
		printf '\n==> perf top symbols\n'
		awk '! /^#/ && ! /^$/ && _shown < 12 { print; _shown++ }' \
			"${_log_root}/fuse-cost-attribution.perf-symbol.txt"
		printf '\n==> perf open(2) callers\n'
		cat "${_log_root}/fuse-cost-attribution.perf-open-attribution.txt"
	fi

	trap - EXIT
	__cleanup
	echo "fuse-cost-attribution-ok"
}

__main "$@"
