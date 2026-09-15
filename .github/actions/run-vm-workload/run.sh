#!/usr/bin/env bash

set -euo pipefail

_vm_name="${VM_NAME:?VM_NAME is required}"
_test_target="${TEST_TARGET:?TEST_TARGET is required}"
_nscell_image="${NSCELL_IMAGE:?NSCELL_IMAGE is required}"
_registry_username="${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
_registry_token="${REGISTRY_TOKEN:-}"

__main() {
  if [[ "${_test_target}" != smoke &&
    ! "${_test_target}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "invalid VM test target: ${_test_target}" >&2
    return 2
  fi
  if [[ "${_test_target}" == all ]]; then
    echo "run-vm-workload accepts one concrete workload, not all" >&2
    return 2
  fi

  sudo incus exec "${_vm_name}" -- \
    env \
    NSCELL_TEST_TARGET="${_test_target}" \
    NSCELL_IMAGE="${_nscell_image}" \
    NSCELL_GATE_MODE=strict \
    NSCELL_REGISTRY_USERNAME="${_registry_username}" \
    NSCELL_REGISTRY_TOKEN="${_registry_token}" \
    bash -s <<'EOF'
set -euo pipefail

_test_target="${NSCELL_TEST_TARGET}"
_nscell_image="${NSCELL_IMAGE}"

__retry() {
  local _max_attempts="$1"
  shift
  local _attempt=1
  local _status

  while true; do
    if "$@"; then
      return 0
    else
      _status=$?
    fi
    if ((_attempt >= _max_attempts)); then
      return "$_status"
    fi
    echo "${1} failed with ${_status}; retrying ($((_attempt + 1))/${_max_attempts})" >&2
    sleep $((_attempt * 2))
    _attempt=$((_attempt + 1))
  done
}

__login_ghcr() {
  if [[ -n "${NSCELL_REGISTRY_TOKEN}" ]]; then
    printf '%s' "${NSCELL_REGISTRY_TOKEN}" |
      oras login ghcr.io \
        --username "${NSCELL_REGISTRY_USERNAME}" \
        --password-stdin
  fi
}

__retry 3 __login_ghcr

mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
grep -qw bpf /sys/kernel/security/lsm
test -x /usr/local/bin/oras
test -x /usr/bin/docker

cd /opt/nscell-ci
export NSCELL_IMAGE="${_nscell_image}"
export NSCELL_IMAGE_PLATFORM=linux/amd64
export NSCELL_CI_TEST_ROOT=/data/nscell
export NSCELL_GATE_MODE=strict
bash scripts/ci.sh setup-runtime-host
bash scripts/ci.sh verify-gate

case "${_test_target}" in
smoke)
  docker pull --platform linux/amd64 busybox:1.37.0
  docker run --rm --runtime nscell --pull=never busybox:1.37.0 sh -c \
    'test "$(uname -m)" = x86_64; test -n "$(cat /etc/hostname)"; echo nscell-vm-smoke-ok'
  ;;
*)
  bash scripts/ci.sh show-host-capabilities
  bash scripts/ci.sh run-workload "${_test_target}"
  bash scripts/ci.sh collect-logs || true
  ;;
esac

if [[ -n "${NSCELL_REGISTRY_TOKEN}" ]]; then
  oras logout ghcr.io || true
fi
EOF
}

__main "$@"
