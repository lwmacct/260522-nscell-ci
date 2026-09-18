#!/bin/sh
set -eu

_bundle=""
_runc_root=""

__cleanup() {
  if [ -n "$_runc_root" ]; then
    runc --root "$_runc_root" delete -f nscell-thermal-mask >/dev/null 2>&1 || true
  fi
  if [ -n "$_bundle" ]; then
    rm -rf "$_bundle"
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

__write_bundle() {
  _bundle="$(mktemp -d /tmp/nscell-thermal-mask.XXXXXX)"
  _runc_root="/run/nscell-runc-thermal-mask-$$"
  trap __cleanup EXIT HUP INT TERM

  mkdir -p \
    "${_bundle}/rootfs/bin" \
    "${_bundle}/rootfs/dev" \
    "${_bundle}/rootfs/proc" \
    "${_bundle}/rootfs/sys/devices/system/cpu/cpu0/thermal_throttle" \
    "${_bundle}/rootfs/tmp"
  cp /bin/busybox "${_bundle}/rootfs/bin/busybox"
  ln -s busybox "${_bundle}/rootfs/bin/sh"

  (
    cd "$_bundle"
    runc spec
    jq '
      .process.terminal = false |
      .process.args = ["/bin/sh", "-c", "printf \"%s\\n\" nscell-runc-thermal-mask-ok"] |
      .root.readonly = false |
      .mounts = [] |
      .linux.namespaces = [{"type": "pid"}, {"type": "mount"}] |
      .linux.maskedPaths = ["/sys/devices/system/cpu/cpu0/thermal_throttle"] |
      del(.linux.resources)
    ' config.json >config.json.next
    mv config.json.next config.json
    runc --root "$_runc_root" run nscell-thermal-mask
  )
}

__main() {
  case "${1:-}" in
    diagnostics)
      __diagnostics
      ;;
    run)
      __write_bundle
      ;;
    *)
      echo "usage: $0 {diagnostics|run}" >&2
      exit 2
      ;;
  esac
}

__main "$@"
