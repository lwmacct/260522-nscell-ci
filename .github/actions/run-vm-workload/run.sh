#!/usr/bin/env bash

set -euo pipefail

_vm_name="${VM_NAME:?VM_NAME is required}"
_test_target="${TEST_TARGET:?TEST_TARGET is required}"
_test_targets_json="${TEST_TARGETS_JSON:?TEST_TARGETS_JSON is required}"
_nscell_image="${NSCELL_IMAGE:?NSCELL_IMAGE is required}"
_oci_base_image="${NSCELL_CI_OCI_BASE_IMAGE:-docker.io/library/python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a}"
declare -a _test_targets=()

__main() {
  local _target

  if [[ "${_test_target}" != smoke &&
    ! "${_test_target}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "invalid VM test target: ${_test_target}" >&2
    return 2
  fi
  if [[ "${_test_target}" == all ]]; then
    echo "run-vm-workload accepts one concrete workload, not all" >&2
    return 2
  fi
  if ! jq -e '
    type == "array" and
    length > 0 and
    all(.[]; type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
    (unique | length) == length
  ' <<<"${_test_targets_json}" >/dev/null; then
    echo "invalid VM test target array: ${_test_targets_json}" >&2
    return 2
  fi
  mapfile -t _test_targets < <(jq -r '.[]' <<<"${_test_targets_json}")
  if [[ "${_test_target}" == smoke ]] &&
    { ((${#_test_targets[@]} != 1)) || [[ "${_test_targets[0]}" != smoke ]]; }; then
    echo "the smoke target must run alone" >&2
    return 2
  fi
  for _target in "${_test_targets[@]}"; do
    if [[ "${_target}" == all ]]; then
      echo "run-vm-workload accepts concrete workloads, not all" >&2
      return 2
    fi
  done

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
