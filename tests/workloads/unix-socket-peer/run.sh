#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
#
# AF_UNIX peer identity: two containers that share a writable directory can
# otherwise hand each other kernel objects with SCM_RIGHTS (a file descriptor
# for a file in a private rootfs, a pidfd, a device node), and an already
# delivered descriptor is invisible to the open-time seccomp and LSM checks.
# The gate denies a container task a socket owned by another NSCell container.
#
# Host-owned sockets keep the documented bind-admission behaviour: reachability
# is decided when the operator puts the path into the container, not here. The
# workload asserts both halves so a later change cannot silently pick one.
set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"

_shared_dir="${_unix_socket_peer_shared_dir}"
_host_server_pid=""

__cleanup() {
  docker rm -f \
    "${_unix_socket_peer_primary_name}" \
    "${_unix_socket_peer_secondary_name}" >/dev/null 2>&1 || true
  if [[ -n "$_host_server_pid" ]]; then
    kill "$_host_server_pid" >/dev/null 2>&1 || true
    wait "$_host_server_pid" 2>/dev/null || true
  fi
  rm -rf "$_shared_dir"
}

__write_peer_scripts() {
  install -d -m 0755 "$_shared_dir"
  chmod 0777 "$_shared_dir"
  cat >"${_shared_dir}/server.py" <<'PY'
import os
import socket
import sys

path = sys.argv[1]
if os.path.exists(path):
    os.unlink(path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
os.chmod(path, 0o777)
server.listen(16)
print("LISTENING", path, oct(os.stat(path).st_mode & 0o777), flush=True)

while True:
    conn, _ = server.accept()
    data = conn.recv(64)
    print("SERVED", data.decode(errors="replace"), flush=True)
    conn.sendall(b"pong")
    conn.close()
PY
  cat >"${_shared_dir}/client.py" <<'PY'
import errno
import socket
import sys
import time

label = sys.argv[1]
path = sys.argv[2]
deadline = time.time() + 30

while True:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        client.connect(path)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ECONNREFUSED) and time.time() < deadline:
            time.sleep(0.2)
            continue
        print("%s CONNECT_FAIL errno=%d(%s)" % (label, exc.errno, errno.errorcode.get(exc.errno, "?")), flush=True)
        sys.exit(3)
    print("%s CONNECT_OK" % label, flush=True)
    client.sendall(label.encode())
    print("%s REPLY %s" % (label, client.recv(64).decode()), flush=True)
    client.close()
    sys.exit(0)
PY
}

__start_containers() {
  docker run -d \
    --name "${_unix_socket_peer_primary_name}" \
    --runtime nscell \
    -v "${_shared_dir}:/shared" \
    "$_unix_socket_peer_base_image" \
    python3 /shared/server.py /shared/primary.sock >/dev/null
  docker run -d \
    --name "${_unix_socket_peer_secondary_name}" \
    --runtime nscell \
    -v "${_shared_dir}:/shared" \
    "$_unix_socket_peer_base_image" \
    sleep 600 >/dev/null
}

__expect_connect_ok() {
  local _label="$1"
  local _runner="$2"
  local _socket_path="$3"
  local _output

  if [[ "$_runner" == host ]]; then
    _output="$(timeout 60 python3 "${_shared_dir}/client.py" "$_label" "$_socket_path")"
  else
    _output="$(timeout 60 docker exec "$_runner" python3 /shared/client.py "$_label" "$_socket_path")"
  fi
  printf '%s\n' "$_output"
  if [[ "$_output" != *"${_label} CONNECT_OK"* || "$_output" != *"${_label} REPLY pong"* ]]; then
    echo "${_label} should have connected: ${_output}" >&2
    return 1
  fi
}

__expect_cross_container_denied() {
  local _output

  _output="$(timeout 60 docker exec "${_unix_socket_peer_secondary_name}" \
    python3 /shared/client.py cross-container /shared/primary.sock || true)"
  printf '%s\n' "$_output"
  if [[ "$_output" != *"cross-container CONNECT_FAIL errno=1(EPERM)"* ]]; then
    echo "another NSCell container was not denied: ${_output}" >&2
    return 1
  fi
}

__assert_daemon_recorded_cross_container_deny() {
  local _deadline=$((SECONDS + 15))
  local _matches=""

  while ((SECONDS <= _deadline)); do
    _matches="$(sudo grep -F 'BPF LSM gate audit event' "$_daemon_log" |
      grep -F 'operation=unix_connect' |
      grep -F 'reason=cross-container' |
      grep -F 'decision=deny' || true)"
    if [[ -n "$_matches" ]]; then
      printf 'unix-socket-peer-audit=%s\n' "$(printf '%s\n' "$_matches" | tail -1)"
      return 0
    fi
    sleep 0.5
  done
  echo "daemon did not record the cross-container AF_UNIX deny" >&2
  sudo tail -100 "$_daemon_log" >&2
  return 1
}

__main() {
  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd python3
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT
  __cleanup
  __ensure_host_image "$_unix_socket_peer_base_image"
  __write_peer_scripts
  __start_containers

  __log "checking that a container still reaches its own socket"
  __expect_connect_ok same-container "${_unix_socket_peer_primary_name}" /shared/primary.sock

  __log "checking that another NSCell container is denied"
  __expect_cross_container_denied
  __assert_daemon_recorded_cross_container_deny

  __log "checking that a host process still reaches the container socket"
  __expect_connect_ok host peer-host "${_shared_dir}/primary.sock"

  __log "checking that a container still reaches a host-owned socket"
  timeout 60 python3 "${_shared_dir}/server.py" "${_shared_dir}/host.sock" >"${_shared_dir}/host-server.log" 2>&1 &
  _host_server_pid=$!
  __expect_connect_ok container-to-host "${_unix_socket_peer_primary_name}" /shared/host.sock
  kill "$_host_server_pid" >/dev/null 2>&1 || true
  wait "$_host_server_pid" 2>/dev/null || true
  _host_server_pid=""
  cat "${_shared_dir}/host-server.log"

  __assert_nscell_ready
  trap - EXIT
  __cleanup
  echo "unix-socket-peer-validation-ok"
}

__main "$@"
