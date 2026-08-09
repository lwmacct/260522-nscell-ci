#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"
source "${_workload_dir}/library/oci.sh"

_state_root="/run/nscell-ci-storage-crash-boundaries"
_wrapper_dir="/usr/local/libexec/nscell-ci-storage-crash-boundaries"
_drop_in_dir="/etc/systemd/system/nscell-daemon.service.d"
_drop_in="${_drop_in_dir}/storage-crash-boundaries.conf"
_sync_in_bundle="${_volume_root}/storage-crash-boundaries/sync-in-bundle"
_sync_out_bundle="${_volume_root}/storage-crash-boundaries/sync-out-bundle"
_sync_in_export="nscell-storage-crash-sync-in-${_workload_resource_id:-default}"
_sync_out_export="nscell-storage-crash-sync-out-${_workload_resource_id:-default}"
_managed_volume_roots=(
  /var/lib/nscell/work/buildkit
  /var/lib/nscell/work/containerd
  /var/lib/nscell/work/docker
  /var/lib/nscell/work/k0s
  /var/lib/nscell/work/kubelet
  /var/lib/nscell/work/rancher-k3s
  /var/lib/nscell/work/rancher-rke2
)

__wait_for_pid_exit() {
  local _pid="$1"
  local _label="$2"
  local _deadline=$((SECONDS + 20))

  while ((SECONDS <= _deadline)); do
    if ! sudo test -d "/proc/${_pid}"; then
      return 0
    fi
    sleep 0.2
  done
  echo "${_label} process ${_pid} did not exit" >&2
  return 1
}

__start_daemon() {
  sudo systemctl reset-failed nscell-daemon.service >/dev/null 2>&1 || true
  sudo systemctl start nscell-daemon.service
  __assert_nscell_ready
}

__cleanup() {
  sudo install -d -m 0700 "$_state_root"
  sudo touch "${_state_root}/triggered"
  __start_daemon >/dev/null 2>&1 || true
  __remove_oci_container "$_oci_runtime_root" "$_storage_crash_sync_in_id"
  __remove_oci_container "$_oci_runtime_root" "$_storage_crash_sync_out_id"
  docker rm -f "$_sync_in_export" "$_sync_out_export" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_sync_in_bundle"
  __remove_oci_bundle "$_sync_out_bundle"
  sudo rm -f "$_drop_in"
  sudo systemctl daemon-reload
  sudo systemctl restart nscell-daemon.service >/dev/null 2>&1 || true
  sudo rm -rf "$_state_root" "$_wrapper_dir"
}

__install_rsync_wrapper() {
  sudo install -d -m 0700 "$_state_root" "$_wrapper_dir" "$_drop_in_dir"
  sudo install -m 0755 /usr/bin/rsync "${_wrapper_dir}/rsync.real"
  sudo install -m 0755 "${_workload_path}/rsync-wrapper.sh" "${_wrapper_dir}/rsync"
  printf '%s\n' \
    '[Service]' \
    "Environment=PATH=${_wrapper_dir}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" |
    sudo tee "$_drop_in" >/dev/null
  sudo rm -f "${_state_root}/mode" "${_state_root}/triggered" "${_state_root}/daemon.pid" \
    "${_state_root}/invocations.log" "${_state_root}/rsync-output.log"
  sudo "${_wrapper_dir}/rsync" --version >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl restart nscell-daemon.service
  __assert_nscell_ready
}

__arm_crash() {
  local _mode="$1"
  local _id="$2"

  printf '%s:%s\n' "$_mode" "$_id" | sudo tee "${_state_root}/mode" >/dev/null
  sudo rm -f "${_state_root}/triggered" "${_state_root}/daemon.pid" \
    "${_state_root}/invocations.log" "${_state_root}/rsync-output.log"
}

__assert_daemon_was_killed() {
  local _expected_pid="$1"
  local _expected_trigger="$2"
  local _actual_pid _actual_trigger

  sudo test -s "${_state_root}/triggered"
  sudo test -s "${_state_root}/daemon.pid"
  _actual_trigger="$(sudo cat "${_state_root}/triggered")"
  _actual_pid="$(sudo cat "${_state_root}/daemon.pid")"
  if [[ "$_actual_trigger" != "$_expected_trigger" ]]; then
    echo "unexpected rsync crash trigger: got ${_actual_trigger}, want ${_expected_trigger}" >&2
    return 1
  fi
  if [[ "$_actual_pid" != "$_expected_pid" ]]; then
    echo "rsync wrapper killed daemon ${_actual_pid}, want ${_expected_pid}" >&2
    return 1
  fi
  __wait_for_pid_exit "$_expected_pid" daemon
}

__wait_for_crash_trigger() {
  local _expected_pid="$1"
  local _expected_trigger="$2"
  local _deadline=$((SECONDS + 20))
  local _actual_pid _actual_trigger

  while ((SECONDS <= _deadline)); do
    if sudo test -s "${_state_root}/triggered" &&
      sudo test -s "${_state_root}/daemon.pid"; then
      _actual_trigger="$(sudo cat "${_state_root}/triggered")"
      _actual_pid="$(sudo cat "${_state_root}/daemon.pid")"
      if [[ "$_actual_trigger" != "$_expected_trigger" ]]; then
        echo "unexpected rsync crash trigger: got ${_actual_trigger}, want ${_expected_trigger}" >&2
        return 1
      fi
      if [[ "$_actual_pid" != "$_expected_pid" ]]; then
        echo "rsync wrapper observed daemon ${_actual_pid}, want ${_expected_pid}" >&2
        return 1
      fi
      return 0
    fi
    sleep 0.2
  done
  echo "rsync crash trigger was not armed for ${_expected_trigger}" >&2
  if sudo test -f "${_state_root}/invocations.log"; then
    sudo tail -100 "${_state_root}/invocations.log" >&2 || true
  fi
  if sudo test -f "${_state_root}/rsync-output.log"; then
    sudo cat "${_state_root}/rsync-output.log" >&2 || true
  fi
  return 1
}

__assert_json_map_lacks_id() {
  local _path="$1"
  local _map="$2"
  local _id="$3"

  sudo test -f "$_path"
  sudo jq -e --arg _id "$_id" --arg _map "$_map" \
    '(.[$_map] // {}) | has($_id) | not' "$_path" >/dev/null
}

__assert_recovery_clean() {
  local _id="$1"
  local _container_pid="${2:-}"
  local _root _journal_name _journal

  if [[ -n "$_container_pid" ]]; then
    __wait_for_pid_exit "$_container_pid" "orphaned container init"
  fi
  sudo test ! -e "${_oci_runtime_root}/${_id}"
  if __container_capability_exists "$_id"; then
    echo "container capability survived recovery for ${_id}" >&2
    return 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs | grep -F "/${_id}"; then
    echo "VirtFS mount survived recovery for ${_id}" >&2
    return 1
  fi
  for _root in "${_managed_volume_roots[@]}"; do
    if sudo test -e "${_root}/${_id}"; then
      echo "managed volume survived recovery: ${_root}/${_id}" >&2
      return 1
    fi
  done
  for _journal_name in buildkit containerd docker k0s kubelet rancher-k3s rancher-rke2; do
    _journal="/var/lib/nscell/state/volumes/${_journal_name}.json"
    sudo test -e "$_journal" || continue
    __assert_json_map_lacks_id "$_journal" volumes "$_id"
  done
  __assert_json_map_lacks_id /var/lib/nscell/state/leases.json leases "$_id"
  __assert_json_map_lacks_id /var/lib/nscell/state/subids.json allocations "$_id"
  sudo nscell daemon status |
    jq -e --arg _id "$_id" \
      'all(.sessions[]?; .id != $_id) and all(.resourceLeases[]?; .id != $_id)' >/dev/null
}

__create_container() {
  local _bundle="$1"
  local _id="$2"

  sudo rm -f "${_bundle}/init.pid"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_id"
}

__assert_sync_in_recovery() {
  local _daemon_pid _create_pid _create_status=0 _backing

  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_sync_in_bundle" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' \
    "$_sync_in_export"
  sudo install -d -m 0700 "${_sync_in_bundle}/rootfs/var/lib/docker"
  printf 'sync-in-partial-original\n' |
    sudo tee "${_sync_in_bundle}/rootfs/var/lib/docker/partial.txt" >/dev/null
  printf 'sync-in-untouched-original\n' |
    sudo tee "${_sync_in_bundle}/rootfs/var/lib/docker/untouched.txt" >/dev/null

  __log "killing the daemon during a partial managed-volume SyncIn"
  __arm_crash sync-in "$_storage_crash_sync_in_id"
  _daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
  timeout 45s sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_sync_in_bundle" \
    --pid-file "${_sync_in_bundle}/init.pid" \
    "$_storage_crash_sync_in_id" &
  _create_pid=$!
  __wait_for_crash_trigger "$_daemon_pid" "sync-in:${_storage_crash_sync_in_id}"
  sudo kill -KILL "$_daemon_pid"
  __assert_daemon_was_killed "$_daemon_pid" "sync-in:${_storage_crash_sync_in_id}"
  wait "$_create_pid" || _create_status=$?
  if ((_create_status == 0)); then
    echo "OCI create unexpectedly succeeded after SyncIn crash" >&2
    return 1
  fi
  if ((_create_status == 124)); then
    echo "OCI create timed out after SyncIn crash" >&2
    return 1
  fi

  _backing="/var/lib/nscell/work/docker/${_storage_crash_sync_in_id}"
  if [[ "$(sudo cat "${_backing}/partial.txt")" != "sync-in-partial-original" ]]; then
    echo "SyncIn crash did not leave the expected partial backing" >&2
    return 1
  fi
  sudo test ! -e "${_backing}/untouched.txt"
  sudo jq -e --arg _id "$_storage_crash_sync_in_id" \
    '.volumes[$_id].phase == "creating"' \
    /var/lib/nscell/state/volumes/docker.json >/dev/null

  __log "restarting and discarding the incomplete SyncIn backing"
  __start_daemon
  __assert_recovery_clean "$_storage_crash_sync_in_id"
  if [[ "$(sudo cat "${_sync_in_bundle}/rootfs/var/lib/docker/partial.txt")" != "sync-in-partial-original" ]] ||
    [[ "$(sudo cat "${_sync_in_bundle}/rootfs/var/lib/docker/untouched.txt")" != "sync-in-untouched-original" ]]; then
    echo "incomplete SyncIn backing overwrote the original rootfs during recovery" >&2
    return 1
  fi
}

__assert_sync_out_recovery() {
  local _daemon_pid _container_pid _delete_pid _backing _delete_status=0

  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_sync_out_bundle" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' \
    "$_sync_out_export"
  sudo install -d -m 0700 "${_sync_out_bundle}/rootfs/var/lib/docker"
  printf 'sync-out-seed-original\n' |
    sudo tee "${_sync_out_bundle}/rootfs/var/lib/docker/seed.txt" >/dev/null

  __log "creating a container before arming the SyncOut crash"
  sudo touch "${_state_root}/triggered"
  __create_container "$_sync_out_bundle" "$_storage_crash_sync_out_id"
  sudo nscell --root "$_oci_runtime_root" start "$_storage_crash_sync_out_id"
  _container_pid="$(sudo cat "${_sync_out_bundle}/init.pid")"
  sudo nscell --root "$_oci_runtime_root" exec \
    "$_storage_crash_sync_out_id" /bin/sh -c \
    'printf sync-out-partial-new > /var/lib/docker/partial.txt; printf sync-out-complete-new > /var/lib/docker/complete.txt; printf sync-out-seed-new > /var/lib/docker/seed.txt'

  __log "killing the daemon during a partial managed-volume SyncOut"
  __arm_crash sync-out "$_storage_crash_sync_out_id"
  _daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
  timeout 45s sudo nscell --root "$_oci_runtime_root" delete --force "$_storage_crash_sync_out_id" &
  _delete_pid=$!
  __wait_for_crash_trigger "$_daemon_pid" "sync-out:${_storage_crash_sync_out_id}"
  sudo kill -KILL "$_daemon_pid"
  __assert_daemon_was_killed "$_daemon_pid" "sync-out:${_storage_crash_sync_out_id}"
  wait "$_delete_pid" || _delete_status=$?
  if ((_delete_status == 124)); then
    echo "OCI delete timed out after SyncOut crash" >&2
    return 1
  fi

  _backing="/var/lib/nscell/work/docker/${_storage_crash_sync_out_id}"
  if [[ "$(sudo cat "${_sync_out_bundle}/rootfs/var/lib/docker/partial.txt")" != "sync-out-partial-new" ]]; then
    echo "SyncOut crash did not copy the expected partial file" >&2
    return 1
  fi
  sudo test ! -e "${_sync_out_bundle}/rootfs/var/lib/docker/complete.txt"
  if [[ "$(sudo cat "${_backing}/complete.txt")" != "sync-out-complete-new" ]]; then
    echo "SyncOut source backing lost container data before recovery" >&2
    return 1
  fi
  sudo jq -e --arg _id "$_storage_crash_sync_out_id" \
    '.volumes[$_id].phase == "active"' \
    /var/lib/nscell/state/volumes/docker.json >/dev/null

  __log "restarting and replaying the incomplete SyncOut"
  __start_daemon
  __assert_recovery_clean "$_storage_crash_sync_out_id" "$_container_pid"
  if [[ "$(sudo cat "${_sync_out_bundle}/rootfs/var/lib/docker/partial.txt")" != "sync-out-partial-new" ]] ||
    [[ "$(sudo cat "${_sync_out_bundle}/rootfs/var/lib/docker/complete.txt")" != "sync-out-complete-new" ]] ||
    [[ "$(sudo cat "${_sync_out_bundle}/rootfs/var/lib/docker/seed.txt")" != "sync-out-seed-new" ]]; then
    echo "replayed SyncOut did not restore all backing data to the rootfs" >&2
    return 1
  fi
}

__main() {
  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd jq
  __require_cmd rsync
  __require_cmd systemctl
  __require_cmd timeout
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT

  __cleanup
  __install_rsync_wrapper
  __assert_sync_in_recovery
  __assert_sync_out_recovery

  trap - EXIT
  __cleanup
  echo "storage-crash-boundaries-validation-ok"
}

__main "$@"
