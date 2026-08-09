#!/usr/bin/env bash

set -euo pipefail

_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_manifest="${_test_dir}/manifest.json"

__usage() {
	cat <<'EOF'
usage: tests/manifest.sh <command>

commands:
  validate
  workloads
  select <host|vm> <smoke|gate|full> [explicit targets]
EOF
}

__validate_schema() {
	jq -e '
		.schema_version == 1 and
		(.targets | type == "array" and length > 0) and
		([.targets[].name] | length) == ([.targets[].name] | unique | length) and
		all(.targets[];
			(.name | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
			(.kind == "workload" or .kind == "probe") and
			(.modes | type == "object" and length > 0) and
			all(.modes | to_entries[];
				(.key == "host" or .key == "vm") and
				(.value.suites | type == "array" and length > 0) and
				all(.value.suites[]; . == "smoke" or . == "gate" or . == "full") and
				(.value.timeout_minutes | type == "number" and . > 0 and floor == .)
			)
		)
	' "${_manifest}" >/dev/null
}

__validate_workload_files() {
	local _actual _expected _path

	_expected="$(jq -r '.targets[] | select(.kind == "workload") | .name' "${_manifest}" | sort)"
	_actual="$({
		for _path in "${_test_dir}"/workloads/*; do
			[[ -d "${_path}" && -f "${_path}/run.sh" ]] || continue
			basename "${_path}"
		done
	} | sort)"
	if [[ "${_actual}" != "${_expected}" ]]; then
		echo "manifest workload set does not match tests/workloads" >&2
		diff -u <(printf '%s\n' "${_expected}") <(printf '%s\n' "${_actual}") >&2 || true
		return 1
	fi
}

__validate() {
	command -v jq >/dev/null 2>&1 || {
		echo "missing required command: jq" >&2
		return 1
	}
	test -s "${_manifest}"
	__validate_schema
	__validate_workload_files
}

__workloads() {
	__validate
	jq -r '.targets[] | select(.kind == "workload") | .name' "${_manifest}" | sort
}

__explicit_targets_json() {
	local _raw="$1"
	local -a _targets=()

	_raw="${_raw//,/ }"
	read -r -a _targets <<<"${_raw}"
	if ((${#_targets[@]} == 0)); then
		echo "explicit target selection must not be empty" >&2
		return 2
	fi
	printf '%s\n' "${_targets[@]}" | sort -u | jq -R . | jq -sc .
}

__select() {
	local _mode="$1"
	local _suite="$2"
	local _explicit="${3:-}"
	local _target _targets_json _selection

	case "${_mode}" in
	host | vm) ;;
	*)
		echo "unsupported test mode: ${_mode}" >&2
		return 2
		;;
	esac
	case "${_suite}" in
	smoke | gate | full) ;;
	*)
		echo "unsupported test suite: ${_suite}" >&2
		return 2
		;;
	esac

	__validate
	if [[ -n "${_explicit}" ]]; then
		_targets_json="$(__explicit_targets_json "${_explicit}")"
		while IFS= read -r _target; do
			if ! jq -e --arg _name "${_target}" --arg _mode "${_mode}" \
				'.targets[] | select(.name == $_name and .modes[$_mode] != null)' \
				"${_manifest}" >/dev/null; then
				echo "target ${_target} is unavailable in ${_mode} mode" >&2
				return 2
			fi
		done < <(jq -r '.[]' <<<"${_targets_json}")
		_selection="$(jq -c --arg _mode "${_mode}" --argjson _targets "${_targets_json}" '
			[.targets[] as $_target |
			select($_targets | index($_target.name)) |
			{name: $_target.name, timeout_minutes: $_target.modes[$_mode].timeout_minutes}]
			| sort_by(.name)
		' "${_manifest}")"
	else
		_selection="$(jq -c --arg _mode "${_mode}" --arg _suite "${_suite}" '
			[.targets[] |
			select(.modes[$_mode] != null) |
			select(.modes[$_mode].suites | index($_suite)) |
			{name, timeout_minutes: .modes[$_mode].timeout_minutes}]
			| sort_by(.name)
		' "${_manifest}")"
	fi
	if [[ "$(jq 'length' <<<"${_selection}")" == 0 ]]; then
		echo "selection produced no ${_mode} targets" >&2
		return 2
	fi
	printf '%s\n' "${_selection}"
}

__main() {
	local _command="${1:-}"
	shift || true

	case "${_command}" in
	validate)
		(($# == 0)) || return 2
		__validate
		;;
	workloads)
		(($# == 0)) || return 2
		__workloads
		;;
	select)
		(($# >= 2 && $# <= 3)) || return 2
		__select "$@"
		;;
	-h | --help | help)
		__usage
		;;
	*)
		__usage >&2
		return 2
		;;
	esac
}

__main "$@"
