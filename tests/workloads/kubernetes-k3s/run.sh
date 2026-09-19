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
  local _root="${_volume_root}/kubernetes-k3s"

  __init_ci_dirs
  __log "preparing Kubernetes k3s roots and image cache"
  docker rm -f "$_kubernetes_k3s_name" >/dev/null 2>&1 || true
  rm -rf "$_root"
  install -d -m 0755 "$_root"
  __ensure_host_image "$_kubernetes_k3s_image"
  __ensure_tagged_image "$_kubernetes_k3s_pause_image" "$_kubernetes_k3s_pause_source_image"
  __ensure_cached_image_archive "$_inner_nginx_image" >/dev/null
  __ensure_cached_image_archive "$_kubernetes_k3s_pause_image" >/dev/null
}

__wait_for_api() {
  for _i in $(seq 1 90); do
    if docker exec "$_kubernetes_k3s_name" kubectl get --raw=/readyz >/dev/null 2>&1 &&
      docker exec "$_kubernetes_k3s_name" kubectl get namespace default >/dev/null 2>&1 &&
      docker exec "$_kubernetes_k3s_name" kubectl get serviceaccount default -n default >/dev/null 2>&1; then
      docker exec "$_kubernetes_k3s_name" kubectl get nodes -o wide || true
      return 0
    fi
    sleep 2
  done
  __dump_k3s_diagnostics
  docker exec "$_kubernetes_k3s_name" kubectl get --raw=/readyz >&2 || true
  return 1
}

__import_image_archive() {
  local _image="$1"
  local _archive _archive_base

  _archive="$(__image_archive_path "$_image")"
  _archive_base="$(basename "$_archive")"
  docker exec "$_kubernetes_k3s_name" ctr -n k8s.io images import "/opt/nscell/images/${_archive_base}" >/dev/null
  docker exec "$_kubernetes_k3s_name" ctr -n k8s.io images ls | grep -F "$_image"
}

__dump_k3s_diagnostics() {
  local _containerd_log="${_volume_root}/kubernetes-k3s/agent/containerd/containerd.log"

  __log "k3s container diagnostics"
  docker logs "$_kubernetes_k3s_name" >&2 || true
  docker exec "$_kubernetes_k3s_name" sh -c 'cat /var/lib/rancher/k3s/agent/containerd/containerd.log' >&2 || true
  if [[ -f "$_containerd_log" ]]; then
    cat "$_containerd_log" >&2 || true
  fi
}

__main() {
  local _root="${_volume_root}/kubernetes-k3s"
  local _phase _ready

  if [[ "${1:-}" == "cleanup" ]]; then
    __require_cmd docker
    docker rm -f "$_kubernetes_k3s_name" >/dev/null 2>&1 || true
    rm -rf "$_root"
    return
  fi

  __require_cmd docker
  __require_cmd flock
  __assert_nscell_ready
  __build_ci_image "$_kubernetes_k3s_image" "${_workload_dir}/workloads/kubernetes-k3s" --build-arg "BASE_IMAGE=${_kubernetes_k3s_base_image}"
  __build_ci_image "$_inner_nginx_image" "${_workload_path}" -f "${_workload_path}/nginx.Dockerfile" --build-arg "BASE_IMAGE=${_inner_nginx_base_image}"
  __prepare

  __log "starting k3s Kubernetes node under nscell"
  docker run -d \
    --name "$_kubernetes_k3s_name" \
    --hostname "$_kubernetes_k3s_name" \
    --runtime nscell \
    --cgroupns=private \
    --device /dev/net/tun:/dev/net/tun:rwm \
    --tmpfs /run \
    --tmpfs /run/lock \
    -v "${_root}:/var/lib/rancher/k3s" \
    -v "${_image_cache_dir}:/opt/nscell/images:ro" \
    -e K3S_KUBECONFIG_MODE=644 \
    "$_kubernetes_k3s_image" \
    server \
    --disable=traefik \
    --disable=servicelb \
    --disable=metrics-server \
    --disable=local-storage \
    --disable=coredns \
    --flannel-backend=none \
    --disable-network-policy \
    --kubelet-arg=feature-gates=KubeletInUserNamespace=true \
    --kubelet-arg=fail-swap-on=false >/dev/null

  __wait_for_api
  __log "loading cached pod images into k3s containerd"
  __import_image_archive "$_kubernetes_k3s_pause_image"
  __import_image_archive "$_inner_nginx_image"

  __log "running Kubernetes pod workload"
  docker exec -i "$_kubernetes_k3s_name" kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${_kubernetes_k3s_pod_name}
  labels:
    app: nscell-kubernetes-k3s-ci
spec:
  nodeName: ${_kubernetes_k3s_name}
  hostNetwork: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: nginx
      image: ${_inner_nginx_image}
      imagePullPolicy: Never
      ports:
        - containerPort: 80
EOF

  for _i in $(seq 1 90); do
    _phase="$(docker exec "$_kubernetes_k3s_name" kubectl get pod "$_kubernetes_k3s_pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    _ready="$(docker exec "$_kubernetes_k3s_name" kubectl get pod "$_kubernetes_k3s_pod_name" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
    if [[ "$_phase" == "Running" && "$_ready" == "true" ]]; then
      docker exec "$_kubernetes_k3s_name" kubectl get pod "$_kubernetes_k3s_pod_name" -o wide
      echo "kubernetes-k3s-pod-ok"
      __assert_nscell_ready
      echo "kubernetes-k3s-validation-ok"
      return
    fi
    if [[ "$_phase" == "Failed" || "$_phase" == "Succeeded" ]]; then
      break
    fi
    sleep 2
  done

  docker exec "$_kubernetes_k3s_name" kubectl describe pod "$_kubernetes_k3s_pod_name" >&2 || true
  docker exec "$_kubernetes_k3s_name" kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp >&2 || true
  __dump_k3s_diagnostics
  exit 1
}

__main "$@"
