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

_bundle_a="${_volume_root}/explicit-storage-persistence/bundle-a"
_bundle_b="${_volume_root}/explicit-storage-persistence/bundle-b"
_storage_root="${_volume_root}/explicit-storage-persistence/host-bind"
_export_name_a="nscell-explicit-storage-export-a-${_workload_resource_id:-default}"
_export_name_b="nscell-explicit-storage-export-b-${_workload_resource_id:-default}"
_container_id_a="explicit-storage-a${_workload_resource_id:+-${_workload_resource_id}}"
_container_id_b="explicit-storage-b${_workload_resource_id:+-${_workload_resource_id}}"
_volume_name="nscell-explicit-storage-${_workload_resource_id:-default}"
_volume_writer="${_volume_name}-writer"
_volume_reader="${_volume_name}-reader"

__cleanup() {
  sudo systemctl reset-failed nscell-daemon.service >/dev/null 2>&1 || true
  sudo systemctl start nscell-daemon.service >/dev/null 2>&1 || true
  __remove_oci_container "$_oci_runtime_root" "$_container_id_a"
  __remove_oci_container "$_oci_runtime_root" "$_container_id_b"
  docker rm -f "$_export_name_a" "$_export_name_b" "$_volume_writer" "$_volume_reader" >/dev/null 2>&1 || true
  docker volume rm -f "$_volume_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle_a"
  __remove_oci_bundle "$_bundle_b"
}

__wait_for_exit() {
  local _pid="$1" _deadline=$((SECONDS + 20))
  while ((SECONDS <= _deadline)); do
    if ! sudo test -d "/proc/${_pid}"; then return 0; fi
    sleep 0.2
  done
  echo "process ${_pid} did not exit" >&2
  return 1
}

__configure_explicit_bind() {
  local _bundle="$1" _source="$2" _tmp
  _tmp="$(mktemp)"
  # shellcheck disable=SC2024 # The temporary output file is owned by the caller.
  sudo jq --arg _source "$_source" \
    '.mounts += [{destination:"/persist", type:"bind", source:$_source, options:["rbind","rw"]}]' \
    "${_bundle}/config.json" >"$_tmp"
  sudo install -m 0600 "$_tmp" "${_bundle}/config.json"
  rm -f "$_tmp"
}

__create_and_start() {
  local _id="$1" _bundle="$2"
  sudo rm -f "${_bundle}/init.pid"
  sudo nscell --root "$_oci_runtime_root" create --bundle "$_bundle" --pid-file "${_bundle}/init.pid" "$_id"
  sudo nscell --root "$_oci_runtime_root" start "$_id"
  sudo nscell --root "$_oci_runtime_root" state "$_id" |
    jq -e '.status == "running" and .pid > 0' >/dev/null
}

__assert_marker() {
  local _id="$1" _want="$2" _got
  _got="$(sudo nscell --root "$_oci_runtime_root" exec "$_id" cat /persist/epoch-marker)"
  [[ "$_got" == "$_want" ]] || { echo "marker=$_got want=$_want" >&2; return 1; }
}

__mapped_root() {
  local _pid="$1"
  sudo awk '$1 == 0 { print $2; found=1; exit } END { if (!found) exit 1 }' "/proc/${_pid}/uid_map"
}

__main() {
  local _pid _daemon_pid _docker_pid _start_a _start_b
  if [[ "${1:-}" == cleanup ]]; then __cleanup; return; fi
  __require_cmd docker
  __require_cmd jq
  __require_cmd systemctl
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT
  __cleanup

  __prepare_oci_bundle "$_oci_base_image" "$_bundle_a" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' "$_export_name_a"
  __prepare_oci_bundle "$_oci_base_image" "$_bundle_b" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' "$_export_name_b"
  sudo install -d -m 0755 "$_storage_root"
  __configure_explicit_bind "$_bundle_a" "$_storage_root"
  __configure_explicit_bind "$_bundle_b" "$_storage_root"

  __log "writing data through an explicit host bind with the first identity"
  __create_and_start "$_container_id_a" "$_bundle_a"
  _pid="$(sudo cat "${_bundle_a}/init.pid")"
  sudo nscell --root "$_oci_runtime_root" exec "$_container_id_a" sh -c 'printf epoch-one > /persist/epoch-marker'
  __assert_marker "$_container_id_a" epoch-one
  [[ "$(sudo cat "${_storage_root}/epoch-marker")" == epoch-one ]]
  _start_a="$(__mapped_root "$_pid")"
  sudo nscell --root "$_oci_runtime_root" delete --force "$_container_id_a"

  __log "reading and updating the bind from a distinct rootfs and subid range"
  __create_and_start "$_container_id_b" "$_bundle_b"
  _pid="$(sudo cat "${_bundle_b}/init.pid")"
  _start_b="$(__mapped_root "$_pid")"
  [[ "$_start_a" != "$_start_b" ]] || { echo "distinct identities reused subid start ${_start_a}" >&2; return 1; }
  __assert_marker "$_container_id_b" epoch-one
  sudo nscell --root "$_oci_runtime_root" exec "$_container_id_b" sh -c 'printf epoch-two > /persist/epoch-marker'
  __assert_marker "$_container_id_b" epoch-two
  sudo nscell --root "$_oci_runtime_root" delete --force "$_container_id_b"

  __log "recreating the same identity after stop/start"
  __create_and_start "$_container_id_a" "$_bundle_a"
  _pid="$(sudo cat "${_bundle_a}/init.pid")"
  [[ "$(__mapped_root "$_pid")" == "$_start_a" ]]
  __assert_marker "$_container_id_a" epoch-two
  sudo nscell --root "$_oci_runtime_root" delete --force "$_container_id_a"

  __log "recreating explicit storage after an active fail-stop daemon restart"
  __create_and_start "$_container_id_a" "$_bundle_a"
  _pid="$(sudo cat "${_bundle_a}/init.pid")"
  _daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
  _docker_pid="$(systemctl show --property MainPID --value docker.service)"
  [[ "$_daemon_pid" =~ ^[1-9][0-9]*$ && "$_docker_pid" =~ ^[1-9][0-9]*$ ]]
  __container_capability_exists "$_container_id_a"
  sudo findmnt -rn -T "/var/lib/nscellfs/${_container_id_a}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'
  sudo systemctl kill --kill-whom=main --signal=SIGKILL nscell-daemon.service
  __wait_for_exit "$_daemon_pid"
  __wait_for_exit "$_pid"
  sudo systemctl reset-failed nscell-daemon.service
  sudo systemctl start nscell-daemon.service
  __assert_nscell_ready
  [[ "$(systemctl show --property MainPID --value docker.service)" == "$_docker_pid" ]] || {
    echo "Docker MainPID changed across the NSCell daemon restart" >&2
    return 1
  }
  sudo test ! -e "${_oci_runtime_root}/${_container_id_a}"
  if __container_capability_exists "$_container_id_a"; then
    echo "container capability survived daemon restart" >&2
    return 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs | grep -F "/${_container_id_a}"; then
    echo "VirtFS mount survived daemon restart" >&2
    return 1
  fi
  sudo nscell daemon gate status | jq -e '.registeredContainers == 0' >/dev/null
  __create_and_start "$_container_id_a" "$_bundle_a"
  _pid="$(sudo cat "${_bundle_a}/init.pid")"
  [[ "$(__mapped_root "$_pid")" == "$_start_a" ]]
  __assert_marker "$_container_id_a" epoch-two
  [[ "$(sudo sha256sum "${_storage_root}/epoch-marker" | awk '{print $1}')" == "$(printf epoch-two | sha256sum | awk '{print $1}')" ]]
  sudo nscell --root "$_oci_runtime_root" delete --force "$_container_id_a"

  __log "persisting a named Docker volume across distinct NSCell containers"
  docker volume create "$_volume_name" >/dev/null
  docker run --name "$_volume_writer" --runtime nscell -v "${_volume_name}:/persist" \
    "$_oci_base_image" sh -c 'printf named-volume > /persist/marker'
  docker run --name "$_volume_reader" --runtime nscell -v "${_volume_name}:/persist" \
    "$_oci_base_image" cat /persist/marker | grep -Fxq named-volume

  trap - EXIT
  __cleanup
  echo explicit-storage-persistence-validation-ok
}

__main "$@"
