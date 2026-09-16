#!/usr/bin/env bash
# shellcheck disable=all

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/.." && pwd)"
_runtime_test_dir="${_repo_root}/tests"

_nscell_image="${NSCELL_IMAGE:-ghcr.io/lwmacct/260522-nscell:latest}"
_test_root="${NSCELL_CI_TEST_ROOT:-/tmp/nscell}"
_image_cache_dir="${NSCELL_CI_IMAGE_CACHE_DIR:-${_test_root}/images}"
_target_platform="${NSCELL_IMAGE_PLATFORM:-linux/amd64}"
_release_root="${NSCELL_RELEASE_ROOT:-/opt/nscell/releases}"
_current_link="${NSCELL_CURRENT_LINK:-/opt/nscell/current}"
_daemon_log="${NSCELL_DAEMON_LOG:-/var/log/nscell-daemon.log}"
_reset_daemon_state="${NSCELL_CI_RESET_DAEMON_STATE:-1}"
_run_id="${NSCELL_WORKLOAD_RUN_ID:-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
_resource_id="$(printf '%s' "$_run_id" | tr -c '[:alnum:]_.-' '-')"
_resource_id="${_resource_id:0:32}"

__log() {
  printf '\n==> %s\n' "$*" >&2
}

__require_cmd() {
  local _cmd="$1"
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "missing required command: $_cmd" >&2
    exit 1
  fi
}

__retry() {
  local _max_attempts="$1"
  shift
  local _attempt=1
  local _status

  while true; do
    if "$@"; then
      return 0
    else
      _status=$?
    fi
    if ((_attempt >= _max_attempts)); then
      return "$_status"
    fi
    __log "${1} failed with ${_status}; retrying ($((_attempt + 1))/${_max_attempts})"
    sleep $((_attempt * 5))
    _attempt=$((_attempt + 1))
  done
}

__install_dependencies() {
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    apparmor \
    jq \
    libseccomp2 \
    python3 \
    util-linux
}

__show_host_capabilities() {
  set -x
  uname -a
  cat /sys/kernel/security/lsm || true
  findmnt /sys/fs/bpf || true
  docker version
  docker info
  oras version
}

__setup_runtime_host() {
  __require_cmd sudo
  __require_cmd docker
  __require_cmd systemctl
  __require_cmd jq
  __require_cmd python3
  __require_cmd oras

  __init_ci_dirs
  __install_nscell_binary
  __install_nscell_systemd_units
  __configure_apparmor_fuse
  __configure_docker_runtime
  __restart_nscell_services
  echo "ci-setup-ok"
}

__configure_apparmor_fuse() {
  local _profile="/etc/apparmor.d/fusermount3"
  local _local_profile="/etc/apparmor.d/local/fusermount3"
  local _temporary_profile

  if ! sudo test -f "$_profile"; then
    return 0
  fi
  __require_cmd apparmor_parser

  sudo install -d -m 0755 /etc/apparmor.d/local
  _temporary_profile="$(mktemp)"
  cat >"$_temporary_profile" <<'EOF'
# NSCell owns per-container FUSE mounts below this private root.
mount fstype=@{fuse_types} options=(nosuid,nodev) options in (ro,rw,noatime,dirsync,nodiratime,noexec,sync) -> /var/lib/nscellfs/**/,
umount /var/lib/nscellfs/**/,
EOF
  sudo install -m 0644 "$_temporary_profile" "$_local_profile"
  rm -f "$_temporary_profile"
  sudo apparmor_parser -r "$_profile"
}

__init_ci_dirs() {
  sudo install -d -m 0755 "$_test_root" "$_image_cache_dir"
  sudo chown -R "$(id -u):$(id -g)" "$_test_root"
}

__image_repo() {
  local _ref="$1"
  local _repo _last

  _repo="${_ref%%@*}"
  _last="${_repo##*/}"
  if [[ "$_last" == *:* ]]; then
    _repo="${_repo%:*}"
  fi
  printf '%s' "$_repo"
}

__fetch_manifest() {
  local _manifest="$1"
  local _image="$2"

  rm -f "$_manifest"
  oras manifest fetch --platform "$_target_platform" --output "$_manifest" "$_image"
}

__fetch_blob() {
  local _layer="$1"
  local _ref="$2"

  rm -f "$_layer"
  oras blob fetch --no-tty --output "$_layer" "$_ref"
}

__extract_nscell_binary_from_image() {
  local _dest="$1"
  local _work_dir _manifest _repo _digest _layer _i

  _work_dir="$(mktemp -d "${_test_root}/oras-image.XXXXXX")"
  _manifest="${_work_dir}/manifest.json"
  _repo="$(__image_repo "$_nscell_image")"

  __log "fetching ${_target_platform} manifest from ${_nscell_image}"
  __retry 3 __fetch_manifest "$_manifest" "$_nscell_image"

  mkdir -p "${_work_dir}/rootfs" "${_work_dir}/layers"
  _i=0
  while IFS= read -r _digest; do
    [[ -n "$_digest" ]] || continue
    _i=$((_i + 1))
    _layer="${_work_dir}/layers/${_i}.tar"
    __log "fetching layer ${_i}: ${_digest}"
    __retry 3 __fetch_blob "$_layer" "${_repo}@${_digest}"
    tar -xf "$_layer" -C "${_work_dir}/rootfs"
  done < <(jq -r '.layers[].digest' "$_manifest")

  install -d -m 0755 "$_dest"
  install -m 0755 "${_work_dir}/rootfs/usr/local/bin/nscell" "${_dest}/nscell"
  rm -rf "$_work_dir"
}

__install_nscell_binary() {
  local _release _artifact_bin_dir _next_link
  _release="${_release_root}/$(date +%Y%m%d%H%M%S)-ci"
  _artifact_bin_dir="${_test_root}/nscell-bin"

  __log "removing previous validation containers before installing nscell"
  docker ps -a --format '{{.Names}}' |
    awk '/^nscell-(docker-in-docker|kubernetes-k3s|systemd-pid1|procfs-memory|procfs-cpu|seccomp-notify-concurrency|container-security-policy)/ { print }' |
    xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network ls --format '{{.Name}}' |
    awk '/^nscell-docker-in-docker/ { print }' |
    xargs -r docker network rm >/dev/null 2>&1 || true

  rm -rf "$_artifact_bin_dir"
  __extract_nscell_binary_from_image "$_artifact_bin_dir"
  "${_artifact_bin_dir}/nscell" version

  __log "installing nscell to ${_release}"
  sudo install -d -m 0755 "${_release}/bin"
  sudo install -m 0755 "${_artifact_bin_dir}/nscell" "${_release}/bin/nscell"
  _next_link="${_current_link}.next"
  sudo rm -f "$_next_link"
  sudo ln -s "$_release" "$_next_link"
  sudo mv -Tf "$_next_link" "$_current_link"
  sudo ln -sfn "${_current_link}/bin/nscell" /usr/bin/nscell
}

__install_nscell_systemd_units() {
  __log "installing nscell-daemon systemd unit"
  sudo tee /etc/systemd/system/nscell-daemon.service >/dev/null <<EOF
[Unit]
Description=nscell-daemon (NSCell control and data plane)
Before=docker.service containerd.service

[Service]
Type=notify
ExecStart=/usr/bin/nscell daemon --log ${_daemon_log} --metrics-listen 127.0.0.1:9618
TimeoutStartSec=45
TimeoutStopSec=90
StartLimitInterval=0
NotifyAccess=main
OOMScoreAdjust=-500
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
  WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable nscell-daemon.service >/dev/null
}

__configure_docker_runtime() {
  local _daemon_config="/etc/docker/daemon.json"
  local _tmp_config

  __log "configuring docker nscell"
  sudo install -d -m 0755 /etc/docker
  _tmp_config="$(mktemp)"
  if sudo test -s "$_daemon_config"; then
    sudo jq '
			if type != "object" then
				error("docker daemon config must be a JSON object")
			else
				.runtimes = ((.runtimes // {})
					| .["nscell"] = {
						"path": "/usr/bin/nscell",
						"runtimeArgs": []
					})
			end
		' "$_daemon_config" >"$_tmp_config"
  else
    jq -n '{
			"runtimes": {
				"nscell": {
					"path": "/usr/bin/nscell",
					"runtimeArgs": []
				}
			}
		}' >"$_tmp_config"
  fi
  sudo install -m 0644 "$_tmp_config" "$_daemon_config"
  rm -f "$_tmp_config"
}

__restart_nscell_services() {
  __log "restarting nscell-daemon and docker"
  docker ps -a --format '{{.Names}}' |
    awk '/^nscell-(docker-in-docker|kubernetes-k3s|systemd-pid1|procfs-memory|procfs-cpu|seccomp-notify-concurrency|container-security-policy)/ { print }' |
    xargs -r docker rm -f >/dev/null 2>&1 || true
  sudo truncate -s 0 "$_daemon_log" 2>/dev/null || sudo install -m 0600 /dev/null "$_daemon_log"
  sudo systemctl reset-failed docker.service nscell-daemon.service || true
  sudo systemctl stop nscell-daemon.service || true
  while read -r _mp; do
    [[ -n "$_mp" ]] || continue
    sudo umount -l "$_mp" || true
  done < <(awk '$0 ~ / - fuse nscellfs / && $5 ~ /^\/var\/lib\/nscellfs\// {print $5}' /proc/self/mountinfo)
  sudo rm -f /run/nscell/daemon.sock /run/nscell/daemon.pid
  sudo rm -rf /run/nscell/containers
  case "$_reset_daemon_state" in
  0 | 1) ;;
  *)
    echo "unsupported NSCELL_CI_RESET_DAEMON_STATE: $_reset_daemon_state" >&2
    exit 2
    ;;
  esac
  if ((_reset_daemon_state)); then
    __log "resetting daemon state and managed-volume roots"
    sudo rm -rf /var/lib/nscell/state /var/lib/nscell/work /run/nscell/runtime
  fi
  if sudo test -d /var/lib/nscellfs; then
    sudo find /var/lib/nscellfs -mindepth 1 -maxdepth 1 -xdev -exec rm -rf -- {} + 2>/dev/null || true
  fi
  sudo systemctl restart nscell-daemon.service
  sudo systemctl is-active --quiet nscell-daemon.service
  sudo systemctl restart docker
  __assert_nscell_ready
}

__verify_gate() {
  sudo systemctl is-active --quiet nscell-daemon.service
  sudo systemctl cat nscell-daemon.service
  sudo nscell daemon gate status
  sudo nscell daemon gate status |
    jq -e '(.mode == "strict") and (.enabled == true) and (.enforce == true)'
}

__assert_nscell_ready() {
	__log "checking nscell services"
	sudo systemctl is-active --quiet nscell-daemon.service
	sudo grep -q "Ready ..." "$_daemon_log"
	! sudo grep -q "ID-mapped mounts are required" "$_daemon_log"
	! sudo grep -q "overlayfs on ID-mapped mounts is required" "$_daemon_log"
	__wait_for_docker_runtime
}

__wait_for_docker_runtime() {
	local _attempt

	for _attempt in $(seq 1 30); do
		if docker info --format '{{json .Runtimes}}' 2>/dev/null |
			jq -e 'has("nscell")' >/dev/null; then
			return 0
		fi
		sleep 2
	done

	docker info --format '{{json .Runtimes}}' | jq -e 'has("nscell")' >/dev/null
}

__run_workload() {
  __require_cmd docker
  __require_cmd jq
  __require_cmd flock
  local _workload="$1"

  if [[ -z "$_workload" || "$_workload" == "all" ]]; then
    echo "run-workload requires one concrete workload name" >&2
    exit 2
  fi

	export NSCELL_CI_TEST_ROOT="$_test_root"
  export NSCELL_CI_IMAGE_CACHE_DIR="$_image_cache_dir"
  export NSCELL_CI_LOG_ROOT="${_test_root}/runs/${_resource_id}/logs"
  export NSCELL_WORKLOAD_RUN_ID="$_resource_id"

  bash "${_runtime_test_dir}/run.sh" run "$_workload"
}

__collect_logs() {
  local _log_dir="${_test_root}/runs/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}/logs"
  sudo install -d -m 0755 "$_log_dir"
  {
    uname -a || true
    cat /sys/kernel/security/lsm || true
    findmnt /sys/fs/bpf || true
    docker info || true
    docker ps -a || true
    docker images || true
    for _container in $(docker ps -a --format '{{.Names}}' | awk '/^nscell-/ { print }'); do
      docker logs "$_container" || true
    done
    sudo systemctl --no-pager --full status docker.service nscell-daemon.service || true
    sudo systemctl cat nscell-daemon.service || true
    sudo nscell daemon gate status || true
    sudo journalctl --no-pager -u docker.service -u nscell-daemon.service || true
  } 2>&1 | sudo tee "${_log_dir}/host-diagnostics.log" >/dev/null
  if sudo test -f "$_daemon_log"; then
    sudo cp "$_daemon_log" "${_log_dir}/nscell-daemon.log"
    sudo chmod 0644 "${_log_dir}/nscell-daemon.log"
  fi
}

__usage() {
  cat <<'EOF'
usage: scripts/ci.sh <command>

commands:
  install-dependencies
  show-host-capabilities
  setup-runtime-host
  verify-gate
  run-workload <workload>
  collect-logs
EOF
}

__main() {
  local _command="${1:-}"
  shift || true

  case "$_command" in
  install-dependencies)
    __install_dependencies
    ;;
  show-host-capabilities)
    __show_host_capabilities
    ;;
  setup-runtime-host)
    __setup_runtime_host
    ;;
  verify-gate)
    __verify_gate
    ;;
  run-workload)
    __run_workload "${1:-}"
    ;;
  collect-logs)
    __collect_logs
    ;;
  -h | --help | help)
    __usage
    ;;
  *)
    __usage >&2
    exit 2
    ;;
  esac
}

__main "$@"
