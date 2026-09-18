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

__write_bundle() {
  mkdir -p /var/lib/docker/overlay2
  _bundle="$(mktemp -d /var/lib/docker/overlay2/nscell-thermal-mask.XXXXXX)"
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
      .linux.rootfsPropagation = "rprivate" |
      .linux.namespaces = [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}] |
      .linux.maskedPaths = ["/sys/devices/system/cpu/cpu0/thermal_throttle"] |
      del(.linux.resources)
    ' config.json >config.json.next
    mv config.json.next config.json
    runc --root "$_runc_root" run nscell-thermal-mask
  )
}

__main() {
  if [ "${1:-}" != "run" ]; then
    echo "usage: $0 run" >&2
    exit 2
  fi
  __write_bundle
}

__main "$@"
