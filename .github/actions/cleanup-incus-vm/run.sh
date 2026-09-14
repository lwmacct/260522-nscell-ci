#!/usr/bin/env bash

set -euo pipefail

_test_target="${TEST_TARGET:?TEST_TARGET is required}"
_log_dir="${LOG_DIR:?LOG_DIR is required}"
_run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${_test_target}"
_resource_hash="$(printf '%s' "${_run_id}" | sha256sum | cut -d ' ' -f1)"
_resource_id="run-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${_resource_hash:0:16}"
_vm_name="${NSCELL_VM_NAME:-test-vm-${_resource_id}}"
_image_alias="${_vm_name}-image"
_share_dir="${RUNNER_TEMP:-/tmp}/test-vm-share-${_resource_id}"

__collect_guest_logs() {
  mkdir -p "${_log_dir}"
  # shellcheck disable=SC2024 # The runner user owns the diagnostics destination.
  sudo incus exec "${_vm_name}" -- bash -euo pipefail -c '
    {
      uname -a
      cat /etc/test-vm-profile || true
      cat /sys/kernel/security/lsm || true
      findmnt /sys/fs/bpf || true
      ip -4 address show || true
      ip -4 route show || true
      cat /etc/resolv.conf || true
      findmnt -T /opt/nscell-ci || true
      ls -ld /opt/nscell-ci || true
      ls -l /opt/nscell-ci/scripts/ci.sh || true
      docker version || true
      oras version || true
      systemctl --no-pager --full status docker.service nscell-daemon.service || true
      systemctl cat nscell-daemon.service || true
      nscell daemon gate status || true
      docker info || true
      docker ps -a || true
      docker images || true
      systemctl --no-pager --full status incus-agent.service || true
      journalctl --no-pager -u incus-agent.service || true
      journalctl --no-pager -u docker.service -u nscell-daemon.service || true
    } 2>&1
    test -f /var/log/nscell-daemon.log && cat /var/log/nscell-daemon.log || true
  ' >"${_log_dir}/guest-diagnostics.log" 2>&1 || true
  sudo incus file pull "${_vm_name}/var/log/nscell-daemon.log" \
    "${_log_dir}/nscell-daemon.log" 2>/dev/null || true
}

__main() {
  __collect_guest_logs
  sudo incus delete --force "${_vm_name}" 2>/dev/null || true
  sudo incus image delete "${_image_alias}" 2>/dev/null || true
  rm -rf "${_share_dir}"
}

__main "$@"
