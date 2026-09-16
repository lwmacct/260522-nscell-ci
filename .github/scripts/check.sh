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
	local _suite _selection

	bash tests/manifest.sh validate
	for _suite in smoke gate full; do
		_selection="$(bash tests/manifest.sh select vm "${_suite}")"
		jq -e '
			type == "array" and length > 0 and
			all(.[];
				(.name | type == "string" and length > 0) and
				(.timeout_minutes | type == "number" and . > 0 and . <= 10)
			)
		' <<<"${_selection}" >/dev/null
	done
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
	__check_retired_gate_mode
	__check_retired_gate_status_fields
	actionlint
	git show --check --oneline HEAD >/dev/null
	git diff --check
}

__main "$@"
