#!/usr/bin/env bash

set -euo pipefail

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

__require_command() {
	local _command="$1"

	if ! command -v "${_command}" >/dev/null; then
		echo "missing required command: ${_command}" >&2
		return 1
	fi
}

__check_shell() {
	local -a _shell_files=()

	mapfile -t _shell_files < <(git ls-files '*.sh' | sort)
	((${#_shell_files[@]} > 0))
	printf '%s\n' "${_shell_files[@]}" | xargs -r -n1 bash -n
	shellcheck "${_shell_files[@]}"
}

__check_python() {
	local _python_file

	while IFS= read -r _python_file; do
		if [[ "$(head -n1 "${_python_file}")" != '#!/usr/bin/env python3' ]]; then
			echo "invalid Python shebang: ${_python_file}" >&2
			return 1
		fi
		python3 - "${_python_file}" <<'PY'
import ast
import pathlib
import sys

_path = pathlib.Path(sys.argv[1])
ast.parse(_path.read_text(), filename=str(_path))
PY
	done < <(git ls-files '*.py' | sort)
}

__check_manifest() {
	local _suite _grouping _selection _targets _token

	bash tests/manifest.sh validate
	for _grouping in isolated bundled; do
		for _suite in smoke quick runtime gate; do
			_selection="$(
				bash tests/manifest.sh select vm "${_suite}" "" "${_grouping}"
			)"
			jq -e '
				type == "array" and length > 0 and
				all(.[];
					(.name | type == "string" and length > 0) and
					(.targets | type == "array" and length > 0) and
					all(.targets[]; type == "string" and length > 0) and
					(.timeout_minutes | type == "number" and . > 0 and . <= 10)
				) and
				((map(.targets[]) | length) == (map(.targets[]) | unique | length))
			' <<<"${_selection}" >/dev/null
			# Every entry the matrix will carry has to mean the same thing
			# here as it does in the manifest.
			while IFS=$'\t' read -r _token _targets; do
				bash tests/manifest.sh check-selection "${_token}" "${_targets}" >/dev/null
			done < <(jq -r '.[] | "\(.name)\t\(.targets | tojson)"' <<<"${_selection}")
		done
	done

	# An explicit target list is the debugging path: one target per entry, and
	# bundling it would need a group token that means several targets.
	_selection="$(
		bash tests/manifest.sh select vm smoke \
			kernel-capability-smoke,fuse-copy-file-range,new-mount-api-deny isolated
	)"
	jq -e '
		type == "array" and length == 3 and
		all(.[]; (.targets | length) == 1)
	' <<<"${_selection}" >/dev/null
	if bash tests/manifest.sh select vm smoke kernel-capability-smoke bundled >/dev/null 2>&1; then
		echo "an explicit target list must not accept the bundled grouping" >&2
		return 1
	fi

	__check_suite_composition
}

__check_manifest_naming() {
	local _tmp _manifest _case _expected _filter _output

	_tmp="$(mktemp -d)"
	_manifest="${_tmp}/manifest.json"

	while IFS=$'\t' read -r _case _expected _filter; do
		jq "${_filter}" tests/manifest.json >"${_manifest}" || return 1
		if _output="$(NSCELL_CI_MANIFEST="${_manifest}" bash tests/manifest.sh validate-schema 2>&1)"; then
			echo "manifest schema accepted ${_case}" >&2
			return 1
		fi
		if [[ "${_output}" != *"${_expected}"* ]]; then
			echo "rejecting ${_case} reported ${_output}" >&2
			return 1
		fi
	done <<'EOF'
an underscore in a target name	target name must match	.targets += [{"name":"io_uring-policy","kind":"workload","modes":{"vm":{"class":"policy","timeout_minutes":5}}}]
a target name that is a command word	target name must not be a command word	.targets += [{"name":"all","kind":"workload","modes":{"vm":{"class":"policy","timeout_minutes":5}}}]
a group that reuses a target name	group must not reuse a target name	.targets += [{"name":"naming-probe","kind":"workload","modes":{"vm":{"class":"semantics","timeout_minutes":5,"group":"daemon-fail-stop"}}}]
a group that is a command word	group must not be a command word	.targets += [{"name":"naming-probe","kind":"workload","modes":{"vm":{"class":"semantics","timeout_minutes":5,"group":"cleanup"}}}]
EOF

	# Without this the rejections above would also pass on a missing manifest.
	cp tests/manifest.json "${_manifest}"
	NSCELL_CI_MANIFEST="${_manifest}" bash tests/manifest.sh validate-schema
	rm -rf "${_tmp}"
}

__suite_targets() {
	bash tests/manifest.sh select vm "$1" "" bundled |
		jq -r '[.[].targets[]] | sort | join(" ")'
}

__check_suite_composition() {
	local _all _smoke _quick _runtime _gate _experiment

	_all="$(jq -r '[.targets[].name] | sort | join(" ")' tests/manifest.json)"
	_smoke="$(__suite_targets smoke)"
	_quick="$(__suite_targets quick)"
	_runtime="$(__suite_targets runtime)"
	_gate="$(__suite_targets gate)"
	_experiment="$(
		jq -r '[.targets[] | select(.modes.vm.class == "experiment") | .name] | sort | join(" ")' \
			tests/manifest.json
	)"

	jq -en \
		--arg all "${_all}" \
		--arg smoke "${_smoke}" \
		--arg quick "${_quick}" \
		--arg runtime "${_runtime}" \
		--arg gate "${_gate}" \
		--arg experiment "${_experiment}" '
		def s($value): $value | split(" ") | map(select(length > 0)) | sort;
		(s($gate) == ((s($quick) + s($runtime)) | unique | sort)) and
		((s($quick) - s($runtime)) | length == (s($quick) | length)) and
		((s($all) - (s($smoke) + s($quick) + s($runtime))) == s($experiment))
	' >/dev/null
}

__check_python_image_pin() {
	local _references _preset
	local -a _digests=()

	_references="$(
		git grep -n -I -E 'python:3\.[0-9]+-alpine' -- \
			'.github/actions/run-vm-workload/run.sh' \
			'.github/workflows/build-vm-standard.yml' \
			'tests/library/env.sh' \
			'tests/workloads/*/Dockerfile' || true
	)"
	[[ -n "${_references}" ]]

	while IFS= read -r _reference; do
		if [[ ! "${_reference}" =~ @sha256:[0-9a-f]{64} ]]; then
			echo "unpinned Python base image reference: ${_reference}" >&2
			return 1
		fi
	done <<<"${_references}"

	# The profile writes the preloaded digest into the guest marker, and the
	# warm step pulls the workflow copy of the same reference. Nothing reads
	# the marker, so a drift here would make the smoke target silently miss
	# its preloaded image instead of failing.
	_preset="$(
		git grep -n -I -E 'PRESET_PYTHON_[0-9]+_ALPINE=' -- images/standard.yaml || true
	)"
	if [[ -z "${_preset}" ]]; then
		echo "standard VM profile does not record the preloaded Python image digest" >&2
		return 1
	fi
	_references="${_references}"$'\n'"${_preset}"

	mapfile -t _digests < <(
		sed -n 's/.*\(sha256:[0-9a-f]\{64\}\).*/\1/p' <<<"${_references}" |
			sort -u
	)
	if ((${#_digests[@]} != 1)); then
		echo "Python base image references do not share one digest" >&2
		return 1
	fi
}

__check_vm_guest_image_policy() {
	local _matches

	_matches="$(
		git grep -n -I -E 'busybox:1\.37\.0|NSCELL_REGISTRY_(USERNAME|TOKEN)|oras (login|logout) ghcr\.io' -- \
			'.github/actions/run-vm-workload' 'tests' || true
	)"
	if [[ -n "${_matches}" ]]; then
		echo "retired VM guest image or registry credential reference found:" >&2
		printf '%s\n' "${_matches}" >&2
		return 1
	fi
}

__check_retired_gate_mode() {
	local _matches

	# ADR-026 removed reduced-security gate execution. These references must
	# not return to workflows, scripts, tests, or documentation.
	_matches="$(
		git grep -n -I -E 'NSCELL_GATE_MODE|--gate-mode|unsupported-no-bpf-lsm' -- \
		':(exclude).github/scripts/check.sh' || true
	)"
	if [[ -n "${_matches}" ]]; then
		echo "retired reduced-security gate reference found:" >&2
		printf '%s\n' "${_matches}" >&2
		return 1
	fi
}

__check_retired_gate_status_fields() {
	local _matches

	_matches="$(
		git grep -n -I -E '\.(mode[[:space:]]*==[[:space:]]*"strict"|enabled[[:space:]]*==[[:space:]]*true|enforce[[:space:]]*==[[:space:]]*true)' -- \
			'scripts/**' 'tests/**' || true
	)"
	if [[ -n "${_matches}" ]]; then
		echo "retired BPF gate status field reference found:" >&2
		printf '%s\n' "${_matches}" >&2
		return 1
	fi
}

__main() {
	cd "${_repo_root}"
	__require_command actionlint
	__require_command jq
	__require_command python3
	__require_command shellcheck

	__check_shell
	__check_python
	__check_manifest
	__check_manifest_naming
	__check_python_image_pin
	__check_vm_guest_image_policy
	__check_retired_gate_mode
	__check_retired_gate_status_fields
	actionlint
	git show --check --oneline HEAD >/dev/null
	git diff --check
}

__main "$@"
