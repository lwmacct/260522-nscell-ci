#!/usr/bin/env bash

__prepare_oci_bundle() {
  local _image="$1"
  local _bundle="$2"
  local _process_args_json="$3"
  local _export_name="$4"
  local _container _config_tmp

  __ensure_host_image "$_image"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  sudo rm -rf "$_bundle"
  install -d -m 0755 "$_bundle"
  sudo install -d -m 0755 "${_bundle}/rootfs"

  _container="$(docker create --name "$_export_name" "$_image")"
  if ! docker export "$_container" | sudo tar --numeric-owner -xpf - -C "${_bundle}/rootfs"; then
    docker rm -f "$_container" >/dev/null 2>&1 || true
    return 1
  fi
  docker rm "$_container" >/dev/null
  sudo chown -R 0:0 "${_bundle}/rootfs"

  sudo nscell spec --bundle "$_bundle"
  _config_tmp="$(mktemp)"
  # shellcheck disable=SC2024 # The temporary output file is owned by the caller.
  sudo jq \
    --argjson _args "$_process_args_json" \
    '.process.args = $_args
      | .process.terminal = false
      | .linux.maskedPaths = []
      | .linux.readonlyPaths = []' \
    "${_bundle}/config.json" >"$_config_tmp"
  sudo install -m 0600 "$_config_tmp" "${_bundle}/config.json"
  rm -f "$_config_tmp"
}

__remove_oci_container() {
  local _root="$1"
  local _id="$2"

  sudo nscell --root "$_root" delete --force "$_id" >/dev/null 2>&1 || true
}

__remove_oci_bundle() {
  local _bundle="$1"

  sudo rm -rf "$_bundle"
}

__container_capability_exists() {
  local _id="$1"

  sudo find /run/nscell/containers \
    -mindepth 2 \
    -maxdepth 2 \
    -type f \
    -name "${_id}.cap" \
    -print \
    -quit |
    grep -q .
}

__host_cgroup_path() {
  local _pid="$1"
  local _relative

  _relative="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/${_pid}/cgroup")"
  if [[ -z "$_relative" ]]; then
    echo "unable to resolve unified cgroup for pid ${_pid}" >&2
    return 1
  fi
  printf '/sys/fs/cgroup%s\n' "$_relative"
}

__find_ancestor_cgroup_with_value() {
  local _current="$1"
  local _file="$2"
  local _expected="$3"

  if [[ "$_file" == */* ]]; then
    echo "cgroup control file must be a basename: ${_file}" >&2
    return 1
  fi

  while [[ "$_current" == "/sys/fs/cgroup" || "$_current" == "/sys/fs/cgroup/"* ]]; do
    if sudo test -f "${_current}/${_file}" &&
      [[ "$(sudo cat "${_current}/${_file}")" == "$_expected" ]]; then
      printf '%s\n' "$_current"
      return 0
    fi
    if [[ "$_current" == "/sys/fs/cgroup" ]]; then
      break
    fi
    _current="${_current%/*}"
  done

  return 1
}
