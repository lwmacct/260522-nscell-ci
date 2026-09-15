#!/usr/bin/env bash

set -euo pipefail

_vm_name="${VM_NAME:?VM_NAME is required}"
_network_interface="${NETWORK_INTERFACE:-enp5s0}"
_log_dir="${LOG_DIR:?LOG_DIR is required}"

__collect_diagnostics() {
  mkdir -p "${_log_dir}"
  {
    sudo incus list "${_vm_name}" --format=yaml || true
    sudo incus info "${_vm_name}" --show-log || true
    sudo incus exec "${_vm_name}" -- ip -4 address show || true
    sudo incus exec "${_vm_name}" -- ip -4 route show || true
    sudo incus exec "${_vm_name}" -- cat /etc/resolv.conf || true
    sudo incus exec "${_vm_name}" -- \
      systemctl --no-pager --full status systemd-networkd systemd-resolved || true
    sudo incus network show incusbr0 || true
    sudo sysctl net.ipv4.ip_forward || true
    sudo iptables --numeric --verbose --list FORWARD || true
    sudo iptables --numeric --verbose --list DOCKER-USER || true
    sudo nft list ruleset || true
    ip -4 address show || true
    ip -4 route show || true
    sudo journalctl --no-pager --unit=incus -n 200 || true
  } >"${_log_dir}/network-diagnostics.log" 2>&1
}

__cleanup() {
  local _status=$?

  if [[ ${_status} -ne 0 ]]; then
    __collect_diagnostics
  fi
  return "${_status}"
}

__wait_for_agent() {
  local _attempt

  for _attempt in $(seq 1 120); do
    if sudo incus exec "${_vm_name}" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  echo "Incus agent did not become ready within 10 minutes" >&2
  return 1
}

__wait_for_ipv4() {
  local _attempt _address _gateway

  for _attempt in $(seq 1 60); do
    _address="$(sudo incus exec "${_vm_name}" -- \
      ip -4 -o address show dev "${_network_interface}" scope global 2>/dev/null |
      awk 'NR == 1 {print $4}' || true)"
    _gateway="$(sudo incus exec "${_vm_name}" -- \
      ip -4 route show default 2>/dev/null |
      awk 'NR == 1 {print $3}' || true)"
    if [[ -n "${_address}" && -n "${_gateway}" ]]; then
      printf '%s\t%s\n' "${_address}" "${_gateway}"
      return 0
    fi
    sleep 2
  done
  echo "Guest did not receive an IPv4 address and default route" >&2
  return 1
}

__guest_https_status() {
  local _url="$1"

  sudo incus exec "${_vm_name}" -- curl -4 -sS \
    --retry 2 \
    --connect-timeout 10 \
    --max-time 60 \
    --output /dev/null \
    --write-out '%{http_code}' \
    "${_url}"
}

__assert_guest_https() {
  local _url="$1"
  shift
  local _status _expected

  _status="$(__guest_https_status "${_url}")"
  for _expected in "$@"; do
    if [[ "${_status}" == "${_expected}" ]]; then
      printf 'guest-https-ok status=%s url=%s\n' "${_status}" "${_url}"
      return 0
    fi
  done
  echo "Unexpected HTTP status ${_status} for ${_url}; expected: $*" >&2
  return 1
}

__main() {
  local _network_state _guest_ipv4_cidr _guest_gateway _guest_ipv4

  trap __cleanup EXIT HUP INT TERM
  __wait_for_agent
  _network_state="$(__wait_for_ipv4)"
  IFS=$'\t' read -r _guest_ipv4_cidr _guest_gateway <<<"${_network_state}"
  _guest_ipv4="${_guest_ipv4_cidr%/*}"

  sudo incus exec "${_vm_name}" -- ip -4 address show dev "${_network_interface}"
  sudo incus exec "${_vm_name}" -- ip -4 route show
  sudo incus exec "${_vm_name}" -- cat /etc/resolv.conf
  ping -c 3 -W 3 "${_guest_ipv4}"

  sudo incus exec "${_vm_name}" -- getent ahostsv4 archive.ubuntu.com
  sudo incus exec "${_vm_name}" -- getent ahostsv4 security.ubuntu.com
  sudo incus exec "${_vm_name}" -- getent ahostsv4 ghcr.io
  sudo incus exec "${_vm_name}" -- getent ahostsv4 registry-1.docker.io

  __assert_guest_https \
    https://archive.ubuntu.com/ubuntu/dists/resolute/InRelease 200
  __assert_guest_https \
    https://security.ubuntu.com/ubuntu/dists/resolute-security/InRelease 200
  __assert_guest_https https://ghcr.io/v2/ 200 401
  __assert_guest_https https://registry-1.docker.io/v2/ 200 401

  printf 'nscell-vm-network-ok address=%s gateway=%s\n' \
    "${_guest_ipv4_cidr}" "${_guest_gateway}"
  __collect_diagnostics
}

__main "$@"
