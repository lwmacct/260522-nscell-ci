#!/usr/bin/env bash

set -euo pipefail

_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_manifest="${NSCELL_CI_MANIFEST:-${_test_dir}/manifest.json}"

# One token namespace.
#
# A target name and a group name are the same token: the selection token that
# the matrix turns into one VM, one job, one artifact, and the argument the
# guest dispatches on. The rule therefore describes the token, not the manifest
# field:
#
#   * lowercase kebab-case - the token is a directory under tests/workloads, an
#     item of a `targets=` list that is split on spaces and commas, and a job and
#     artifact name fragment, so it stays one plain word with one spelling;
#   * never a command word - tests/run.sh dispatches all, cleanup, parallel and
#     run before it treats its argument as a name, so those tokens are not
#     available as names;
#   * one meaning - a group must not reuse a target name, or a bundled suite and
#     a `targets=<name>` selection would silently mean different things.
_token_pattern='^[a-z0-9][a-z0-9-]*$'
_token_reserved='["all","cleanup","parallel","run"]'

__usage() {
	cat <<'EOF'
usage: tests/manifest.sh <command>

commands:
  validate
  validate-schema
  workloads
  check-selection <token> <targets-json>
  select <vm> <smoke|quick|runtime|gate> [explicit targets] [isolated|bundled]

Grouping applies to a suite selection that bundles targets sharing a manifest
group. An explicit target list is always one target per entry.

Set NSCELL_CI_MANIFEST to read a manifest other than tests/manifest.json.
EOF
}

__report_schema_violations() {
	local _classes='["preflight","contract","policy","semantics","runtime","experiment"]'

	jq -r \
		--arg name_pattern "${_token_pattern}" \
		--argjson reserved "${_token_reserved}" \
		--argjson classes "${_classes}" '
		def report($what; $names):
			select(($names | length) > 0) | "manifest \($what): \($names | join(", "))";
		(.targets | map(.name)) as $names |
		[
			report(
				"target name must match " + $name_pattern +
					" (the token is a tests/workloads directory and a targets= item)";
				[.targets[] | select((.name | type) != "string" or (.name | test($name_pattern) | not)) | (.name | tostring)]
			),
			report(
				"target name must not be a command word (" + ($reserved | join(", ")) + ")";
				[.targets[] | .name as $name | select(($reserved | index($name)) != null) | $name]
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
			),
			report(
				"group must not be a command word (" + ($reserved | join(", ")) + ")";
				[.targets[] | select(.modes.vm.group as $group |
					$group != null and ($reserved | index($group)) != null) | (.name | tostring)]
			),
			report(
				"group must not reuse a target name (one token, one meaning)";
				[.targets[] | select(.modes.vm.group as $group |
					$group != null and ($names | index($group)) != null) |
					(.name + " -> " + .modes.vm.group)]
			)
		] | .[]
	' "${_manifest}" >&2
}

__validate_schema() {
	jq -e \
		--arg name_pattern "${_token_pattern}" \
		--argjson reserved "${_token_reserved}" '
		(.targets | map(.name)) as $names |
		.schema_version == 2 and
		(.targets | type == "array" and length > 0) and
		($names | length) == ($names | unique | length) and
		all(.targets[]; . as $target |
			($target.name | type == "string" and test($name_pattern)) and
			(($reserved | index($target.name)) == null) and
			($target.kind == "workload" or $target.kind == "probe") and
			($target.modes | type == "object" and (keys_unsorted == ["vm"])) and
			($target.modes.vm.class as $class |
				(["preflight", "contract", "policy", "semantics", "runtime", "experiment"] |
					index($class)) != null) and
			($target.modes.vm.timeout_minutes | type == "number" and . > 0 and . <= 10 and floor == .) and
			(($target.modes.vm.group // null) == null or
				($target.modes.vm.group as $group |
					($group | type == "string" and test($name_pattern)) and
					(($reserved | index($group)) == null) and
					(($names | index($group)) == null)))
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
	__require_jq
	__validate_schema
	__validate_workload_files
}

__require_jq() {
	command -v jq >/dev/null 2>&1 || {
		echo "missing required command: jq" >&2
		return 1
	}
	test -s "${_manifest}"
}

__workloads() {
	__validate
	jq -r '.targets[] | select(.kind == "workload") | .name' "${_manifest}" | sort
}

# The matrix carries the token it selected and the concrete targets that token
# stands for. Both cross a boundary (workflow outputs, job and artifact names,
# a guest argument), so re-derive the meaning here instead of trusting the
# caller: the same token must always denote the same targets.
__check_selection() {
	local _token _targets_json _reason

	if (($# != 2)); then
		echo "check-selection requires a token and a targets JSON array" >&2
		return 2
	fi
	_token="$1"
	_targets_json="$2"

	__require_jq || return 2
	_reason="$(
		jq -r \
			--arg token "${_token}" \
			--argjson targets "${_targets_json}" \
			--arg name_pattern "${_token_pattern}" \
			--argjson reserved "${_token_reserved}" \
			--arg manifest_name "$(basename "${_manifest}")" '
			def word: select(type == "string") | test($name_pattern);
			(.targets | map(.name)) as $names |
			[.targets[] | select(.modes.vm.group != null) | .modes.vm.group] as $groups |
			if ($targets | type) != "array" or ($targets | length) == 0 or
				any($targets[]; (type != "string") or (word | not)) or
				(($targets | unique | length) != ($targets | length)) then
				"targets must be a non-empty array of unique kebab-case names"
			elif ($token | word | not) then
				"\($token) must match \($name_pattern)"
			elif ($reserved | index($token)) != null then
				"\($token) is a command word, not a selection token"
			elif ($names | index($token)) != null then
				if ($targets | sort) == [$token] then "" else
					"the target \($token) runs alone, but the list is \($targets | sort | join(", "))"
				end
			elif ($groups | index($token)) != null then
				([.targets[] | select(.modes.vm.group == $token) | .name] | sort) as $members |
				if ($targets | sort) == $members then "" else
					"the group \($token) is \($members | join(", ")), but the list is \($targets | sort | join(", "))"
				end
			else
				"\($token) is not a target name or a group in \($manifest_name)"
			end
		' "${_manifest}"
	)" || return 2

	if [[ -n "${_reason}" ]]; then
		echo "invalid test selection: ${_reason}" >&2
		return 2
	fi
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
		# An explicit list is how a single target is debugged, so it never
		# shares a VM: bundling would need a group name for the entry, and a
		# group name that means several targets is not a selection token.
		if [[ "${_grouping}" == bundled ]]; then
			echo "an explicit target list is always one target per entry; drop the bundled grouping" >&2
			return 2
		fi
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
				label: $_target.name,
				timeout_minutes: $_target.modes[$_mode].timeout_minutes
			}]
			| sort_by(.name)
		' "${_manifest}")"
		_selection="$(jq -c 'map({name, label, targets: [.name], timeout_minutes})' <<<"${_selection}")"
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
	validate-schema)
		(($# == 0)) || return 2
		__require_jq || return 2
		__validate_schema
		;;
	workloads)
		(($# == 0)) || return 2
		__workloads
		;;
	check-selection)
		(($# == 2)) || return 2
		__check_selection "$@"
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
