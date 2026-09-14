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

_root="${_volume_root}/resource-limits"
_bundle="${_root}/bundle"
_export_name="nscell-resource-limits-export-${_workload_resource_id:-resource-limits}"
_soft_nofile=1024
_hard_nofile=1048576

__cleanup() {
  __remove_oci_container "$_oci_runtime_root" "$_resource_limits_id"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__configure_limits() {
  local _config_tmp

  _config_tmp="$(mktemp)"
  # shellcheck disable=SC2024 # The temporary output file is owned by the caller.
  sudo jq \
    --argjson _soft "$_soft_nofile" \
    --argjson _hard "$_hard_nofile" \
    '.process.rlimits = [{
      type: "RLIMIT_NOFILE",
      soft: $_soft,
      hard: $_hard
    }]' \
    "${_bundle}/config.json" >"$_config_tmp"
  sudo install -m 0600 "$_config_tmp" "${_bundle}/config.json"
  rm -f "$_config_tmp"
}

__install_probe() {
  sudo tee "${_bundle}/rootfs/probe.sh" >/dev/null <<'EOF'
#!/bin/sh
set -eu

soft=$(ulimit -Sn)
hard=$(ulimit -Hn)
printf 'resource-limits-nofile soft=%s hard=%s\n' "$soft" "$hard"
[ "$soft" -eq 1024 ]
[ "$hard" -eq 1048576 ]
awk -F'  +' '
  $1 == "Max open files" && $2 == 1024 && $3 == 1048576 { found = 1 }
  END { exit !found }
' /proc/self/limits
echo resource-limits-probe-ok
EOF
  sudo chmod 0755 "${_bundle}/rootfs/probe.sh"
}

__wait_for_stopped() {
  local _deadline=$((SECONDS + 20))
  local _actual=""

  while ((SECONDS <= _deadline)); do
    _actual="$(sudo nscell --root "$_oci_runtime_root" state \
      "$_resource_limits_id" 2>/dev/null |
      jq -r '.status // empty' || true)"
    if [[ "$_actual" == "stopped" ]]; then
      return 0
    fi
    sleep 0.2
  done

  echo "resource limit container did not stop; last state: ${_actual:-unavailable}" >&2
  return 1
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
  __configure_limits
  __install_probe

  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_resource_limits_id"
  sudo nscell --root "$_oci_runtime_root" start "$_resource_limits_id"
  _probe_output="$(sudo nscell --root "$_oci_runtime_root" exec \
    "$_resource_limits_id" /probe.sh)"
  printf '%s\n' "$_probe_output"
  if [[ "$_probe_output" != "resource-limits-nofile soft=1024 hard=1048576
resource-limits-probe-ok" ]]; then
    echo "unexpected resource limit probe output" >&2
    exit 1
  fi

  sudo nscell --root "$_oci_runtime_root" kill "$_resource_limits_id" TERM
  __wait_for_stopped
  sudo nscell --root "$_oci_runtime_root" delete "$_resource_limits_id"
  __assert_nscell_ready

  trap - EXIT
  __cleanup
  echo "resource-limits-validation-ok"
}

__main "$@"
