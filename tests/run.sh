#!/usr/bin/env bash
# shellcheck disable=all

set -euo pipefail

_workload_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

_test="${1:-all}"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/diagnostics.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"

__usage() {
  local _workload
  cat <<'EOF'
usage: scripts/ci.sh run-workloads [workload...]

  scripts/ci.sh run-workloads all
                         run all workload tests
  scripts/ci.sh run-workloads docker-in-docker procfs-cpu
                         run selected workload tests concurrently

Set NSCELL_WORKLOAD_FAIL_FAST=0 to let every selected workload finish before
returning the first failure.

available workloads:
EOF
  for _workload in $(__workload_names); do
    printf '  %s\n' "$_workload"
  done
}

__workload_names() {
  bash "${_workload_dir}/manifest.sh" workloads
}

__workload_script() {
  local _name="$1"

  case "$_name" in
  "" | */* | .* | *..*)
    return 1
    ;;
  esac
  [[ -f "${_workload_dir}/workloads/${_name}/run.sh" ]]
}

__require_workload() {
  local _name="$1"

  if ! __workload_script "$_name"; then
    echo "unknown workload: ${_name}" >&2
    __usage >&2
    exit 2
  fi
}

__run_one_test() {
  local _name="$1"

  __require_workload "$_name"
  bash "${_workload_dir}/workloads/${_name}/run.sh"
}

__cleanup_one_test() {
  local _name="$1"
  local _workload

  __require_cmd docker
  case "$_name" in
  all)
    for _workload in $(__workload_names); do
      bash "${_workload_dir}/workloads/${_workload}/run.sh" cleanup
    done
    ;;
  *)
    __require_workload "$_name"
    bash "${_workload_dir}/workloads/${_name}/run.sh" cleanup
    ;;
  esac
  rm -rf "$_volume_root"
}

__cleanup_tests() {
  local _workload

  if (($# == 0)); then
    __cleanup_one_test all
    return
  fi
  for _workload in "$@"; do
    __cleanup_one_test "$_workload"
  done
}

__run_all_tests() {
  local -a _workloads=()
  local _workload _status

  mapfile -t _workloads < <(__workload_names)
  __require_cmd docker
  __require_cmd flock
  __init_ci_dirs
  __assert_nscell_ready

  __log "running nscell workload tests: ${_workloads[*]}"
  for _workload in "${_workloads[@]}"; do
    if bash "$0" "$_workload" >"${_log_root}/${_workload}.log" 2>&1; then
      __log "${_workload} workload test passed"
      tail -80 "${_log_root}/${_workload}.log"
    else
      _status=$?
      __log "${_workload} workload test failed with ${_status}"
      cat "${_log_root}/${_workload}.log" >&2 || true
      exit "$_status"
    fi
  done

  echo "ci-tests-ok"
}

__run_parallel_tests() {
  local -a _workloads=("$@")
  local _run_id _run_root _log_dir
  local -a _pids=()
  local -A _pid_workloads=()
  local _workload _workload_id _pid _status _done_pid _remaining _failed=0
  local _index=0
  local _fail_fast="${NSCELL_WORKLOAD_FAIL_FAST:-1}"

  case "${_fail_fast}" in
  0 | 1) ;;
  *)
    echo "NSCELL_WORKLOAD_FAIL_FAST must be 0 or 1" >&2
    return 2
    ;;
  esac

  if ((${#_workloads[@]} == 0)); then
    mapfile -t _workloads < <(__workload_names)
  fi

  for _workload in "${_workloads[@]}"; do
    __require_workload "$_workload"
  done

  __require_cmd docker
  __require_cmd flock
  __init_ci_dirs
  __assert_nscell_ready

  if [[ -n "${NSCELL_WORKLOAD_RUN_ID:-}" ]]; then
    _run_id="$NSCELL_WORKLOAD_RUN_ID"
  elif [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    _run_id="${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}"
  else
    _run_id="$(date +%H%M%S)-$$"
  fi
  _run_id="$(__safe_resource_id "$_run_id")"
  _run_id="${_run_id:0:16}"
  _run_root="${_test_root}/runs/${_run_id}"
  _log_dir="${_run_root}/logs"
  install -d -m 0755 "$_log_dir"

  __log "running nscell workload tests concurrently: ${_workloads[*]}"
  for _workload in "${_workloads[@]}"; do
    ((++_index))
    _workload_id="${_run_id}-${_index}"
    (
      export NSCELL_WORKLOAD_ID="$_workload_id"
      unset NSCELL_CI_VOLUME_ROOT NSCELL_CI_LOG_ROOT
      bash "$0" "$_workload"
    ) >"${_log_dir}/${_workload}.log" 2>&1 &
    _pid=$!
    _pids+=("$_pid")
    _pid_workloads["$_pid"]="$_workload"
  done

  _remaining=${#_pids[@]}
  while ((_remaining > 0)); do
    _done_pid=""
    if wait -n -p _done_pid; then
      _status=0
    else
      _status=$?
    fi
    if [[ -z "$_done_pid" ]]; then
      break
    fi

    _workload="${_pid_workloads[$_done_pid]:-unknown}"
    unset '_pid_workloads[$_done_pid]'
    ((_remaining--))
    if ((_status == 0)); then
      __log "${_workload} workload test passed"
      tail -80 "${_log_dir}/${_workload}.log"
      continue
    fi

    _failed=1
    __log "${_workload} workload test failed with ${_status}"
    cat "${_log_dir}/${_workload}.log" >&2 || true
    if ((_fail_fast)); then
      __terminate_parallel_workloads _pid_workloads
      exit 1
    fi
  done

  if ((_failed != 0)); then
    exit 1
  fi

  echo "ci-tests-ok"
}

__terminate_parallel_workloads() {
  local -n _running="$1"
  local _pid _workload

  for _pid in "${!_running[@]}"; do
    _workload="${_running[$_pid]}"
    __log "terminating ${_workload} workload after earlier failure"
    kill -TERM "$_pid" >/dev/null 2>&1 || true
  done
  for _pid in "${!_running[@]}"; do
    wait "$_pid" >/dev/null 2>&1 || true
  done
}

__main() {
  case "$_test" in
  run)
    shift
    if (($# != 1)); then
      __usage >&2
      exit 2
    fi
    __run_one_test "$1"
    ;;
  all)
    __run_all_tests
    ;;
  parallel)
    shift
    __run_parallel_tests "$@"
    ;;
  cleanup)
    shift
    if [[ "${1:-}" == "--" ]]; then
      shift
    fi
    __cleanup_tests "$@"
    ;;
  -h | --help | help)
    __usage
    ;;
  *)
    __run_one_test "$_test"
    ;;
  esac
}

trap __dump_debug EXIT
__main "$@"
