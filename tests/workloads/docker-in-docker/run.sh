#!/usr/bin/env bash
# shellcheck disable=all

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"

__prepare() {
  local _root="${_volume_root}/docker-in-docker"

  __init_ci_dirs
  __log "preparing Docker-in-Docker network and bind mount roots"
  if ! docker network inspect "$_docker_in_docker_network" >/dev/null 2>&1; then
    docker network create --driver bridge "$_docker_in_docker_network" >/dev/null
  fi

  docker rm -f "$_docker_in_docker_name" >/dev/null 2>&1 || true
  rm -rf "${_root}/data" "${_root}/docker"
  install -d -m 0755 "${_root}/data" "${_root}/docker/certs"
  stat -c 'host-before %u:%g %n' "${_root}/data" "${_root}/docker" "${_root}/docker/certs"

  cat >"${_test_root}/nscell-docker-in-docker-compose.yml" <<EOF
services:
  docker-in-docker:
    container_name: ${_docker_in_docker_name}
    hostname: ${_docker_in_docker_name}
    image: "${_docker_in_docker_image}"
    restart: "no"
    runtime: nscell
    privileged: false
    annotations:
      io.backend.security.profile: dind
    labels:
      io.backend.security.profile: dind
    networks:
      - ${_docker_in_docker_network}
    devices:
      - /dev/net/tun:/dev/net/tun:rwm
    volumes:
      - ${_root}/data:/data
      - ${_root}/docker:/var/lib/docker
      - ${_root}/docker/certs:/certs
    environment:
      - TZ=Asia/Shanghai
      - DOCKER_TLS_CERTDIR=
networks:
  ${_docker_in_docker_network}:
    external: true
EOF
}

__wait_for_inner_docker() {
  local _name="$1"
  local _prefix="${2:-}"

  docker exec "$_name" sh -lc "
		for _i in \$(seq 1 60); do
			if docker info >/dev/null 2>&1; then
				docker info --format \"${_prefix}{{.ServerVersion}} {{.Architecture}} {{.Driver}}\"
				exit 0
			fi
			sleep 2
		done
		docker info
	"
}

__main() {
  local _root="${_volume_root}/docker-in-docker"

  if [[ "${1:-}" == "cleanup" ]]; then
    __require_cmd docker
    docker rm -f "$_docker_in_docker_name" >/dev/null 2>&1 || true
    docker network rm "$_docker_in_docker_network" >/dev/null 2>&1 || true
    rm -rf "$_root"
    return
  fi

  __require_cmd docker
  __require_cmd flock
  __assert_nscell_ready
  __build_ci_image "$_docker_in_docker_image" "${_workload_dir}/workloads/docker-in-docker" --build-arg "BASE_IMAGE=${_docker_in_docker_base_image}"
  __build_ci_image "$_inner_nginx_image" "${_workload_path}" -f "${_workload_path}/nginx.Dockerfile" --build-arg "BASE_IMAGE=${_inner_nginx_base_image}"
  __prepare

  __log "starting Docker-in-Docker validation container"
  __ensure_host_image "$_docker_in_docker_image"
  docker compose -f "${_test_root}/nscell-docker-in-docker-compose.yml" up -d --remove-orphans

  __log "checking idmapped bind mounts"
  stat -c 'host-after %u:%g %n' "${_root}/data" "${_root}/docker" "${_root}/docker/certs"
  docker exec "$_docker_in_docker_name" sh -lc '
		cat /proc/self/uid_map
		stat -c "container %u:%g %n" /data /var/lib/docker /certs
		touch /data/probe /var/lib/docker/probe /certs/probe
		stat -c "probe %u:%g %n" /data/probe /var/lib/docker/probe /certs/probe
	'
  stat -c 'host-probe %u:%g %n' "${_root}/data/probe" "${_root}/docker/probe" "${_root}/docker/certs/probe"

  __log "checking inner docker"
  __wait_for_inner_docker "$_docker_in_docker_name"
  docker exec "$_docker_in_docker_name" nscell-ci-docker-in-docker-smoke

  __log "checking host docker top"
  docker top "$_docker_in_docker_name" >/dev/null

  __log "checking Docker-in-Docker restart"
  docker restart -t 1 "$_docker_in_docker_name"
  __wait_for_inner_docker "$_docker_in_docker_name" "restart "
  docker exec "$_docker_in_docker_name" nscell-ci-docker-in-docker-smoke

  __log "checking Docker-in-Docker stop/start"
  docker stop -t 1 "$_docker_in_docker_name"
  docker start "$_docker_in_docker_name"
  __wait_for_inner_docker "$_docker_in_docker_name" "stopstart "

  __log "checking inner nginx with docker load cache"
  __wait_for_inner_docker "$_docker_in_docker_name"
  __load_image_into_docker_container "$_docker_in_docker_name" "$_inner_nginx_image"
  docker exec "$_docker_in_docker_name" sh -lc "docker rm -f nginx >/dev/null 2>&1 || true"
  docker exec "$_docker_in_docker_name" sh -lc "docker run -d -p 80:80 --name=nginx '$_inner_nginx_image' >/dev/null"
  docker exec "$_docker_in_docker_name" sh -lc 'docker ps --filter name=nginx --format "inner-nginx {{.Status}} {{.Ports}}"'

  __assert_nscell_ready
  echo "docker-in-docker-validation-ok"
}

__main "$@"
