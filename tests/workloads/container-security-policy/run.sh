#!/usr/bin/env bash
# shellcheck disable=all

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"
source "${_workload_dir}/library/oci.sh"

_identity_bundle="${_volume_root}/container-security-policy/invalid-host-root-map"
_identity_id="container-security-host-root-map${_workload_resource_id:+-${_workload_resource_id}}"
_identity_export_name="nscell-oci-export-identity${_workload_resource_id:+-${_workload_resource_id}}"

__require_bpf_lsm() {
  if sudo nscell daemon gate status |
    jq -e '.enabled == true and .mode == "strict" and .enforce == true and .features.lsmActive == true and .auditEnabled == true' >/dev/null; then
    __log "strict BPF LSM policy and audit checks required"
    return
  fi
  echo "strict BPF LSM gate with audit is required for container-security-policy" >&2
  sudo nscell daemon gate status >&2 || true
  exit 1
}

__state_json() {
  local _name="$1"
  local _cid _runtime_root
  local -a _runtime_roots=(
    /run/docker/runtime-runc/moby
    /run/docker/runtime-runc/nscell
    /run/nscell/runtime
  )

  _cid="$(docker inspect "$_name" --format '{{.Id}}')"
  for _runtime_root in "${_runtime_roots[@]}"; do
    if sudo test -f "${_runtime_root}/${_cid}/state.json"; then
      sudo nscell --root "$_runtime_root" state "$_cid"
      return
    fi
  done
  echo "failed to locate nscell state.json for ${_name} (${_cid})" >&2
  exit 1
}

__check_devices() {
  local _name="$1"
  local _state_json

  __log "checking cgroup device policy diagnostics for ${_name}"
  _state_json="$(__state_json "$_name")"
  if ! grep -q '"cgroup_device_policy": {' <<<"$_state_json"; then
    echo "nscell state did not expose cgroup_device_policy for ${_name}" >&2
    printf '%s\n' "$_state_json" >&2
    exit 1
  fi
  if ! grep -Eq '"(systemd_device_configured|ebpf_device_filter_configured)": true' <<<"$_state_json"; then
    echo "cgroup_device_policy did not report an active systemd or eBPF device policy for ${_name}" >&2
    printf '%s\n' "$_state_json" >&2
    exit 1
  fi
  echo "cgroup-device-policy-ok ${_name}"
}

__run_probe() {
  local _name="$1"
  local _check="$2"

  docker exec "$_name" nscell-ci-container-security-policy-probe "$_check"
}

__check_process_identity_isolation() {
  local _name="$1"
  local _pid _host_id _kind _ns _host_ns _container_ns

  __run_probe "$_name" process-identity-isolation
  _pid="$(docker inspect "$_name" --format '{{.State.Pid}}')"
  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "invalid container init pid for ${_name}: ${_pid}" >&2
    exit 1
  fi

  for _kind in Uid Gid; do
    _host_id="$(sudo awk -v _kind="${_kind}:" '$1 == _kind { print $3; exit }' "/proc/${_pid}/status")"
    if [[ ! "$_host_id" =~ ^[0-9]+$ ]] || [[ "$_host_id" == "0" ]]; then
      echo "container init maps to invalid host ${_kind,,}: ${_host_id}" >&2
      exit 1
    fi
  done

  for _ns in user mnt pid ipc uts net cgroup; do
    _host_ns="$(sudo readlink "/proc/1/ns/${_ns}")"
    _container_ns="$(sudo readlink "/proc/${_pid}/ns/${_ns}")"
    if [[ -z "$_host_ns" || -z "$_container_ns" || "$_host_ns" == "$_container_ns" ]]; then
      echo "container ${_name} shares host ${_ns} namespace: ${_container_ns}" >&2
      exit 1
    fi
  done
  echo "process-namespace-isolation-ok ${_name} pid=${_pid}"
}

__check_host_root_mapping_rejected() {
  local _config_tmp _create_log

  __log "checking rejection of process mappings to host uid/gid 0"
  __remove_oci_container "$_oci_runtime_root" "$_identity_id"
  __remove_oci_bundle "$_identity_bundle"
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_identity_bundle" \
    '["/bin/sh", "-c", "sleep 30"]' \
    "$_identity_export_name"

  _config_tmp="$(mktemp)"
  _create_log="${_log_root}/container-security-host-root-map.log"
  sudo jq \
    '.linux.uidMappings = [{"containerID": 0, "hostID": 0, "size": 65536}]
      | .linux.gidMappings = [{"containerID": 0, "hostID": 0, "size": 65536}]' \
    "${_identity_bundle}/config.json" >"$_config_tmp"
  sudo install -m 0600 "$_config_tmp" "${_identity_bundle}/config.json"
  rm -f "$_config_tmp"

  if sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_identity_bundle" "$_identity_id" >"$_create_log" 2>&1; then
    echo "OCI create accepted process uid/gid mappings to host ID 0" >&2
    exit 1
  fi
  if ! grep -Eq 'host ID 0|breaks container isolation' "$_create_log"; then
    echo "OCI create failed without the expected host-root mapping rejection" >&2
    cat "$_create_log" >&2
    exit 1
  fi
  if sudo test -e "${_oci_runtime_root}/${_identity_id}" || __container_capability_exists "$_identity_id"; then
    echo "rejected host-root mapping left runtime or capability state" >&2
    exit 1
  fi
  echo "host-root-process-mapping-rejected-ok"
}

__assert_bpf_mount_audit() {
  local _log_start="$1"
  local _profile="$2"
  local _fs_type="$3"
  local _deadline _log

  _deadline=$((SECONDS + 15))
  while ((SECONDS <= _deadline)); do
    _log="$(tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null || true)"
    if awk \
      -v _profile="profile=${_profile}" \
      -v _fs_type="name=${_fs_type}" \
      'index($0, "BPF LSM gate audit event") &&
			 index($0, "operation=mount") &&
			 index($0, "decision=deny") &&
			 index($0, "reason=policy") &&
			 index($0, _profile) &&
			 index($0, _fs_type) { found = 1 }
			 END { exit !found }' <<<"$_log"; then
      return 0
    fi
    sleep 0.5
  done

  echo "missing BPF LSM mount deny audit for profile=${_profile} fs_type=${_fs_type}" >&2
  tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null |
    grep -E 'BPF LSM gate audit event|slow seccomp notification|mount denied|operation=mount|fs_type=' |
    tail -160 >&2 || true
  exit 1
}

__assert_unsafe_mount_audits() {
  local _log_start="$1"
  local _profile="$2"
  local _fs_type

  for _fs_type in securityfs debugfs tracefs configfs; do
    __assert_bpf_mount_audit "$_log_start" "$_profile" "$_fs_type"
  done
}

__assert_bpf_kernel_interface_audit() {
  local _log_start="$1"
  local _profile="$2"
  local _file_name="$3"
  local _deadline _log

  _deadline=$((SECONDS + 15))
  while ((SECONDS <= _deadline)); do
    _log="$(tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null || true)"
    if awk \
      -v _profile="profile=${_profile}" \
      -v _file_name="file_name=${_file_name}" \
      'index($0, "BPF LSM gate audit event") &&
			 (index($0, "operation=file_open") || index($0, "operation=inode_permission")) &&
			 index($0, "decision=deny") &&
			 index($0, "reason=kernel-interface") &&
			 index($0, _profile) &&
			 (_file_name == "file_name=" || index($0, _file_name)) { found = 1 }
			 END { exit !found }' <<<"$_log"; then
      return 0
    fi
    sleep 0.5
  done

  echo "missing BPF LSM kernel-interface deny audit for profile=${_profile} file_name=${_file_name}" >&2
  tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null |
    grep -E 'BPF LSM gate audit event|operation=(file_open|inode_permission)|kernel-interface|file_name=' |
    tail -160 >&2 || true
  exit 1
}

__assert_kernel_interface_audits() {
  local _log_start="$1"
  local _profile="$2"
  local _probe_output="$3"
  local _file_name

  for _file_name in lsm securityfs debugfs tracefs configfs; do
    if ! grep -q "kernel-interface-denied ${_file_name}" <<<"$_probe_output"; then
      continue
    fi
    case "$_file_name" in
    securityfs | debugfs | tracefs | configfs)
      __assert_bpf_kernel_interface_audit "$_log_start" "$_profile" ""
      ;;
    *)
      __assert_bpf_kernel_interface_audit "$_log_start" "$_profile" "$_file_name"
      ;;
    esac
  done
}

__assert_bpf_task_audit() {
  local _log_start="$1"
  local _operation="$2"
  local _reason="$3"
  local _deadline _log

  _deadline=$((SECONDS + 15))
  while ((SECONDS <= _deadline)); do
    _log="$(tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null || true)"
    if awk \
      -v _operation="operation=${_operation}" \
      -v _reason="reason=${_reason}" \
      'index($0, "BPF LSM gate audit event") &&
			 index($0, _operation) &&
			 index($0, "decision=deny") &&
			 index($0, _reason) { found = 1 }
			 END { exit !found }' <<<"$_log"; then
      return 0
    fi
    sleep 0.5
  done

  echo "missing BPF LSM task deny audit for operation=${_operation} reason=${_reason}" >&2
  tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null |
    grep -E 'BPF LSM gate audit event|operation=(signal|ptrace)|target_' |
    tail -160 >&2 || true
  exit 1
}

__assert_no_bpf_task_audit() {
  local _log_start="$1"
  local _log

  sleep 0.5
  _log="$(tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null || true)"
  if awk \
    'index($0, "BPF LSM gate audit event") &&
		 (index($0, "operation=signal") || index($0, "operation=ptrace")) &&
		 (index($0, "container_hash=0000000000000000") || !index($0, "profile=")) { found = 1 }
		 END { exit !found }' <<<"$_log"; then
    echo "host task operation unexpectedly produced BPF LSM task audit" >&2
    awk \
      'index($0, "BPF LSM gate audit event") &&
			 (index($0, "operation=signal") || index($0, "operation=ptrace")) &&
			 (index($0, "container_hash=0000000000000000") || !index($0, "profile=")) { print }' <<<"$_log" >&2 || true
    exit 1
  fi
}

__container_cgroup_path() {
  local _name="$1"
  local _pid _rel

  _pid="$(docker inspect "$_name" --format '{{.State.Pid}}')"
  _rel="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/${_pid}/cgroup")"
  printf '/sys/fs/cgroup%s\n' "$_rel"
}

__run_task_op_from_cgroup() {
  local _source_cgroup="$1"
  local _target_pid="$2"
  local _operation="$3"

  python3 - "$_source_cgroup" "$_target_pid" "$_operation" <<'PY'
import ctypes
import errno
import os
import signal
import sys

source_cgroup = sys.argv[1]
target_pid = int(sys.argv[2])
operation = sys.argv[3]

with open(os.path.join(source_cgroup, "cgroup.procs"), "w", encoding="ascii") as f:
    f.write(str(os.getpid()))

if operation == "signal":
    try:
        os.kill(target_pid, signal.SIGCONT)
    except PermissionError:
        sys.exit(1)
    sys.exit(0)

if operation != "ptrace":
    raise RuntimeError(f"unknown task operation: {operation}")

libc = ctypes.CDLL(None, use_errno=True)
PTRACE_ATTACH = 16
PTRACE_DETACH = 17
rc = libc.ptrace(PTRACE_ATTACH, target_pid, 0, 0)
if rc == 0:
    libc.ptrace(PTRACE_DETACH, target_pid, 0, 0)
    sys.exit(0)
err = ctypes.get_errno()
if err == errno.EPERM:
    sys.exit(1)
raise OSError(err, os.strerror(err))
PY
}

__spawn_task_target_in_cgroup() {
  local _target_cgroup="$1"
  local _warm_task_storage="${2:-false}"

  python3 - "$_target_cgroup" "$_warm_task_storage" <<'PY' >/dev/null 2>&1 &
import os
import sys
import time

target_cgroup = sys.argv[1]
warm_task_storage = sys.argv[2] == "true"
with open(os.path.join(target_cgroup, "cgroup.procs"), "w", encoding="ascii") as f:
    f.write(str(os.getpid()))
if warm_task_storage:
    try:
        os.getxattr("/tmp", b"security.capability")
    except OSError:
        pass
time.sleep(3600)
PY
  printf '%s\n' "$!"
}

__expect_task_op_denied() {
  local _source_cgroup="$1"
  local _target_pid="$2"
  local _operation="$3"
  local _status

  set +e
  __run_task_op_from_cgroup "$_source_cgroup" "$_target_pid" "$_operation"
  _status="$?"
  set -e
  if [[ "$_status" -eq 0 ]]; then
    echo "NSCell task operation ${_operation} unexpectedly succeeded" >&2
    exit 1
  fi
  if [[ "$_status" -ne 1 ]]; then
    echo "NSCell task operation ${_operation} failed with status ${_status}, want EPERM status 1" >&2
    exit 1
  fi
}

__assert_bpf_xattr_audit() {
  local _log_start="$1"
  local _profile="$2"
  local _operation="$3"
  local _decision="$4"
  local _xattr_name="$5"
  local _deadline _log

  _deadline=$((SECONDS + 15))
  while ((SECONDS <= _deadline)); do
    _log="$(tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null || true)"
    if awk \
      -v _profile="profile=${_profile}" \
      -v _operation="operation=${_operation}" \
      -v _decision="decision=${_decision}" \
      -v _xattr_name="name=${_xattr_name}" \
      'index($0, "BPF LSM gate audit event") &&
			 index($0, _operation) &&
			 index($0, _decision) &&
			 index($0, _profile) &&
			 index($0, _xattr_name) { found = 1 }
			 END { exit !found }' <<<"$_log"; then
      return 0
    fi
    sleep 0.5
  done

  echo "missing BPF LSM xattr audit for profile=${_profile} operation=${_operation} decision=${_decision} name=${_xattr_name}" >&2
  tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null |
    grep -E 'BPF LSM gate audit event|operation=.*xattr|name=' |
    tail -160 >&2 || true
  exit 1
}

__assert_xattr_negative_audits() {
  local _log_start="$1"
  local _profile="$2"

  __assert_bpf_xattr_audit "$_log_start" "$_profile" setxattr deny user.nscell_ci_denied
  __assert_bpf_xattr_audit "$_log_start" "$_profile" getxattr deny user.nscell_ci_denied
  __assert_bpf_xattr_audit "$_log_start" "$_profile" removexattr deny user.nscell_ci_denied
}

__assert_xattr_trusted_overlay_audits() {
  local _log_start="$1"
  local _profile="$2"

  __assert_bpf_xattr_audit "$_log_start" "$_profile" setxattr allow trusted.overlay.origin
  __assert_bpf_xattr_audit "$_log_start" "$_profile" getxattr allow trusted.overlay.origin
}

__assert_no_bpf_host_audit() {
  local _log_start="$1"
  local _marker="$2"
  local _log

  sleep 0.5
  _log="$(tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null || true)"
  if awk \
    -v _marker="name=${_marker}" \
    'index($0, "BPF LSM gate audit event") && index($0, _marker) { found = 1 }
		 END { exit !found }' <<<"$_log"; then
    echo "host xattr operation unexpectedly produced BPF LSM gate audit for ${_marker}" >&2
    grep -F "name=${_marker}" <<<"$_log" >&2 || true
    exit 1
  fi
}

__assert_no_bpf_kernel_interface_host_audit() {
  local _log_start="$1"
  local _log

  sleep 0.5
  _log="$(tail -n +"$((_log_start + 1))" "$_daemon_log" 2>/dev/null || true)"
  if awk \
    'index($0, "BPF LSM gate audit event") &&
		 (index($0, "operation=file_open") || index($0, "operation=inode_permission")) &&
		 index($0, "reason=kernel-interface") { found = 1 }
		 END { exit !found }' <<<"$_log"; then
    echo "host kernel-interface access unexpectedly produced BPF LSM gate audit" >&2
    grep -E 'BPF LSM gate audit event|operation=(file_open|inode_permission)|kernel-interface' <<<"$_log" >&2 || true
    exit 1
  fi
}

__check_host_bpf_gate_exemption() {
  local _log_start

  __log "checking non-NSCell host process BPF gate exemption"
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  python3 - <<'PY'
import os
import shutil

base = f"/tmp/nscell-ci-host-gate-exemption-{os.getpid()}"
path = os.path.join(base, "target")
name = b"user.nscell_ci_host_exempt"
value = b"host"

try:
    os.makedirs(base, exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"data")
    os.setxattr(path, name, value)
    got = os.getxattr(path, name)
    if got != value:
        raise RuntimeError(f"host xattr value {got!r}, want {value!r}")
    os.removexattr(path, name)
finally:
    shutil.rmtree(base, ignore_errors=True)

print("host-bpf-gate-exemption-ok")
PY
  __assert_no_bpf_host_audit "$_log_start" user.nscell_ci_host_exempt
}

__check_host_kernel_interface_gate_exemption() {
  local _log_start

  __log "checking non-NSCell host kernel-interface gate exemption"
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  python3 - <<'PY'
import os

for path in (
    "/sys/kernel/security/lsm",
    "/sys/kernel/debug",
    "/sys/kernel/tracing",
    "/sys/kernel/config",
):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    except OSError:
        continue
    else:
        os.close(fd)

print("host-kernel-interface-gate-exemption-ok")
PY
  __assert_no_bpf_kernel_interface_host_audit "$_log_start"
}

__check_host_task_gate_exemption() {
  local _log_start _host_pid

  __log "checking non-NSCell host task gate exemption"
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  sleep 3600 &
  _host_pid="$!"
  __cleanup() {
    kill "$_host_pid" 2>/dev/null || true
    wait "$_host_pid" 2>/dev/null || true
  }
  kill -0 "$_host_pid"
  __assert_no_bpf_task_audit "$_log_start"
  __cleanup
}

__check_host_target_task_gate() {
  local _name="${_container_security_policy_name}-host-target"
  local _source_cgroup _log_start _host_pid

  __log "checking NSCell container task gate against host target"
  docker rm -f "$_name" >/dev/null 2>&1 || true
  docker run -d \
    --name "$_name" \
    --hostname "$_name" \
    --runtime nscell \
    --cgroupns=private \
    --cap-add SYS_PTRACE \
    --cap-add KILL \
    --annotation "io.backend.security.profile=default" \
    --label "io.backend.security.profile=default" \
    "$_container_security_policy_image" >/dev/null
  _source_cgroup="$(__container_cgroup_path "$_name")"
  sleep 3600 &
  _host_pid="$!"
  __cleanup() {
    kill "$_host_pid" 2>/dev/null || true
    wait "$_host_pid" 2>/dev/null || true
    docker rm -f "$_name" >/dev/null 2>&1 || true
  }

  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  __expect_task_op_denied "$_source_cgroup" "$_host_pid" signal
  __assert_bpf_task_audit "$_log_start" signal host-target
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  __expect_task_op_denied "$_source_cgroup" "$_host_pid" ptrace
  __assert_bpf_task_audit "$_log_start" ptrace host-target
  __cleanup
}

__check_cross_container_task_gate() {
  local _name_a="${_container_security_policy_name}-task-a"
  local _name_b="${_container_security_policy_name}-task-b"
  local _source_cgroup _target_cgroup _log_start _target_pid

  __log "checking NSCell cross-container task gate"
  docker rm -f "$_name_a" "$_name_b" >/dev/null 2>&1 || true
  __cleanup() {
    if [[ -n "${_target_pid:-}" ]]; then
      kill "$_target_pid" 2>/dev/null || true
      wait "$_target_pid" 2>/dev/null || true
    fi
    docker rm -f "$_name_a" "$_name_b" >/dev/null 2>&1 || true
  }
  for _name in "$_name_a" "$_name_b"; do
    docker run -d \
      --name "$_name" \
      --hostname "$_name" \
      --runtime nscell \
      --cgroupns=private \
      --cap-add SYS_PTRACE \
      --cap-add KILL \
      --annotation "io.backend.security.profile=default" \
      --label "io.backend.security.profile=default" \
      "$_container_security_policy_image" >/dev/null
  done
  _source_cgroup="$(__container_cgroup_path "$_name_a")"
  _target_cgroup="$(__container_cgroup_path "$_name_b")"
  _target_pid="$(__spawn_task_target_in_cgroup "$_target_cgroup" true)"

  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  __expect_task_op_denied "$_source_cgroup" "$_target_pid" signal
  __assert_bpf_task_audit "$_log_start" signal cross-container
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  __expect_task_op_denied "$_source_cgroup" "$_target_pid" ptrace
  __assert_bpf_task_audit "$_log_start" ptrace cross-container
  __cleanup
}

__check_proc_sys() {
  local _name="$1"
  local _profile="$2"
  local _host_global_deny_sysctls _real_namespaced_sysctls

  __log "checking proc sys security policy for ${_name} (${_profile})"
  _host_global_deny_sysctls="$(nscell daemon policy sysctl-list --profile "$_profile" --kind host-global-deny | tr '\n' ' ')"
  _real_namespaced_sysctls="$(nscell daemon policy sysctl-list --profile "$_profile" --kind real-namespaced | tr '\n' ' ')"
  docker exec \
    -e "host_global_deny_sysctls=${_host_global_deny_sysctls}" \
    -e "real_namespaced_sysctls=${_real_namespaced_sysctls}" \
    "$_name" nscell-ci-container-security-policy-probe proc-sys-policy
}

__run_profile() {
  local _profile="$1"
  local _name="${_container_security_policy_name}-${_profile}"
  local _log_start _probe_output

  docker rm -f "$_name" >/dev/null 2>&1 || true
  docker run -d \
    --name "$_name" \
    --hostname "$_name" \
    --runtime nscell \
    --cgroupns=private \
    --cap-add SYS_ADMIN \
    --annotation "io.backend.security.profile=${_profile}" \
    --label "io.backend.security.profile=${_profile}" \
    "$_container_security_policy_image" >/dev/null

  __log "checking process identity and namespace isolation in ${_name}"
  __check_process_identity_isolation "$_name"
  __check_devices "$_name"
  __log "checking host control-plane isolation in ${_name}"
  __run_probe "$_name" control-plane-isolation
  __log "checking cgroup subtree delegation in ${_name}"
  __run_probe "$_name" cgroup-delegation
  __log "checking privileged resource negative policy in ${_name}"
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  __run_probe "$_name" privileged-resource-negative-policy
  __assert_unsafe_mount_audits "$_log_start" "$_profile"
  __log "checking kernel interface file policy in ${_name}"
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  _probe_output="$(__run_probe "$_name" kernel-interface-file-policy)"
  printf '%s\n' "$_probe_output"
  __assert_kernel_interface_audits "$_log_start" "$_profile" "$_probe_output"
  __log "checking cgroup subtree mount policy in ${_name}"
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  __run_probe "$_name" cgroup-subtree-mount-policy
  __assert_unsafe_mount_audits "$_log_start" "$_profile"
  __log "checking cgroup subtree kernel interface file policy in ${_name}"
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  _probe_output="$(__run_probe "$_name" cgroup-subtree-kernel-interface-file-policy)"
  printf '%s\n' "$_probe_output"
  __assert_kernel_interface_audits "$_log_start" "$_profile" "$_probe_output"
  __log "checking xattr negative policy in ${_name}"
  _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
  __run_probe "$_name" xattr-negative-policy
  __assert_xattr_negative_audits "$_log_start" "$_profile"
  if [[ "$_profile" == "dind" ]]; then
    __log "checking trusted overlay xattr policy in ${_name}"
    _log_start="$(wc -l <"$_daemon_log" 2>/dev/null || printf '0\n')"
    __run_probe "$_name" xattr-trusted-overlay-policy
    __assert_xattr_trusted_overlay_audits "$_log_start" "$_profile"
  fi
  __check_proc_sys "$_name" "$_profile"
}

__main() {
  if [[ "${1:-}" == "cleanup" ]]; then
    __require_cmd docker
    __remove_oci_container "$_oci_runtime_root" "$_identity_id"
    __remove_oci_bundle "$_identity_bundle"
    docker rm -f "$_identity_export_name" >/dev/null 2>&1 || true
    docker rm -f \
      "${_container_security_policy_name}-default" \
      "${_container_security_policy_name}-dind" \
      "${_container_security_policy_name}-k8s-node" \
      "${_container_security_policy_name}-host-target" \
      "${_container_security_policy_name}-task-a" \
      "${_container_security_policy_name}-task-b" >/dev/null 2>&1 || true
    return
  fi

  __require_cmd docker
  __require_cmd jq
  __assert_nscell_ready
  __init_ci_dirs
  __build_ci_image "$_container_security_policy_image" "$_workload_path" --build-arg "BASE_IMAGE=${_container_security_policy_base_image}"

  __require_bpf_lsm
  __check_host_root_mapping_rejected
  __check_host_bpf_gate_exemption
  __check_host_kernel_interface_gate_exemption
  __check_host_task_gate_exemption
  __run_profile k8s-node
  __run_profile default
  __run_profile dind
  __check_host_target_task_gate
  __check_cross_container_task_gate

  __assert_nscell_ready
  echo "container-security-policy-validation-ok"
}

__main "$@"
