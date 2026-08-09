#!/usr/bin/env bash
# shellcheck disable=SC2154

__safe_image_name() {
	printf '%s' "$1" | sed -E 's#[/:@]+#_#g'
}

__image_archive_path() {
	local _image="$1"
	printf '%s/%s.tar\n' "$_image_cache_dir" "$(__safe_image_name "$_image")"
}

__retry() {
	local _max_attempts="$1"
	shift
	local _attempt=1
	local _status

	while true; do
		if "$@"; then
			return 0
		else
			_status=$?
		fi
		if ((_attempt >= _max_attempts)); then
			return "$_status"
		fi
		__log "${1} failed with ${_status}; retrying ($((_attempt + 1))/${_max_attempts})"
		sleep $((_attempt * 5))
		_attempt=$((_attempt + 1))
	done
}

__ensure_host_image() {
	local _image="$1"
	if ! docker image inspect "$_image" >/dev/null 2>&1; then
		__log "pulling host image ${_image}"
		__retry 3 docker pull --quiet "$_image"
	fi
}

__ensure_tagged_image() {
	local _target_image="$1"
	local _source_image="$2"

	if docker image inspect "$_target_image" >/dev/null 2>&1; then
		return
	fi
	__ensure_host_image "$_source_image"
	docker tag "$_source_image" "$_target_image"
}

__build_ci_image() {
	local _image="$1"
	local _context="$2"
	shift 2

	__log "building CI image ${_image}"
	__retry 3 docker build --network host -t "$_image" "$@" "$_context"
}

__workload_var_name() {
	local _workload="$1"
	printf '%s' "$_workload" | tr '-' '_'
}

__build_workload_ci_image() {
	local _workload="$1"
	local _workload_var _image_var _base_image_var _image _base_image

	_workload_var="$(__workload_var_name "$_workload")"
	_image_var="_${_workload_var}_image"
	_base_image_var="_${_workload_var}_base_image"
	_image="${!_image_var:-}"
	_base_image="${!_base_image_var:-}"
	if [[ -z "$_image" || -z "$_base_image" ]]; then
		echo "workload ${_workload} is missing ${_image_var} or ${_base_image_var}" >&2
		exit 1
	fi

	__ensure_host_image "$_base_image"
	__build_ci_image "$_image" "${_workload_dir}/workloads/${_workload}" --build-arg "BASE_IMAGE=${_base_image}"
}

__build_ci_images() {
	local _workload_path _workload

	for _workload_path in "${_workload_dir}"/workloads/*; do
		[[ -d "$_workload_path" && -f "${_workload_path}/Dockerfile" ]] || continue
		_workload="$(basename "$_workload_path")"
		__build_workload_ci_image "$_workload"
	done
	__ensure_tagged_image "$_kubernetes_k3s_pause_image" "$_kubernetes_k3s_pause_source_image"
}

__ensure_cached_image_archive() {
	local _image="$1"
	local _archive _id_file _lock _tmp _image_id _cached_id

	__init_ci_dirs
	_archive="$(__image_archive_path "$_image")"
	_id_file="${_archive}.id"
	_lock="${_archive}.lock"
	(
		flock 9
		__ensure_host_image "$_image"
		_image_id="$(docker image inspect "$_image" --format '{{.Id}}')"
		_cached_id="$(cat "$_id_file" 2>/dev/null || true)"
		if [[ -s "$_archive" && "$_cached_id" == "$_image_id" ]]; then
			printf '%s\n' "$_archive"
			exit 0
		fi
		_tmp="${_archive}.$$"
		__log "saving ${_image} to ${_archive}"
		docker save -o "$_tmp" "$_image"
		mv -f "$_tmp" "$_archive"
		printf '%s\n' "$_image_id" >"$_id_file"
		printf '%s\n' "$_archive"
	) 9>"$_lock"
}

__load_image_into_docker_container() {
	local _container="$1"
	local _image="$2"
	local _archive

	_archive="$(__ensure_cached_image_archive "$_image")"
	__log "loading ${_image} into Docker inside ${_container}"
	docker exec -i "$_container" docker load <"$_archive" >/dev/null
	docker exec "$_container" docker image inspect "$_image" >/dev/null
}
