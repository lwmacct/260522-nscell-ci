#!/usr/bin/env bash
# shellcheck disable=SC2154

__container_logs() {
  local _name="$1"
  if ! docker container inspect "$_name" >/dev/null 2>&1; then
    return
  fi
  docker ps -a --filter "name=^/${_name}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' >&2 || true
  docker inspect "$_name" --format 'container-state exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' >&2 || true
  docker logs --tail "${NSCELL_CI_LOG_TAIL:-60}" "$_name" >&2 || true
}

__dump_debug() {
  local _code=$?
  if [[ $_code -eq 0 ]]; then
    return
  fi

  echo "nscell runtime validation failed with exit code $_code" >&2
  for _name in "$_docker_in_docker_name" "$_kubernetes_k3s_name" "$_systemd_pid1_name" "$_procfs_memory_name" "$_procfs_cpu_name" "$_seccomp_notify_concurrency_name" "${_container_security_policy_name}-default" "${_container_security_policy_name}-dind" "${_container_security_policy_name}-k8s-node"; do
    __container_logs "$_name"
  done
  systemctl --no-pager --full status nscell-daemon.service docker.service 2>&1 |
    grep -E '(^●|Active:|Main PID:|failed|error|panic|SIGSEGV)' >&2 || true
  tail -260 "$_daemon_log" 2>/dev/null |
    grep -E 'panic:|SIGSEGV|nsenter|mount denied|mount .*failed|Error during syscall|Version:|Commit-ID:' >&2 || true
  tail -160 "$_daemon_log" 2>/dev/null |
    grep -E 'panic:|SIGSEGV|degraded|data plane|failed|Version:|Commit-ID:' >&2 || true
  __dump_nscell_state_snapshots
}
