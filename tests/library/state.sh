#!/usr/bin/env bash
# shellcheck disable=SC2154

__nscell_state_snapshot() {
  local _kind="$1"
  local _subject="$2"
  local _path="${3:-/var/lib/nscell/state/events.log}"

  sudo test -f "$_path"
  sudo python3 - "$_path" "$_kind" "$_subject" <<'PY'
import json
import sys
import zlib

path, wanted_kind, wanted_subject = sys.argv[1:]
with open(path, "rb") as source:
    data = source.read()

offset = 0
sequence = 0
latest = {}
while offset < len(data):
    if len(data) - offset < 16:
        raise SystemExit("state event log has a torn header")
    header = data[offset:offset + 16]
    if header[:8] != b"NSCELST1":
        raise SystemExit("state event log has invalid record magic")
    length = int.from_bytes(header[8:12], "big")
    checksum = int.from_bytes(header[12:16], "big")
    end = offset + 16 + length
    if length == 0 or end > len(data):
        raise SystemExit("state event log has an invalid record length")
    payload = data[offset + 16:end]
    if zlib.crc32(header[:12] + payload) & 0xffffffff != checksum:
        raise SystemExit("state event log checksum mismatch")
    event = json.loads(payload)
    sequence += 1
    if event.get("version") != 2 or event.get("sequence") != sequence:
        print(
            f"state event mismatch at record {sequence}: {event!r}",
            file=sys.stderr,
        )
        raise SystemExit("state event log sequence mismatch")
    kind = event.get("kind")
    subject = event.get("subject")
    if kind == "epoch":
        if sequence != 1 or subject != "":
            raise SystemExit("state event log has an invalid epoch event")
    elif kind == "checkpoint":
        if sequence != 2:
            raise SystemExit("state event log has an invalid checkpoint position")
        latest.clear()
        for entry in event.get("payload", {}).get("entries", []):
            latest[(entry.get("kind"), entry.get("subject"))] = entry.get("payload")
    elif kind in {"subid", "leases", "volume"}:
        latest[(kind, subject)] = event.get("payload")
    else:
        raise SystemExit(f"state event log has unknown kind {kind!r}")
    offset = end

if offset != len(data) or sequence == 0:
    raise SystemExit("state event log is empty or incomplete")
print(json.dumps(latest.get((wanted_kind, wanted_subject)), sort_keys=True))
PY
}

__assert_nscell_state_store() {
  local _path="${1:-/var/lib/nscell/state/events.log}"
  local _mode

  sudo test -f "$_path"
  _mode="$(sudo stat -c '%a' "$_path")"
  if [[ "$_mode" != "600" ]]; then
    echo "nscell state event log mode is ${_mode}, want 600" >&2
    return 1
  fi
}

__assert_state_map_lacks_id() {
  local _kind="$1"
  local _subject="$2"
  local _map="$3"
  local _id="$4"
  local _path="${5:-/var/lib/nscell/state/events.log}"
  local _snapshot

  _snapshot="$(__nscell_state_snapshot "$_kind" "$_subject" "$_path")"
  jq -e --arg _id "$_id" --arg _map "$_map" \
    '((. // {})[$_map] // {}) | has($_id) | not' <<<"$_snapshot" >/dev/null
}

__dump_nscell_state_snapshots() {
  local _path="${1:-/var/lib/nscell/state/events.log}"
  local _kind _subject _snapshot
  local -a _domains=(
    "subid allocator"
    "leases control-plane"
    "volume buildkit"
    "volume containerd"
    "volume docker"
    "volume k0s"
    "volume kubelet"
    "volume rancher-k3s"
    "volume rancher-rke2"
  )

  if ! sudo test -f "$_path"; then
    return 0
  fi

  for _domain in "${_domains[@]}"; do
    read -r _kind _subject <<<"$_domain"
    printf '\n--- nscell state %s/%s ---\n' "$_kind" "$_subject" >&2
    if _snapshot="$(__nscell_state_snapshot "$_kind" "$_subject" "$_path" 2>/dev/null)"; then
      jq . <<<"$_snapshot" >&2 || true
    else
      echo "state snapshot unavailable" >&2
    fi
  done
}
