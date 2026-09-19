#!/usr/bin/env bash

set -euo pipefail

_vm_name="${VM_NAME:?VM_NAME is required}"
_test_target="${TEST_TARGET:?TEST_TARGET is required}"
_test_targets_json="${TEST_TARGETS_JSON:?TEST_TARGETS_JSON is required}"
_nscell_image="${NSCELL_IMAGE:?NSCELL_IMAGE is required}"
_oci_base_image="${NSCELL_CI_OCI_BASE_IMAGE:-docker.io/library/python:3.14-alpine@sha256:016508ba505da24f7139765bc4bb669df4e88eb2f12eeadd571bf2f88d7533df}"
declare -a _test_targets=()

__main() {
  local _manifest="${GITHUB_WORKSPACE:-.}/tests/manifest.sh"

  # The manifest owns the token rule and the meaning of a selection, so ask it
  # instead of restating either one here.
  bash "${_manifest}" check-selection "${_test_target}" "${_test_targets_json}" >/dev/null
  mapfile -t _test_targets < <(jq -r '.[]' <<<"${_test_targets_json}")

sudo incus exec "${_vm_name}" -- \
  env \
  NSCELL_TEST_TARGET="${_test_target}" \
  NSCELL_TEST_TARGETS_JSON="${_test_targets_json}" \
  NSCELL_IMAGE="${_nscell_image}" \
    NSCELL_CI_OCI_BASE_IMAGE="${_oci_base_image}" \
    bash -s <<'EOF'
set -euo pipefail

_test_target="${NSCELL_TEST_TARGET}"
_test_targets_json="${NSCELL_TEST_TARGETS_JSON}"
_nscell_image="${NSCELL_IMAGE}"
_oci_base_image="${NSCELL_CI_OCI_BASE_IMAGE}"
declare -a _test_targets=()
mapfile -t _test_targets < <(jq -r '.[]' <<<"${_test_targets_json}")

mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
grep -qw bpf /sys/kernel/security/lsm
test -x /usr/local/bin/oras
test -x /usr/bin/docker

cd /opt/nscell-ci
export NSCELL_IMAGE="${_nscell_image}"
export NSCELL_IMAGE_PLATFORM=linux/amd64
export NSCELL_CI_TEST_ROOT=/data/nscell
export NSCELL_CI_IMAGE_CACHE_DIR=/data/nscell/images
export NSCELL_CI_OCI_BASE_IMAGE="${_oci_base_image}"
bash scripts/ci.sh setup-runtime-host
bash scripts/ci.sh verify-gate

case "${_test_target}" in
smoke)
  docker image inspect "${_oci_base_image}" >/dev/null
  docker run --rm --runtime nscell --pull=never "${_oci_base_image}" sh -c \
    'test "$(uname -m)" = x86_64; test -n "$(cat /etc/hostname)"; echo nscell-vm-smoke-ok'
  ;;
*)
  bash scripts/ci.sh show-host-capabilities
  if ((${#_test_targets[@]} == 1)); then
    bash scripts/ci.sh run-workload "${_test_targets[0]}"
  else
    export NSCELL_WORKLOAD_FAIL_FAST=0
    bash tests/run.sh parallel "${_test_targets[@]}"
  fi
  bash scripts/ci.sh collect-logs || true
  ;;
esac

EOF
}

__main "$@"
