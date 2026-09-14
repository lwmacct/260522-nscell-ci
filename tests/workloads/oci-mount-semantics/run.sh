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
    "${_rootfs}/copyup" \
    "${_rootfs}/lower" \
    "${_rootfs}/mnt" \
    "${_rootfs}/mnt/run" \
    "${_rootfs}/shm-target"
  printf '%s\n' seed | sudo tee "${_rootfs}/copyup/seed" >/dev/null
  printf '%s\n' lower-file | sudo tee "${_rootfs}/lower/lower-file" >/dev/null
  printf '%s\n' bind-base | sudo tee "${_root}/bind-base/bind-base-file" >/dev/null
  printf '%s\n' bind-external | sudo tee "${_root}/bind-external/bind-external-file" >/dev/null
  printf '%s\n' bind-under | sudo tee "${_root}/bind-under/bind-under-file" >/dev/null
  sudo ln -sfn /mnt/run "${_rootfs}/mnt/alias"
  sudo ln -sfn /mnt/shm-target "${_rootfs}/mnt/run/shm"
}

__configure_mounts() {
  local _config_tmp

  _config_tmp="$(mktemp)"
  # shellcheck disable=SC2024 # The temporary output file is owned by the caller.
  sudo jq \
    --arg _lowerdir "${_bundle}/rootfs/lower" \
    --arg _bind_base "${_root}/bind-base" \
    --arg _bind_external "${_root}/bind-external" \
    --arg _bind_under "${_root}/bind-under" \
    '.mounts += [
      {
        destination: "/copyup",
        type: "tmpfs",
        source: "tmpfs",
        options: ["nosuid", "nodev", "mode=1777", "size=65536k", "tmpcopyup"]
      },
      {
        destination: "/readonly-overlay",
        type: "overlay",
        source: "overlay",
        options: ["lowerdir=" + $_lowerdir, "ro", "nosuid", "nodev", "noexec"]
      },
      {
        destination: "/mnt/run",
        type: "bind",
        source: $_bind_base,
        options: ["rw", "bind"]
      },
      {
        destination: "/mnt/alias/external",
        type: "bind",
        source: $_bind_external,
        options: ["rw", "bind"]
      },
      {
        destination: "/mnt/run/shm/under",
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

assert_mount() {
  mountpoint="$1"
  filesystem="$2"
  awk -v target="$mountpoint" -v fstype="$filesystem" '
    $5 == target && $9 == fstype { found = 1 }
    END { exit !found }
  ' /proc/self/mountinfo
}

assert_readonly() {
  mountpoint="$1"
  awk -v target="$mountpoint" '
    $5 == target && $6 ~ /(^|,)ro(,|$)/ { found = 1 }
    END { exit !found }
  ' /proc/self/mountinfo
}

assert_mount /proc proc
assert_mount /sys sysfs
assert_mount /sys/fs/cgroup cgroup2
assert_mount /dev tmpfs
assert_mount /dev/mqueue mqueue
assert_mount /copyup tmpfs
assert_mount /readonly-overlay overlay
assert_readonly /readonly-overlay
assert_readonly /sys

[ "$(cat /copyup/seed)" = seed ]
printf runtime > /copyup/runtime
[ "$(cat /readonly-overlay/lower-file)" = lower-file ]
if echo rejected > /readonly-overlay/rejected 2>/dev/null; then
  echo "readonly overlay accepted a write" >&2
  exit 1
fi
[ ! -e /readonly-overlay/rejected ]

[ "$(cat /mnt/run/bind-base-file)" = bind-base ]
[ "$(cat /mnt/alias/external/bind-external-file)" = bind-external ]
[ "$(cat /mnt/run/shm/under/bind-under-file)" = bind-under ]
[ ! -e /shm-target/under ]
echo oci-mount-semantics-probe-ok
EOF
  sudo chmod 0755 "${_bundle}/rootfs/probe.sh"
}

__main() {
  local _probe_output

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
  _probe_output="$(sudo nscell --root "$_oci_runtime_root" exec \
    "$_oci_mount_semantics_id" /probe.sh)"
  printf '%s\n' "$_probe_output"
  if [[ "$_probe_output" != "oci-mount-semantics-probe-ok" ]]; then
    echo "unexpected OCI mount probe output" >&2
    exit 1
  fi
  if sudo test -e "${_bundle}/rootfs/copyup/runtime"; then
    echo "tmpcopyup write leaked into the original rootfs directory" >&2
    exit 1
  fi

  sudo nscell --root "$_oci_runtime_root" kill "$_oci_mount_semantics_id" TERM
  sudo nscell --root "$_oci_runtime_root" delete "$_oci_mount_semantics_id"
  __assert_nscell_ready

  trap - EXIT
  __cleanup
  echo "oci-mount-semantics-validation-ok"
}

__main "$@"
