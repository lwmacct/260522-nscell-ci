#!/usr/bin/env bash

__safe_resource_id() {
  local _value="$1"
  printf '%s' "$_value" | tr -c '[:alnum:]_.-' '-'
}

__image_tag() {
  local _repo="$1"
  local _default_tag="$2"

  if [[ -n "$_workload_resource_id" ]]; then
    printf '%s:%s\n' "$_repo" "$_workload_resource_id"
  else
    printf '%s:%s\n' "$_repo" "$_default_tag"
  fi
}

_test_root="${NSCELL_CI_TEST_ROOT:-/data/nscell}"
_workload_id="${NSCELL_WORKLOAD_ID:-}"
_workload_resource_id=""
_workload_run_root="$_test_root"
if [[ -n "$_workload_id" ]]; then
  _workload_resource_id="$(__safe_resource_id "$_workload_id")"
  _workload_run_root="${_test_root}/runs/${_workload_resource_id}"
fi

_image_cache_dir="${NSCELL_CI_IMAGE_CACHE_DIR:-${_test_root}/images}"
_volume_root="${NSCELL_CI_VOLUME_ROOT:-${_workload_run_root}/volumes}"
_log_root="${NSCELL_CI_LOG_ROOT:-${_workload_run_root}/logs}"
_daemon_log="${NSCELL_DAEMON_LOG:-/var/log/nscell-daemon.log}"

_oci_base_image="${NSCELL_CI_OCI_BASE_IMAGE:-docker.io/library/busybox:1.37.0}"
_oci_runtime_root="${NSCELL_CI_OCI_RUNTIME_ROOT:-/run/nscell/runtime}"
_oci_lifecycle_id="${NSCELL_CI_OCI_LIFECYCLE_ID:-oci-lifecycle${_workload_resource_id:+-${_workload_resource_id}}}"
_oci_mount_semantics_id="${NSCELL_CI_OCI_MOUNT_SEMANTICS_ID:-oci-mount-semantics${_workload_resource_id:+-${_workload_resource_id}}}"
_fuse_copy_file_range_name="${NSCELL_CI_FUSE_COPY_FILE_RANGE_NAME:-nscell-fuse-copy-file-range${_workload_resource_id:+-${_workload_resource_id}}}"
_fuse_copy_file_range_base_image="${NSCELL_CI_FUSE_COPY_FILE_RANGE_BASE_IMAGE:-docker.io/library/python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a}"
_fuse_request_timeout_name="${NSCELL_CI_FUSE_REQUEST_TIMEOUT_NAME:-nscell-fuse-request-timeout${_workload_resource_id:+-${_workload_resource_id}}}"
_resource_limits_id="${NSCELL_CI_RESOURCE_LIMITS_ID:-resource-limits${_workload_resource_id:+-${_workload_resource_id}}}"
_resource_update_id="${NSCELL_CI_RESOURCE_UPDATE_ID:-resource-update${_workload_resource_id:+-${_workload_resource_id}}}"
_storage_lifecycle_id="${NSCELL_CI_STORAGE_LIFECYCLE_ID:-storage-lifecycle${_workload_resource_id:+-${_workload_resource_id}}}"
_daemon_fail_stop_id="${NSCELL_CI_DAEMON_FAIL_STOP_ID:-daemon-fail-stop${_workload_resource_id:+-${_workload_resource_id}}}"
_daemon_crash_recovery_id="${NSCELL_CI_DAEMON_CRASH_RECOVERY_ID:-daemon-crash-recovery${_workload_resource_id:+-${_workload_resource_id}}}"
_rootfs_event_recovery_id="${NSCELL_CI_ROOTFS_EVENT_RECOVERY_ID:-rootfs-event-recovery${_workload_resource_id:+-${_workload_resource_id}}}"
_daemon_dial_retry_id="${NSCELL_CI_DAEMON_DIAL_RETRY_ID:-daemon-dial-retry${_workload_resource_id:+-${_workload_resource_id}}}"
_storage_crash_sync_in_id="${NSCELL_CI_STORAGE_CRASH_SYNC_IN_ID:-storage-crash-sync-in${_workload_resource_id:+-${_workload_resource_id}}}"
_storage_crash_sync_out_id="${NSCELL_CI_STORAGE_CRASH_SYNC_OUT_ID:-storage-crash-sync-out${_workload_resource_id:+-${_workload_resource_id}}}"

_docker_in_docker_name="${NSCELL_CI_DOCKER_IN_DOCKER_NAME:-nscell-docker-in-docker${_workload_resource_id:+-${_workload_resource_id}}}"
_shared_netns_primary_name="${NSCELL_CI_SHARED_NETNS_PRIMARY_NAME:-nscell-shared-netns-primary${_workload_resource_id:+-${_workload_resource_id}}}"
_shared_netns_secondary_name="${NSCELL_CI_SHARED_NETNS_SECONDARY_NAME:-nscell-shared-netns-secondary${_workload_resource_id:+-${_workload_resource_id}}}"
_docker_in_docker_network="${NSCELL_CI_DOCKER_IN_DOCKER_NETWORK:-nscell-docker-in-docker${_workload_resource_id:+-${_workload_resource_id}}}"
_docker_in_docker_base_image="${NSCELL_CI_DOCKER_IN_DOCKER_BASE_IMAGE:-docker.io/library/docker:29.6.2-dind}"
_docker_in_docker_image="${NSCELL_CI_DOCKER_IN_DOCKER_IMAGE:-$(__image_tag nscell-ci/docker-in-docker latest)}"

_container_security_policy_name="${NSCELL_CI_CONTAINER_SECURITY_POLICY_NAME:-nscell-container-security-policy${_workload_resource_id:+-${_workload_resource_id}}}"
_container_security_policy_base_image="${NSCELL_CI_CONTAINER_SECURITY_POLICY_BASE_IMAGE:-docker.io/library/python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a}"
_container_security_policy_image="${NSCELL_CI_CONTAINER_SECURITY_POLICY_IMAGE:-$(__image_tag nscell-ci/container-security-policy latest)}"

_kubernetes_k3s_name="${NSCELL_CI_KUBERNETES_K3S_NAME:-nscell-kubernetes-k3s${_workload_resource_id:+-${_workload_resource_id}}}"
_kubernetes_k3s_base_image="${NSCELL_CI_KUBERNETES_K3S_BASE_IMAGE:-docker.io/rancher/k3s:v1.30.6-k3s1}"
_kubernetes_k3s_image="${NSCELL_CI_KUBERNETES_K3S_IMAGE:-$(__image_tag nscell-ci/kubernetes-k3s latest)}"
_kubernetes_k3s_pause_source_image="${NSCELL_CI_KUBERNETES_K3S_PAUSE_SOURCE_IMAGE:-docker.io/rancher/mirrored-pause:3.6}"
_kubernetes_k3s_pause_image="${NSCELL_CI_KUBERNETES_K3S_PAUSE_IMAGE:-docker.io/rancher/mirrored-pause:3.6}"
_kubernetes_k3s_pod_name="${NSCELL_CI_KUBERNETES_K3S_POD_NAME:-nscell-kubernetes-k3s-nginx${_workload_resource_id:+-${_workload_resource_id}}}"

_systemd_pid1_name="${NSCELL_CI_SYSTEMD_PID1_NAME:-nscell-systemd-pid1${_workload_resource_id:+-${_workload_resource_id}}}"
_systemd_pid1_image="${NSCELL_CI_SYSTEMD_PID1_IMAGE:-ghcr.io/lwmacct/260522-nscell-ci:systemd-pid1-latest}"

_procfs_memory_name="${NSCELL_CI_PROCFS_MEMORY_NAME:-nscell-procfs-memory${_workload_resource_id:+-${_workload_resource_id}}}"
_procfs_memory_base_image="${NSCELL_CI_PROCFS_MEMORY_BASE_IMAGE:-docker.io/library/python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a}"
_procfs_memory_image="${NSCELL_CI_PROCFS_MEMORY_IMAGE:-$(__image_tag nscell-ci/procfs-memory latest)}"
_procfs_memory_memory_bytes="${NSCELL_CI_PROCFS_MEMORY_MEMORY_BYTES:-134217728}"
_procfs_memory_swap_bytes="${NSCELL_CI_PROCFS_MEMORY_SWAP_BYTES:-268435456}"
_procfs_memory_overflow_alloc_bytes="${NSCELL_CI_PROCFS_MEMORY_OVERFLOW_ALLOC_BYTES:-268435456}"
_procfs_memory_swap_exercise_alloc_bytes="${NSCELL_CI_PROCFS_MEMORY_SWAP_EXERCISE_ALLOC_BYTES:-201326592}"

_procfs_cpu_name="${NSCELL_CI_PROCFS_CPU_NAME:-nscell-procfs-cpu${_workload_resource_id:+-${_workload_resource_id}}}"
_procfs_cpu_base_image="${NSCELL_CI_PROCFS_CPU_BASE_IMAGE:-docker.io/library/python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a}"
_procfs_cpu_image="${NSCELL_CI_PROCFS_CPU_IMAGE:-$(__image_tag nscell-ci/procfs-cpu latest)}"
_procfs_cpu_quota_cpus="${NSCELL_CI_PROCFS_CPU_QUOTA_CPUS:-0.1}"

_new_mount_api_deny_name="${NSCELL_CI_NEW_MOUNT_API_DENY_NAME:-nscell-new-mount-api-deny${_workload_resource_id:+-${_workload_resource_id}}}"

_seccomp_notify_concurrency_name="${NSCELL_CI_SECCOMP_NOTIFY_CONCURRENCY_NAME:-nscell-seccomp-notify-concurrency${_workload_resource_id:+-${_workload_resource_id}}}"
_seccomp_notify_concurrency_base_image="${NSCELL_CI_SECCOMP_NOTIFY_CONCURRENCY_BASE_IMAGE:-docker.io/library/python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a}"
_seccomp_notify_concurrency_image="${NSCELL_CI_SECCOMP_NOTIFY_CONCURRENCY_IMAGE:-$(__image_tag nscell-ci/seccomp-notify-concurrency latest)}"
_seccomp_notify_concurrency_processes="${NSCELL_CI_SECCOMP_NOTIFY_CONCURRENCY_PROCESSES:-24}"
_seccomp_notify_concurrency_sysinfo_iterations="${NSCELL_CI_SECCOMP_NOTIFY_CONCURRENCY_SYSINFO_ITERATIONS:-32}"
_seccomp_notify_concurrency_openat2_iterations="${NSCELL_CI_SECCOMP_NOTIFY_CONCURRENCY_OPENAT2_ITERATIONS:-8}"
_seccomp_notify_concurrency_mount_iterations="${NSCELL_CI_SECCOMP_NOTIFY_CONCURRENCY_MOUNT_ITERATIONS:-8}"

_inner_nginx_base_image="${NSCELL_CI_INNER_NGINX_BASE_IMAGE:-docker.io/nginx:latest}"
_inner_nginx_image="${NSCELL_CI_INNER_NGINX_IMAGE:-$(__image_tag nscell-ci/nginx-workload latest)}"

__require_cmd() {
  local _cmd="$1"
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "missing required command: $_cmd" >&2
    exit 1
  fi
}

__log() {
  printf '\n==> %s\n' "$*" >&2
}

__init_ci_dirs() {
  install -d -m 0755 "$_test_root" "$_image_cache_dir" "$_volume_root" "$_log_root"
}
