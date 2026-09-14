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

__cleanup() {
  docker rm -f \
    "$_shared_netns_secondary_name" \
    "$_shared_netns_primary_name" \
    >/dev/null 2>&1 || true
}

__container_pid() {
  docker inspect "$1" --format '{{.State.Pid}}'
}

__assert_running() {
  docker inspect "$1" --format '{{.State.Running}}' | grep -qx true
}

__netns_link() {
  readlink "/proc/$1/ns/net"
}

__main() {
  local _primary_pid _secondary_pid _primary_netns _secondary_netns
  local _primary_proc_net _secondary_proc_net

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT
  __cleanup

  __ensure_host_image "$_oci_base_image"
  __log "starting primary container for shared network namespace validation"
  docker run -d \
    --name "$_shared_netns_primary_name" \
    --hostname shared-netns-primary \
    --runtime nscell \
    --label io.backend.security.profile=default \
    "$_oci_base_image" \
    tail -f /dev/null >/dev/null

  __log "joining a second NSCell container to the primary network namespace"
  docker run -d \
    --name "$_shared_netns_secondary_name" \
    --runtime nscell \
    --network "container:$_shared_netns_primary_name" \
    --label io.backend.security.profile=default \
    "$_oci_base_image" \
    tail -f /dev/null >/dev/null

  _primary_pid="$(__container_pid "$_shared_netns_primary_name")"
  _secondary_pid="$(__container_pid "$_shared_netns_secondary_name")"
  _primary_netns="$(__netns_link "$_primary_pid")"
  _secondary_netns="$(__netns_link "$_secondary_pid")"
  printf 'shared-netns primary=%s secondary=%s\n' \
    "$_primary_netns" "$_secondary_netns"
  if [[ -z "$_primary_pid" || -z "$_secondary_pid" ]]; then
    echo "shared-network workload did not expose container PIDs" >&2
    exit 1
  fi
  if [[ "$_primary_netns" != "$_secondary_netns" ]]; then
    echo "shared-network containers use different network namespaces" >&2
    exit 1
  fi

  _primary_proc_net="$(docker exec \
    "$_shared_netns_primary_name" \
    cat /proc/sys/net/ipv4/ping_group_range)"
  _secondary_proc_net="$(docker exec \
    "$_shared_netns_secondary_name" \
    cat /proc/sys/net/ipv4/ping_group_range)"
  printf 'shared-netns-proc primary=%q secondary=%q\n' \
    "$_primary_proc_net" "$_secondary_proc_net"
  if [[ -z "$_primary_proc_net" || "$_primary_proc_net" != "$_secondary_proc_net" ]]; then
    echo "procfs network state differs across the shared network namespace" >&2
    exit 1
  fi

  __log "keeping the shared namespace alive after primary container removal"
  docker rm -f "$_shared_netns_primary_name" >/dev/null
  __assert_running "$_shared_netns_secondary_name"
  if ! docker exec "$_shared_netns_secondary_name" \
    test -r /proc/sys/net/ipv4/ping_group_range; then
    echo "secondary shared-network container lost procfs network state" >&2
    exit 1
  fi

  if sudo grep -Eq 'panic|runtime error: invalid memory address' "$_daemon_log"; then
    echo "daemon log contains a crash after shared network namespace use" >&2
    sudo tail -100 "$_daemon_log" >&2
    exit 1
  fi
  __assert_nscell_ready

  trap - EXIT
  __cleanup
  echo "shared-netns-lifecycle-validation-ok"
}

__main "$@"
