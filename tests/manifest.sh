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
  select <vm> <smoke|quick|runtime|gate> [explicit targets]
  select <vm> <smoke|quick|runtime|gate> [explicit targets] [isolated|bundled]
EOF
}

__report_schema_violations() {
	local _name_pattern='^[a-z0-9][a-z0-9-]*$'
	local _classes='["preflight","contract","policy","semantics","runtime","experiment"]'

	jq -r --arg name_pattern "${_name_pattern}" --argjson classes "${_classes}" '
		def report($what; $names):
			select(($names | length) > 0) | "manifest \($what): \($names | join(", "))";
		[
			report(
				"target name must match " + $name_pattern + " (lowercase kebab-case, no underscores)";
				[.targets[] | select((.name | type) != "string" or (.name | test($name_pattern) | not)) | (.name | tostring)]
			),
			report(
				"kind must be workload or probe";
				[.targets[] | select(.kind != "workload" and .kind != "probe") | (.name | tostring)]
			),
			report(
				"modes must contain exactly vm";
				[.targets[] | select((.modes | type) != "object" or (.modes | keys_unsorted) != ["vm"]) | (.name | tostring)]
			),
			report(
				"vm class must be one of " + ($classes | join(", "));
				[.targets[] | select(.modes.vm.class as $class | ($classes | index($class)) == null) | (.name | tostring)]
			),
			report(
				"timeout_minutes must be a whole number in 1..10";
				[.targets[] | select((.modes.vm.timeout_minutes | type) != "number" or
					.modes.vm.timeout_minutes <= 0 or .modes.vm.timeout_minutes > 10 or
					(.modes.vm.timeout_minutes | floor) != .modes.vm.timeout_minutes) | (.name | tostring)]
			),
			report(
				"group must match " + $name_pattern;
				[.targets[] | select(.modes.vm.group != null and
					((.modes.vm.group | type) != "string" or (.modes.vm.group | test($name_pattern) | not))) |
					(.name | tostring)]
			)
		] | .[]
	' "${_manifest}" >&2
}

__validate_schema() {
	jq -e '
		.schema_version == 2 and
		(.targets | type == "array" and length > 0) and
		([.targets[].name] | length) == ([.targets[].name] | unique | length) and
		all(.targets[];
			(.name | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
			(.kind == "workload" or .kind == "probe") and
			(.modes | type == "object" and (keys_unsorted == ["vm"])) and
			(.modes.vm.class as $class |
				(["preflight", "contract", "policy", "semantics", "runtime", "experiment"] |
					index($class)) != null) and
			(.modes.vm.timeout_minutes | type == "number" and . > 0 and . <= 10 and floor == .) and
			((.modes.vm.group // null) == null or
				(.modes.vm.group | type == "string" and test("^[a-z0-9][a-z0-9-]*$")))
		)
	' "${_manifest}" >/dev/null || {
		# The schema check itself is a single boolean, so say which target broke
		# which rule instead of leaving the caller with a bare exit status.
		if jq -e '(.schema_version == 2) and ((.targets | type) == "array")' "${_manifest}" >/dev/null 2>&1; then
			__report_schema_violations
			jq -r 'select(([.targets[].name] | length) != ([.targets[].name] | unique | length)) |
				"manifest target names must be unique"' "${_manifest}" >&2
		else
			echo "manifest must declare schema_version 2 and a non-empty targets array" >&2
		fi
		return 1
	}
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

__suite_classes() {
	case "$1" in
	smoke) printf '%s\n' preflight ;;
	quick) printf '%s\n' contract policy semantics ;;
	runtime) printf '%s\n' runtime ;;
	gate) printf '%s\n' contract policy semantics runtime ;;
	esac
}

__select() {
	local _mode="$1"
	local _suite="$2"
	local _explicit="${3:-}"
	local _grouping="${4:-isolated}"
	local _target _targets_json _selection _classes_json
	local -a _classes=()

	case "${_mode}" in
	vm) ;;
	*)
		echo "unsupported test mode: ${_mode}" >&2
		return 2
		;;
	esac
	case "${_suite}" in
	smoke | quick | runtime | gate) ;;
	*)
		echo "unsupported test suite: ${_suite}" >&2
		return 2
		;;
	esac
	case "${_grouping}" in
	isolated | bundled) ;;
	*)
		echo "unsupported test grouping: ${_grouping}" >&2
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
			{
				name: $_target.name,
				kind: $_target.kind,
				label: $_target.name,
				timeout_minutes: $_target.modes[$_mode].timeout_minutes
			}]
			| sort_by(.name)
		' "${_manifest}")"
		if [[ "${_grouping}" == bundled ]] &&
			[[ "$(jq '[.[].kind] | unique | length' <<<"${_selection}")" != 1 ]]; then
			echo "bundled explicit selection cannot mix probe and workload targets" >&2
			return 2
		fi
		if [[ "${_grouping}" == bundled ]]; then
			_selection="$(jq -c '
				if length == 1 then
					.[0] | {name, label, targets: [.name], timeout_minutes}
				else
					{
						name: "selected",
						label: (map(.name) | sort | join("+")),
						targets: map(.name),
						timeout_minutes: (
							([.[].timeout_minutes] | max) as $_timeout |
							if $_timeout + 2 > 10 then 10 else $_timeout + 2 end
						)
					}
			end |
			[.]
			' <<<"${_selection}")"
		else
			_selection="$(jq -c 'map({name, label, targets: [.name], timeout_minutes})' <<<"${_selection}")"
		fi
	else
		mapfile -t _classes < <(__suite_classes "${_suite}")
		_classes_json="$(printf '%s\n' "${_classes[@]}" | jq -R . | jq -sc .)"
		_selection="$(jq -c --arg _mode "${_mode}" --argjson _classes "${_classes_json}" '
			[.targets[] |
			select(.modes[$_mode] != null) |
			select(.modes[$_mode].class as $class | ($_classes | index($class)) != null) |
			{
				name: (.modes[$_mode].group // .name),
				label: (.modes[$_mode].group // .name),
				target: .name,
				timeout_minutes: .modes[$_mode].timeout_minutes
			}]
			| sort_by(.name)
		' "${_manifest}")"
		if [[ "${_grouping}" == bundled ]]; then
			_selection="$(jq -c '
				group_by(.name)
				| map(
					{
						name: .[0].name,
						label: .[0].name,
						targets: (map(.target) | sort),
						timeout_minutes: (
							if length == 1 then
								.[0].timeout_minutes
							else
								([.[].timeout_minutes] | max) as $_timeout |
								if $_timeout + 2 > 10 then 10 else $_timeout + 2 end
							end
						)
					}
				)
				| sort_by(.name)
			' <<<"${_selection}")"
		else
			_selection="$(jq -c 'sort_by(.name) | map({name: .target, label: .target, targets: [.target], timeout_minutes})' <<<"${_selection}")"
		fi
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
		(($# >= 2 && $# <= 4)) || return 2
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
