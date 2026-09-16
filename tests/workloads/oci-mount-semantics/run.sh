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

_root="${_volume_root}/oci-mount-semantics"
_bundle="${_root}/bundle"
_export_name="nscell-oci-mount-export-${_workload_resource_id:-oci-mount-semantics}"

__cleanup() {
  __remove_oci_container "$_oci_runtime_root" "$_oci_mount_semantics_id"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__prepare_rootfs() {
  local _rootfs="${_bundle}/rootfs"

  sudo install -d -m 0755 \
    "${_root}/bind-base" \
    "${_root}/bind-external" \
    "${_root}/bind-under" \
    "${_root}/bind-base/shm/under" \
    "${_root}/bind-base/external" \
    "${_root}/overlay-lower" \
    "${_root}/overlay-upper" \
    "${_root}/overlay-work/work" \
    "${_rootfs}/copyup" \
    "${_rootfs}/readonly-copyup" \
    "${_rootfs}/run" \
    "${_rootfs}/mnt" \
    "${_rootfs}/shm-target"
  printf '%s\n' seed | sudo tee "${_rootfs}/copyup/seed" >/dev/null
  printf '%s\n' readonly-seed | sudo tee "${_rootfs}/readonly-copyup/seed" >/dev/null
  printf '%s\n' lower-file | sudo tee "${_root}/overlay-lower/lower-file" >/dev/null
  printf '%s\n' bind-base | sudo tee "${_root}/bind-base/bind-base-file" >/dev/null
  printf '%s\n' bind-external | sudo tee "${_root}/bind-external/bind-external-file" >/dev/null
  printf '%s\n' bind-under | sudo tee "${_root}/bind-under/bind-under-file" >/dev/null
  sudo ln -sfn /run "${_rootfs}/var/run"
  sudo ln -sfn /mnt/shm-target "${_rootfs}/run/shm"
}

__configure_mounts() {
  local _config_tmp

  _config_tmp="$(mktemp)"
  # shellcheck disable=SC2024 # The temporary output file is owned by the caller.
  sudo jq \
    --arg _lowerdir "${_root}/overlay-lower" \
    --arg _upperdir "${_root}/overlay-upper" \
    --arg _workdir "${_root}/overlay-work/work" \
    --arg _bind_base "${_root}/bind-base" \
    --arg _bind_external "${_root}/bind-external" \
    --arg _bind_under "${_root}/bind-under" \
    '.mounts |= map(
      if .destination == "/dev" then
        .options = (((.options // []) | map(select(. != "ro" and . != "rw"))) + ["ro"])
      else
        .
      end
    ) |
    .mounts += [
      {
        destination: "/copyup",
        type: "tmpfs",
        source: "tmpfs",
        options: ["nosuid", "nodev", "mode=1777", "size=65536k", "tmpcopyup"]
      },
      {
        destination: "/readonly-copyup",
        type: "tmpfs",
        source: "tmpfs",
        options: ["nosuid", "nodev", "mode=1777", "size=65536k", "tmpcopyup", "ro"]
      },
      {
        destination: "/readonly-overlay",
        type: "overlay",
        source: "overlay",
        options: [
          "lowerdir=" + $_lowerdir,
          "upperdir=" + $_upperdir,
          "workdir=" + $_workdir,
          "ro",
          "nosuid",
          "nodev",
          "noexec"
        ]
      },
      {
        destination: "/run",
        type: "bind",
        source: $_bind_base,
        options: ["rw", "bind"]
      },
      {
        destination: "/var/run/external",
        type: "bind",
        source: $_bind_external,
        options: ["rw", "bind"]
      },
      {
        destination: "/run/shm/under",
        type: "bind",
        source: $_bind_under,
        options: ["rw", "bind"]
      }
    ]' \
    "${_bundle}/config.json" >"$_config_tmp"
  sudo install -m 0600 "$_config_tmp" "${_bundle}/config.json"
  rm -f "$_config_tmp"
}

__install_probe() {
  sudo tee "${_bundle}/rootfs/probe.sh" >/dev/null <<'EOF'
#!/bin/sh
set -eu

__assert_mount() {
  _mountpoint="$1"
  _filesystem="$2"
  awk -v _target="$_mountpoint" -v _fstype="$_filesystem" '
    $5 == _target {
      for (_field = 7; _field < NF; _field++) {
        if ($_field == "-") {
          if ($(_field + 1) == _fstype) {
            _found = 1
          }
          break
        }
      }
    }
    END { exit !_found }
  ' /proc/self/mountinfo
}

__assert_mountpoint() {
  _mountpoint="$1"
  awk -v _target="$_mountpoint" \
    '$5 == _target { _found = 1 } END { exit !_found }' \
    /proc/self/mountinfo
}

__assert_readonly() {
  _mountpoint="$1"
  awk -v _target="$_mountpoint" '
    $5 == _target && $6 ~ /(^|,)ro(,|$)/ { _found = 1 }
    END { exit !_found }
  ' /proc/self/mountinfo
}

__assert_mount /proc proc
__assert_mount /sys sysfs
__assert_mountpoint /sys/fs/cgroup
test -r /sys/fs/cgroup/cgroup.controllers
__assert_mount /dev tmpfs
__assert_readonly /dev
__assert_mount /dev/mqueue mqueue
__assert_mount /copyup tmpfs
__assert_mount /readonly-copyup tmpfs
__assert_readonly /readonly-copyup
__assert_mount /readonly-overlay overlay
__assert_readonly /readonly-overlay

[ "$(cat /copyup/seed)" = seed ]
printf runtime > /copyup/runtime
[ "$(cat /readonly-copyup/seed)" = readonly-seed ]
if echo rejected > /readonly-copyup/rejected 2>/dev/null; then
  echo "readonly tmpcopyup accepted a write" >&2
  exit 1
fi
[ ! -e /readonly-copyup/rejected ]
[ "$(cat /readonly-overlay/lower-file)" = lower-file ]
if echo rejected > /readonly-overlay/rejected 2>/dev/null; then
  echo "readonly overlay accepted a write" >&2
  exit 1
fi
[ ! -e /readonly-overlay/rejected ]

[ "$(cat /run/bind-base-file)" = bind-base ]
[ "$(cat /var/run/external/bind-external-file)" = bind-external ]
[ "$(cat /run/shm/under/bind-under-file)" = bind-under ]
[ ! -e /shm-target/under ]
echo oci-mount-semantics-probe-ok
EOF
  sudo chmod 0755 "${_bundle}/rootfs/probe.sh"
}

__wait_for_stopped() {
  local _deadline=$((SECONDS + 20))
  local _actual=""

  while ((SECONDS <= _deadline)); do
    _actual="$(sudo nscell --root "$_oci_runtime_root" state \
      "$_oci_mount_semantics_id" 2>/dev/null |
      jq -r '.status // empty' || true)"
    if [[ "$_actual" == "stopped" ]]; then
      return 0
    fi
    sleep 0.2
  done

  echo "OCI mount container did not stop; last state: ${_actual:-unavailable}" >&2
  return 1
}

__main() {
  local _probe_log _probe_rc

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd jq
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT

  __cleanup
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' \
    "$_export_name"
  __prepare_rootfs
  __configure_mounts
  __install_probe

  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_oci_mount_semantics_id"
  sudo nscell --root "$_oci_runtime_root" start "$_oci_mount_semantics_id"
  _probe_log="${_log_root}/oci-mount-probe.log"
  set +e
  sudo nscell --root "$_oci_runtime_root" exec \
    "$_oci_mount_semantics_id" \
    /bin/sh -x /probe.sh | tee "$_probe_log"
  _probe_rc="${PIPESTATUS[0]}"
  set -e
  if [[ "$_probe_rc" -ne 0 ]] ||
    ! grep -qx 'oci-mount-semantics-probe-ok' "$_probe_log"; then
    echo "unexpected OCI mount probe output" >&2
    exit 1
  fi
  if sudo test -e "${_bundle}/rootfs/copyup/runtime"; then
    echo "tmpcopyup write leaked into the original rootfs directory" >&2
    exit 1
  fi
  if sudo test -e "${_bundle}/rootfs/readonly-copyup/rejected"; then
    echo "readonly tmpcopyup write leaked into the original rootfs directory" >&2
    exit 1
  fi

  sudo nscell --root "$_oci_runtime_root" kill "$_oci_mount_semantics_id" TERM
  __wait_for_stopped
  sudo nscell --root "$_oci_runtime_root" delete "$_oci_mount_semantics_id"
  __assert_nscell_ready

  trap - EXIT
  __cleanup
  echo "oci-mount-semantics-validation-ok"
}

__main "$@"
