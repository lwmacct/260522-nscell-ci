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
_exec_timeout="${NSCELL_CLEANUP_EXEC_TIMEOUT:-45s}"
_pull_timeout="${NSCELL_CLEANUP_PULL_TIMEOUT:-15s}"
_delete_timeout="${NSCELL_CLEANUP_DELETE_TIMEOUT:-30s}"

__bounded() {
  local _duration="$1"
  shift

  timeout --signal=TERM --kill-after=5s "${_duration}" "$@"
}

__pull_guest_file() {
  local _guest_path="$1"
  local _host_path="$2"

  __bounded "${_pull_timeout}" sudo incus file pull \
    "${_vm_name}${_guest_path}" "${_host_path}" 2>/dev/null || true
}

__collect_guest_logs() {
  mkdir -p "${_log_dir}"

  __pull_guest_file /var/log/nscell-daemon.log "${_log_dir}/nscell-daemon.log"
  __pull_guest_file /var/log/nscell-runtime-invocations.log \
    "${_log_dir}/nscell-runtime-invocations.log"
  __pull_guest_file /var/log/nscell-runtime.log "${_log_dir}/nscell-runtime.log"
  __pull_guest_file /var/lib/nscell/state/events.log "${_log_dir}/nscell-state-events.log"
  if [[ -f "${_log_dir}/nscell-state-events.log" ]]; then
    sudo chown "$(id -u):$(id -g)" "${_log_dir}/nscell-state-events.log"
    chmod 0644 "${_log_dir}/nscell-state-events.log"
  fi

  # shellcheck disable=SC2016,SC2024 # The quoted script expands inside the guest.
  __bounded "${_exec_timeout}" sudo incus exec "${_vm_name}" -- bash -euo pipefail -c '
    __guest_bounded() {
      timeout --signal=TERM --kill-after=2s \
        5s "$@"
    }

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
      __guest_bounded docker version || true
      oras version || true
      systemctl --no-pager --full status docker.service nscell-daemon.service || true
      systemctl cat nscell-daemon.service || true
      __guest_bounded nscell daemon gate status || true
      __guest_bounded docker info || true
      __guest_bounded docker ps -a || true
      __guest_bounded docker images || true
      systemctl --no-pager --full status incus-agent.service || true
      ps -eLo pid,ppid,tid,stat,wchan:32,comm,args || true
      for _pid in $(pgrep -x nscell || true); do
        printf "nscell process diagnostics: pid=%s\n" "${_pid}"
        cat "/proc/${_pid}/status" || true
        cat "/proc/${_pid}/wchan" || true
        for _task_dir in "/proc/${_pid}"/task/*; do
          printf "nscell task stack: %s\n" "${_task_dir##*/}"
          cat "${_task_dir}/wchan" || true
          cat "${_task_dir}/stack" || true
        done
      done
      __guest_bounded dmesg --ctime || true
      journalctl --no-pager -u incus-agent.service || true
      journalctl --no-pager -u docker.service -u nscell-daemon.service || true
      test -f /var/log/nscell-runtime-invocations.log && cat /var/log/nscell-runtime-invocations.log || true
      test -f /var/log/nscell-runtime.log && cat /var/log/nscell-runtime.log || true
    } 2>&1
    test -f /var/log/nscell-daemon.log && cat /var/log/nscell-daemon.log || true
  ' >"${_log_dir}/guest-diagnostics.log" 2>&1 || true
  if __bounded "${_pull_timeout}" sudo incus exec "${_vm_name}" -- \
    test -d /data/nscell/runs >/dev/null 2>&1; then
    install -d -m 0755 "${_log_dir}/run-logs"
    __bounded "${_exec_timeout}" sudo incus exec "${_vm_name}" -- bash -c '
      find /data/nscell/runs -type f -path "*/logs/*" -printf "%P\\0" |
        tar --null -C /data/nscell/runs --files-from - -cf -
    ' | __bounded "${_exec_timeout}" tar -xf - -C "${_log_dir}/run-logs" || true
  fi
}

__main() {
  __collect_guest_logs
  __bounded "${_delete_timeout}" sudo incus delete --force "${_vm_name}" 2>/dev/null || true
  __bounded "${_delete_timeout}" sudo incus image delete "${_image_alias}" 2>/dev/null || true
  rm -rf "${_share_dir}"
}

__main "$@"
