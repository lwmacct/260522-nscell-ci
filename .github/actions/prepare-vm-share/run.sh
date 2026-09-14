#!/usr/bin/env bash

set -euo pipefail

_ci_repo="${CI_REPO:?CI_REPO is required}"
_test_target="${TEST_TARGET:?TEST_TARGET is required}"
_run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${_test_target}"
_resource_hash="$(printf '%s' "${_run_id}" | sha256sum | cut -d ' ' -f1)"
_resource_id="run-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${_resource_hash:0:16}"
_share_dir="${RUNNER_TEMP:-/tmp}/test-vm-share-${_resource_id}"

__main() {
  test -d "${_ci_repo}"
  mkdir -p "${_share_dir}"
  tar --exclude=.git -C "${_ci_repo}" -cf - . |
    tar -xf - -C "${_share_dir}"
  test -x "${_share_dir}/scripts/ci.sh"
  test -d "${_share_dir}/tests"
  printf 'share_dir=%s\n' "${_share_dir}" >> "${GITHUB_OUTPUT}"
}

__main "$@"
