#!/usr/bin/env bash

set -euo pipefail

_image_dir="${IMAGE_DIR:?IMAGE_DIR is required}"
_share_dir="${SHARE_DIR:?SHARE_DIR is required}"
_test_target="${TEST_TARGET:?TEST_TARGET is required}"
_vm_cpu="${VM_CPU:?VM_CPU is required}"
_vm_memory="${VM_MEMORY:?VM_MEMORY is required}"
_run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${_test_target}"
_resource_hash="$(printf '%s' "${_run_id}" | sha256sum | cut -d ' ' -f1)"
_resource_id="run-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${_resource_hash:0:16}"
_vm_name="${NSCELL_VM_NAME:-test-vm-${_resource_id}}"
_image_alias="${_vm_name}-image"

__verify_vm_contract() {
  if ! sudo incus exec "${_vm_name}" -- sh -c '
    test -f /etc/test-vm-profile &&
      test -x /usr/local/bin/oras &&
      test -x /usr/bin/docker &&
      test -r /opt/nscell-ci/scripts/ci.sh
  ' >/dev/null 2>&1; then
    echo "Incus agent is ready but the VM contract or CI 9p share is incomplete" >&2
    return 1
  fi
}

__import_image() {
  test -s "${_image_dir}/incus.tar.xz"
  test -s "${_image_dir}/disk.qcow2"
  test -s "${_image_dir}/SHA256SUMS"
  sudo incus --quiet image import \
    "${_image_dir}/incus.tar.xz" \
    "${_image_dir}/disk.qcow2" \
    --alias "${_image_alias}"
}

__main() {
  test -d "${_share_dir}"
  __import_image
  sudo incus --quiet init "${_image_alias}" "${_vm_name}" \
    --vm \
    -c security.secureboot=false \
    -c limits.cpu="${_vm_cpu}" \
    -c limits.memory="${_vm_memory}"
  sudo incus --quiet config device add \
    "${_vm_name}" ci-source disk \
    source="${_share_dir}" \
    path=/opt/nscell-ci \
    readonly=true \
    io.bus=9p
  sudo incus --quiet start "${_vm_name}"
  sudo incus wait --timeout=300 --interval=1 "${_vm_name}" agent
  __verify_vm_contract
  printf 'vm_name=%s\n' "${_vm_name}" >> "${GITHUB_OUTPUT}"
  printf 'image_alias=%s\n' "${_image_alias}" >> "${GITHUB_OUTPUT}"
}

__main "$@"
