#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"
_disabled_probe_tmp=""
_enabled_probe_tmp=""
_fuse_enable_path="/sys/module/fuse/parameters/enable_uring"
_restore_enable_value=""

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"

__cleanup() {
	local _path

	if [[ -n "$_restore_enable_value" ]]; then
		printf '%s\n' "$_restore_enable_value" | sudo tee "$_fuse_enable_path" >/dev/null || true
		_restore_enable_value=""
	fi
	for _path in "$_disabled_probe_tmp" "$_enabled_probe_tmp"; do
		if [[ -n "$_path" ]]; then
			rm -f -- "$_path"
		fi
	done
}

__set_fuse_io_uring() {
	local _value="$1"

	printf '%s\n' "$_value" | sudo tee "$_fuse_enable_path" >/dev/null
}

__restore_fuse_io_uring() {
	if [[ -n "$_restore_enable_value" ]]; then
		__set_fuse_io_uring "$_restore_enable_value"
		_restore_enable_value=""
	fi
}

__kernel_config_value() {
	local _config
	local _value

	_config="/boot/config-$(uname -r)"

	if [[ ! -r "$_config" ]]; then
		printf 'unknown\n'
		return
	fi
	_value="$(sed -n 's/^CONFIG_FUSE_IO_URING=//p' "$_config")"
	printf '%s\n' "${_value:-unknown}"
}

__kernel_value() {
	local _path="$1"

	if [[ ! -r "$_path" ]]; then
		printf 'unknown\n'
		return
	fi
	tr -d '[:space:]' <"$_path"
	printf '\n'
}

__fuse_mounts() {
	awk '$0 ~ / - fuse(\.[^ ]+)? / { print }' /proc/self/mountinfo
}

__fuse_connection_count() {
	sudo find /sys/fs/fuse/connections -mindepth 1 -maxdepth 1 | wc -l
}

__assert_no_probe_residue() {
	local _stage="$1"

	if [[ "$(__fuse_connection_count)" != "$_fuse_connections_before" ]]; then
		echo "io_uring probe left FUSE connections behind after ${_stage}" >&2
		sudo ls -l /sys/fs/fuse/connections >&2 || true
		return 1
	fi
	if [[ "$(__fuse_mounts)" != "$_mounts_before" ]]; then
		echo "io_uring probe left a FUSE mount behind after ${_stage}" >&2
		return 1
	fi
	if [[ "$(pgrep -cx nscell)" != "$_nscell_processes_before" ]]; then
		echo "io_uring probe left an nscell process behind after ${_stage}" >&2
		pgrep -ax nscell >&2 || true
		return 1
	fi
}

__capture_probe_state() {
	local _pid

	echo "==> FUSE connections" >&2
	ls -l /sys/fs/fuse/connections 2>&1 || true
	for _pid in $(pgrep -x nscell || true); do
		echo "==> nscell ${_pid} wchan: $(cat "/proc/${_pid}/wchan" 2>/dev/null || true)" >&2
		sudo cat "/proc/${_pid}/stack" 2>&1 || true
		sudo ls -l "/proc/${_pid}/fd" 2>&1 || true
		sudo cat "/proc/${_pid}/fdinfo"/* 2>&1 || true
	done
	sudo dmesg --ctime 2>&1 | tail -n 40 || true
}

__wait_for_probe_exit() {
	local _pid="$1"
	local _budget="$2"
	local _deadline=$((SECONDS + _budget))

	while ((SECONDS < _deadline)); do
		if ! kill -0 "${_pid}" 2>/dev/null; then
			wait "${_pid}" 2>/dev/null || true
			return 0
		fi
		sleep 1
	done

	return 1
}

# Run the enabled probe with its result redirected to a file: a pipe would hide
# the reported result when the kernel keeps a thread stranded in a FUSE wait.
# The probe must also terminate on its own instead of being killed by timeout.
__run_enabled_probe() {
	local _output="$1"
	local _payload_bytes="$2"
	local _benchmark_requests="${3:-0}"
	shift 3 || true
	local _deadline=$((SECONDS + 20))
	local _wrapper_pid
	local -a _arguments=(nscell daemon host io-uring)

	if [[ "${_payload_bytes}" != "0" ]]; then
		_arguments+=(--payload-bytes "${_payload_bytes}")
	fi
	if [[ "${_benchmark_requests}" != "0" ]]; then
		_arguments+=(--benchmark-requests "${_benchmark_requests}")
	fi
	if (($# > 0)); then
		_arguments+=("$@")
	fi

	# shellcheck disable=SC2024 # The redirect target is owned by the workload user.
	sudo timeout --signal=KILL 20s \
		"${_arguments[@]}" >"${_output}" 2>"${_output}.stderr" &
	_wrapper_pid=$!

	while ((SECONDS < _deadline)); do
		if jq -e . "${_output}" >/dev/null 2>&1; then
			break
		fi
		sleep 1
	done
	if ! jq -e . "${_output}" >/dev/null 2>&1; then
		echo "FUSE io_uring probe produced no result within 20s" >&2
		tail -n 20 "${_output}.stderr" >&2 || true
		tail -n 20 "${_output}" >&2 || true
		__capture_probe_state
		return 1
	fi
	cat "${_output}.stderr" >&2 || true
	cat "${_output}"
	if ! __wait_for_probe_exit "${_wrapper_pid}" 15; then
		echo "FUSE io_uring probe did not terminate after reporting a result" >&2
		__capture_probe_state
		return 1
	fi
}

__assert_inventory() {
	local _config_value="$1"
	local _enable_value="$2"
	local _disabled_value="$3"
	local _release="$4"
	local _expected_probe="$5"
	local _expected_payload="$6"
	local _probe_file="$7"

	jq -e \
		--arg _config "$_config_value" \
		--arg _enable "$_enable_value" \
		--arg _disabled "$_disabled_value" \
		--arg _release "$_release" \
		--arg _expected_probe "$_expected_probe" '
      .kernelRelease == $_release and
      .configFuseIOUring == $_config and
      .fuseEnableUring == $_enable and
      .ioUringDisabled == $_disabled and
      (.possibleCPUs | type == "number" and . > 0) and
      .queueCount == .possibleCPUs and
      .payloadBytes == ($_expected_payload | tonumber) and
      (.estimatedBytesPerConnection | type == "number") and
      .estimatedBytesPerConnection >= (.queueCount * .payloadBytes) and
      (.abi.setup | type == "boolean") and
      (.abi.uringCmd | type == "boolean") and
      (.abi.sqe128 | type == "boolean") and
      (.abi.cqe32 | type == "boolean") and
      (.abi.featureBits | type == "number") and
      (.transportProbe | IN("unsupported", "failed", "passed")) and
      .transportProbe == $_expected_probe and
      .transport.status == .transportProbe and
      (if .transportProbe == "passed" then
         .transportReady == true and
         .transport.attempted == true and
         .transport.fuseInit == true and
         .transport.queueEntriesRegistered == .queueCount and
         .transport.entryPayloadBytes == ([8192, ($_expected_payload | tonumber)] | max) and
         .transport.commitAndFetch == true and
         .transport.teardown == true and
         (.transport.durationMillis | type == "number" and . >= 0) and
         (.transport | has("error") | not)
       elif .transportProbe == "failed" then
         .transportReady == false and
         .transport.attempted == true and
         (.transport.error | type == "string" and length > 0) and
         (.transport.error as $_error | .reasons | index($_error) != null)
       else
         .transportReady == false and
         .transport.attempted == false
       end) and
      (if $_config == "y" then true
       else (.reasons | index("CONFIG_FUSE_IO_URING is not enabled") != null)
       end) and
      (if ($_enable | ascii_downcase) == "y" then true
       else (.reasons | index("fuse.enable_uring is not enabled") != null)
       end) and
      (if $_disabled == "0" then true
       else (.reasons | index("io_uring is disabled by the host policy") != null)
       end) and
      (if ($_config == "y" and ($_enable | ascii_downcase) == "y" and $_disabled == "0" and
           .abi.setup and .abi.uringCmd and .abi.sqe128 and .abi.cqe32)
       then (.transportProbe == "passed" or .transportProbe == "failed")
       else .transportProbe == "unsupported"
       end)
    ' --arg _expected_payload "$_expected_payload" "$_probe_file" >/dev/null
}

__main() {
	local _config_value _daemon_fds_before _daemon_pid _disabled_value
	local _enabled_value _original_enable_value _release

	if [[ "${1:-}" == "cleanup" ]]; then
		__cleanup
		return
	fi

	__require_cmd jq
	__require_cmd systemctl
	__require_cmd timeout
	__assert_nscell_ready
	__init_ci_dirs
	trap __cleanup EXIT

	_daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
	if [[ ! "$_daemon_pid" =~ ^[1-9][0-9]*$ ]] || ! sudo test -d "/proc/${_daemon_pid}"; then
		echo "invalid nscell daemon MainPID: ${_daemon_pid:-empty}" >&2
		return 1
	fi
	_daemon_fds_before="$(sudo find "/proc/${_daemon_pid}/fd" -mindepth 1 -maxdepth 1 | wc -l)"
	_mounts_before="$(__fuse_mounts)"
	_fuse_connections_before="$(__fuse_connection_count)"
	_nscell_processes_before="$(pgrep -cx nscell)"

	_release="$(uname -r)"
	_config_value="$(__kernel_config_value)"
	_original_enable_value="$(__kernel_value "$_fuse_enable_path")"
	_disabled_value="$(__kernel_value /proc/sys/kernel/io_uring_disabled)"
	_disabled_probe_tmp="$(mktemp)"
	_enabled_probe_tmp="$(mktemp)"

	if [[ "${_original_enable_value,,}" != n ]]; then
		echo "standard VM must start with fuse.enable_uring=N, got ${_original_enable_value}" >&2
		return 1
	fi
	if [[ "$_config_value" != y || "$_disabled_value" != 0 ]]; then
		echo "standard VM cannot run the enabled FUSE io_uring probe" >&2
		return 1
	fi
	if ! sudo test -w "$_fuse_enable_path"; then
		echo "FUSE io_uring module parameter is not writable in the disposable VM" >&2
		return 1
	fi

	__log "validating the disabled FUSE io_uring baseline"
	sudo timeout --signal=TERM --kill-after=5s 20s \
		nscell daemon host io-uring | tee "$_disabled_probe_tmp"
	__assert_inventory \
		"$_config_value" "$_original_enable_value" "$_disabled_value" "$_release" \
		unsupported 1048576 "$_disabled_probe_tmp"
	sudo install -m 0644 \
		"$_disabled_probe_tmp" "${_log_root}/fuse-io-uring-probe-disabled.json"

	__log "enabling FUSE io_uring inside the disposable VM"
	_restore_enable_value="$_original_enable_value"
	__set_fuse_io_uring Y
	_enabled_value="$(__kernel_value "$_fuse_enable_path")"
	if [[ "${_enabled_value,,}" != y ]]; then
		echo "failed to enable FUSE io_uring in the disposable VM" >&2
		return 1
	fi

	__log "validating the enabled FUSE io_uring transport across payload budgets"
	for _payload_bytes in 1048576 262144 65536 8192; do
		__run_enabled_probe "$_enabled_probe_tmp" "$_payload_bytes"
		__assert_inventory \
			"$_config_value" "$_enabled_value" "$_disabled_value" "$_release" \
			passed "$_payload_bytes" "$_enabled_probe_tmp"
		jq -r '"io-uring payloadBytes=\(.payloadBytes) entryPayloadBytes=\(.transport.entryPayloadBytes) status=\(.transportProbe) estimatedBytesPerConnection=\(.estimatedBytesPerConnection)"' \
			"$_enabled_probe_tmp"
		sudo install -m 0644 \
			"$_enabled_probe_tmp" "${_log_root}/fuse-io-uring-probe-payload-${_payload_bytes}.json"
		if [[ "$_payload_bytes" == 1048576 ]]; then
			sudo install -m 0644 \
				"$_enabled_probe_tmp" "${_log_root}/fuse-io-uring-probe.json"
			sudo install -m 0644 \
				"$_enabled_probe_tmp" "${_log_root}/fuse-io-uring-probe-enabled.json"
		fi
		__assert_no_probe_residue "payload ${_payload_bytes}"
	done

	__log "checking for probe residue across ${_fuse_io_uring_probe_iterations} runs"
	for _iteration in $(seq 1 "${_fuse_io_uring_probe_iterations}"); do
		__run_enabled_probe "$_enabled_probe_tmp" 65536
		jq -e '.transportProbe == "passed" and .transport.teardown == true' \
			"$_enabled_probe_tmp" >/dev/null
		__assert_no_probe_residue "iteration ${_iteration}"
	done

	__log "measuring the per-request cost of both transports"
	# dispatch4/readers4 vary how the classic server answers. This VM has four
	# CPUs, so its clients and its server readers share them and the shape
	# comparison is not readable here; these variants only keep the flags
	# exercised. Measure the shape on a many-CPU host (repo-laboratory skill).
	_benchmark_variants=(baseline1 clients4 coop4 defer4 dispatch4 readers4)
	for _round in $(seq 1 "${_fuse_io_uring_probe_benchmark_rounds}"); do
		for _variant in "${_benchmark_variants[@]}"; do
			case "${_variant}" in
			clients4)
				_variant_args=(--benchmark-clients 4)
				;;
			dispatch4)
				_variant_args=(--benchmark-clients 4 --benchmark-classic-serve dispatch)
				;;
			readers4)
				_variant_args=(--benchmark-clients 4 --benchmark-classic-readers 4)
				;;
			coop4)
				_variant_args=(--benchmark-clients 4 --benchmark-setup coop)
				;;
			defer4)
				_variant_args=(--benchmark-clients 4 --benchmark-setup defer)
				;;
			sqpoll4)
				_variant_args=(--benchmark-clients 4 --benchmark-setup sqpoll)
				;;
			*)
				_variant_args=()
				;;
			esac
			if ! __run_enabled_probe "$_enabled_probe_tmp" 65536 \
				"${_fuse_io_uring_probe_benchmark_requests}" "${_variant_args[@]}"; then
				echo "transport-benchmark variant=${_variant} round=${_round} unavailable" >&2
				continue
			fi
			jq -e '.benchmark.requests > 0 and (.benchmark.classic | (has("error") | not))' \
				"$_enabled_probe_tmp" >/dev/null
			jq -r --arg _variant "${_variant}" --arg _round "${_round}" '
				"transport-benchmark variant=\($_variant) round=\($_round) requests=\(.benchmark.requests) clients=\(.benchmark.clients) entriesPerQueue=\(.benchmark.entriesPerQueue) setupFlags=\(.benchmark.setupFlags)"
				+ " classic_serve=\(.benchmark.classic.serverShape) classic_readers=\(.benchmark.classic.serverReaders)"
				+ " io_uring_serve=\(.benchmark.ioUring.serverShape)"
				+ " classic_us=\(.benchmark.classic.durationUsPerRequest)"
				+ " classic_syscalls_per_req=\(.benchmark.classic.syscallsPerRequest)"
				+ (if (.benchmark.ioUring | has("error")) then
					" io_uring=error:\(.benchmark.ioUring.error)"
				else
					" io_uring_us=\(.benchmark.ioUring.durationUsPerRequest)"
					+ " io_uring_syscalls_per_req=\(.benchmark.ioUring.syscallsPerRequest)"
					+ " io_uring_enters=\(.benchmark.ioUring.ioUringEnterCalls)"
				end)
			' "$_enabled_probe_tmp"
			sudo install -m 0644 \
				"$_enabled_probe_tmp" "${_log_root}/fuse-io-uring-benchmark-${_variant}-${_round}.json"
			__assert_no_probe_residue "benchmark ${_variant} round ${_round}"
		done
	done

	__log "transport benchmark summary (median over ${_fuse_io_uring_probe_benchmark_rounds} rounds)"
	for _variant in "${_benchmark_variants[@]}"; do
		_variant_files=("${_log_root}"/fuse-io-uring-benchmark-"${_variant}"-*.json)
		if [[ ! -e "${_variant_files[0]}" ]]; then
			echo "transport-summary variant=${_variant} unavailable" >&2
			continue
		fi
		jq -rs --arg _variant "${_variant}" '
			map(select(.benchmark.ioUring | has("error") | not)) as $_runs
			| if ($_runs | length) == 0 then
				"transport-summary variant=\($_variant) io_uring unavailable"
			else
				($_runs | map(.benchmark.classic.durationUsPerRequest) | sort) as $_classic
				| ($_runs | map(.benchmark.ioUring.durationUsPerRequest) | sort) as $_uring
				| ($_runs | map(.benchmark.ioUring.syscallsPerRequest) | sort) as $_syscalls
				| ($_classic[($_classic | length) / 2 | floor]) as $_classic_median
				| ($_uring[($_uring | length) / 2 | floor]) as $_uring_median
				| "transport-summary variant=\($_variant) rounds=\($_runs | length)"
				+ " classic_serve=\($_runs[0].benchmark.classic.serverShape)"
				+ " classic_readers=\($_runs[0].benchmark.classic.serverReaders)"
				+ " classic_us_median=\($_classic_median * 100 | round / 100)"
				+ " classic_us_min=\($_classic[0] * 100 | round / 100)"
				+ " classic_us_max=\($_classic[-1] * 100 | round / 100)"
				+ " io_uring_us_median=\($_uring_median * 100 | round / 100)"
				+ " io_uring_us_min=\($_uring[0] * 100 | round / 100)"
				+ " io_uring_us_max=\($_uring[-1] * 100 | round / 100)"
				+ " io_uring_syscalls_per_req=\($_syscalls[($_syscalls | length) / 2 | floor] * 1000 | round / 1000)"
				+ " delta_percent=\((($_classic_median - $_uring_median) / $_classic_median * 1000 | round / 10))"
			end
		' "${_variant_files[@]}"
	done

	__restore_fuse_io_uring
	if [[ "$(__kernel_value "$_fuse_enable_path")" != "$_original_enable_value" ]]; then
		echo "failed to restore the FUSE io_uring module parameter" >&2
		return 1
	fi

	if [[ "$(systemctl show --property MainPID --value nscell-daemon.service)" != "$_daemon_pid" ]]; then
		echo "io_uring inventory restarted the nscell daemon" >&2
		return 1
	fi
	if [[ "$(sudo find "/proc/${_daemon_pid}/fd" -mindepth 1 -maxdepth 1 | wc -l)" != "$_daemon_fds_before" ]]; then
		echo "io_uring inventory changed the nscell daemon fd count" >&2
		return 1
	fi
	if [[ "$(__fuse_mounts)" != "$_mounts_before" ]]; then
		echo "io_uring inventory changed the host FUSE mount set" >&2
		return 1
	fi
	__assert_nscell_ready

	trap - EXIT
	__cleanup
	echo "fuse-io-uring-probe-validation-ok"
}

__main "$@"
