#!/bin/sh
# Runs inside the Docker-in-Docker container: every command below is an inner
# runtime operation that NSCell mediates, so this is where "a container may use
# its own world" is asserted (bind, named volume, tmpfs, build, --privileged,
# explicit /run share) together with the operations that must stay refused
# (kernel views, a device node bound outside the caller's own /dev, paths that
# only exist on the CI host).
set -eu

__fail() {
	echo "dind-smoke: $1" >&2
	exit 1
}

__assert_output() {
	local _label="$1" _want="$2" _got="$3"
	if [ "$_got" != "$_want" ]; then
		__fail "${_label}: got '${_got}', want '${_want}'"
	fi
	echo "dind-ok ${_label}"
}

__assert_refused() {
	local _label="$1"
	shift
	if "$@" >"/tmp/dind-refused.out" 2>&1; then
		__fail "${_label} was allowed"
	fi
	echo "dind-refused ${_label}"
}

# __privileged_probe succeeds only inside a privileged inner container: it keeps
# CAP_SYS_ADMIN (bit 21) and gets the /dev entry Docker adds to its rootfs.
#
# It deliberately runs no mount(8). A nested mount(8) of this image goes through
# the new mount API, which NSCell answers with a capability proxy fd; that path is
# outside what this workload asserts.
__privileged_probe='_eff=$(tr -d " \t" </proc/self/status | grep "^CapEff:" | cut -d: -f2); [ "$(( 0x${_eff} & 0x200000 ))" -ne 0 ] && test -c /dev/kmsg && printf nscell-dind-privileged-ok'

__check_mounts() {
	local _image="$1" _src="$2"

	# A directory of this container's world, bound read-only into an inner
	# container (the `docker run -v <dir>:<dir>` shape).
	__assert_output "bind-directory" "nscell-dind-bind-ok" \
		"$(docker run --rm -v "${_src}:/probe:ro" "$_image" cat /probe/marker)"

	# A single file of this container's world bound over a file in the inner
	# container's rootfs.
	__assert_output "bind-file" "nscell-dind-bind-ok" \
		"$(docker run --rm -v "${_src}/marker:/probe-marker:ro" "$_image" cat /probe-marker)"

	# A named volume: created by the inner daemon, written through one container
	# and read back through another.
	docker volume rm -f dind-smoke-volume >/dev/null 2>&1 || true
	docker volume create dind-smoke-volume >/dev/null
	docker run --rm -v dind-smoke-volume:/volume "$_image" \
		sh -c 'printf nscell-dind-volume-ok > /volume/marker'
	__assert_output "named-volume" "nscell-dind-volume-ok" \
		"$(docker run --rm -v dind-smoke-volume:/volume "$_image" cat /volume/marker)"
	docker volume rm -f dind-smoke-volume >/dev/null

	# `--tmpfs` on a target that only exists inside the inner container.
	__assert_output "tmpfs" "nscell-dind-tmpfs-ok" \
		"$(docker run --rm --tmpfs /probe-tmp:size=1m,mode=1777 "$_image" \
			sh -c 'printf nscell-dind-tmpfs-ok > /probe-tmp/marker && cat /probe-tmp/marker')"

	# An explicit, operator-authorized share of this container's /run: the inner
	# container sees this world's Docker socket, which is the socket scenario the
	# outer spec has to authorize on purpose.
	__assert_output "run-share" "nscell-dind-run-ok" \
		"$(docker run --rm -v /run:/host-run "$_image" \
			sh -c '[ -S /host-run/docker.sock ] && printf nscell-dind-run-ok')"

	# `--privileged`: the inner container keeps CAP_SYS_ADMIN and the /dev entry
	# Docker adds to its rootfs. An unprivileged container has neither (see
	# __check_refusals).
	__assert_output "privileged" "nscell-dind-privileged-ok" \
		"$(docker run --rm --privileged "$_image" sh -c "$__privileged_probe")"
}

__check_build() {
	local _image="$1" _context

	# A real build: the builder creates a container from this world, runs the step
	# in it and commits the result.
	#
	# DOCKER_BUILDKIT=0 is deliberate. BuildKit's client cannot hand its
	# Dockerfile to the daemon from inside an nscell container (the session
	# transfer arrives as 2B and the daemon then reports "failed to read
	# dockerfile"), and its build executor mounts /proc at
	# /var/lib/docker/buildkit/executor/<id>/rootfs, a path the ProcView
	# capability does not cover. Both happen before or outside the mount shapes
	# this workload asserts, so the build assertion uses the classic builder,
	# which exercises the same mediated mounts (rootfs overlay, /proc, tmpfs,
	# binds) inside the build container.
	_context="$(mktemp -d)"
	printf 'FROM %s\nRUN printf nscell-dind-build-ok > /built\n' "$_image" >"${_context}/Dockerfile"
	DOCKER_BUILDKIT=0 docker build --quiet --tag dind-smoke-build "${_context}" >/dev/null
	__assert_output "build" "nscell-dind-build-ok" \
		"$(docker run --rm --entrypoint cat dind-smoke-build /built)"
	docker image rm -f dind-smoke-build >/dev/null 2>&1 || true
	rm -rf "$_context"
}

__check_refusals() {
	local _image="$1"

	# NSCell owns /proc and /sys; they are never bind operands, not even a
	# container's own view of them.
	__assert_refused "proc-bind" docker run --rm -v /proc:/host-proc "$_image" true
	__assert_refused "sys-bind" docker run --rm -v /sys/kernel:/host-sys "$_image" true

	# A device node is not a general bind source: only an entry of this
	# container's own /dev may be handed to an inner container's /dev.
	__assert_refused "device-node-source" docker run --rm -v /dev/null:/probe-null "$_image" true

	# A path that exists on the CI host is not that path here: the inner runtime
	# creates the bind source inside this container's own world, so the inner
	# container sees an empty directory instead of the host's $HOME. Only the
	# outer creation-time spec can hand a real host path in.
	__assert_output "host-path-not-shared" "nscell-dind-host-path-ok" \
		"$(docker run --rm -v /home/runner:/probe-host "$_image" \
			sh -c '[ -z "$(ls -A /probe-host)" ] && printf nscell-dind-host-path-ok')"

	# The privileged probe is a privilege probe, not a tautology: an ordinary
	# inner container fails it.
	__assert_refused "unprivileged-caps" docker run --rm "$_image" sh -c "$__privileged_probe"
}

__main() {
	local _driver _image _src

	_driver="$(docker info --format '{{.Driver}}')"
	if [ "$_driver" != overlay2 ]; then
		echo "unexpected inner Docker storage driver: $_driver" >&2
		exit 1
	fi
	docker info --format '{{.ServerVersion}} {{.Architecture}} {{.Driver}}'

	_image="${DIND_SMOKE_IMAGE:-}"
	if [ -z "$_image" ]; then
		__fail "DIND_SMOKE_IMAGE is not set"
	fi
	docker image inspect "$_image" >/dev/null

	_src="$(mktemp -d)"
	printf nscell-dind-bind-ok >"${_src}/marker"

	__check_mounts "$_image" "$_src"
	__check_build "$_image"
	__check_refusals "$_image"

	rm -rf "$_src"
	echo "docker-in-docker-smoke-ok"
}

__main "$@"
