#!/bin/sh
set -eu

_container="nscell-thermal-mask"
_request=""

__cleanup() {
  docker rm -f "$_container" >/dev/null 2>&1 || true
  if [ -n "$_request" ]; then
    rm -f "$_request"
  fi
}

__diagnostics() {
  uname -a
  printf 'cpu-count=%s\n' "$(nproc)"
  runc --version | sed -n '1,2p'
  if [ -d /sys/devices/system/cpu/cpu0/thermal_throttle ]; then
    echo 'thermal-throttle-sysfs=present'
  else
    echo 'thermal-throttle-sysfs=absent'
  fi
}

__run_masked_container() {
  _image="$1"
  _response=""
  _id=""
  _state=""

  _request="$(mktemp /tmp/nscell-thermal-mask-request.XXXXXX)"
  trap __cleanup EXIT HUP INT TERM
  docker rm -f "$_container" >/dev/null 2>&1 || true
  jq -n \
    --arg image "$_image" \
    --arg path /sys/devices/system/cpu/cpu0/thermal_throttle \
    '{
      Image: $image,
      HostConfig: {
        Tmpfs: {($path): ""},
        MaskedPaths: [$path]
      }
    }' >"$_request"

  _response="$(
    curl -sS \
      --unix-socket /var/run/docker.sock \
      -H 'Content-Type: application/json' \
      -X POST \
      --data-binary "@${_request}" \
      "http://docker/containers/create?name=${_container}"
  )"
  if ! _id="$(printf '%s\n' "$_response" | jq -er '.Id // empty')"; then
    printf '%s\n' "$_response" >&2
    return 1
  fi

  if ! docker start "$_container" >/dev/null; then
    docker inspect --format 'thermal-mask-state running={{.State.Running}} error={{.State.Error}}' "$_container" >&2 || true
    return 1
  fi
  sleep 2
  _state="$(docker inspect --format '{{.State.Running}} {{.State.Error}}' "$_container")"
  printf 'thermal-mask-state %s\n' "$_state"
  if [ "${_state%% *}" != true ]; then
    return 1
  fi
  echo 'nscell-runc-thermal-mask-ok'
}

__main() {
  case "${1:-}" in
    diagnostics)
      __diagnostics
      ;;
    run)
      if [ "$#" -ne 2 ]; then
        echo "usage: $0 run IMAGE" >&2
        exit 2
      fi
      __run_masked_container "$2"
      ;;
    *)
      echo "usage: $0 {diagnostics|run IMAGE}" >&2
      exit 2
      ;;
  esac
}

__main "$@"
