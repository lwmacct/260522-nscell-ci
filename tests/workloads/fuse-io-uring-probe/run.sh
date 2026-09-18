#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"
_probe_tmp=""

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"

__cleanup() {
	if [[ -n "$_probe_tmp" ]]; then
		rm -f -- "$_probe_tmp"
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

__assert_inventory() {
	local _config_value="$1"
	local _enable_value="$2"
	local _disabled_value="$3"
	local _release="$4"

	jq -e \
		--arg _config "$_config_value" \
		--arg _enable "$_enable_value" \
		--arg _disabled "$_disabled_value" \
		--arg _release "$_release" '
      .kernelRelease == $_release and
      .configFuseIOUring == $_config and
      .fuseEnableUring == $_enable and
      .ioUringDisabled == $_disabled and
      (.possibleCPUs | type == "number" and . > 0) and
      .queueCount == .possibleCPUs and
      .payloadBytes == 1048576 and
      (.estimatedBytesPerConnection | type == "number") and
      .estimatedBytesPerConnection >= (.queueCount * .payloadBytes) and
      (.abi.setup | type == "boolean") and
      (.abi.uringCmd | type == "boolean") and
      (.abi.sqe128 | type == "boolean") and
      (.abi.cqe32 | type == "boolean") and
      (.abi.featureBits | type == "number") and
      (.transportProbe | IN("unsupported", "failed", "passed")) and
      .transport.status == .transportProbe and
      (if .transportProbe == "passed" then
         .transportReady == true and
         .transport.attempted == true and
         .transport.fuseInit == true and
         .transport.queueEntriesRegistered == .queueCount and
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
    ' "$_probe_tmp" >/dev/null
}

__main() {
	local _config_value _daemon_fds_before _daemon_pid _disabled_value
	local _enable_value _mounts_before _release

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

	_release="$(uname -r)"
	_config_value="$(__kernel_config_value)"
	_enable_value="$(__kernel_value /sys/module/fuse/parameters/enable_uring)"
	_disabled_value="$(__kernel_value /proc/sys/kernel/io_uring_disabled)"
	_probe_tmp="$(mktemp)"

	__log "recording the FUSE io_uring ABI and resource baseline"
	timeout 20s sudo nscell daemon host io-uring | tee "$_probe_tmp"
	__assert_inventory "$_config_value" "$_enable_value" "$_disabled_value" "$_release"
	sudo install -m 0644 "$_probe_tmp" "${_log_root}/fuse-io-uring-probe.json"

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
