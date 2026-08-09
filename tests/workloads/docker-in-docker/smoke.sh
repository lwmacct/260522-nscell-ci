#!/bin/sh
set -eu

__main() {
	_driver="$(docker info --format '{{.Driver}}')"
	if [ "$_driver" != overlay2 ]; then
		echo "unexpected inner Docker storage driver: $_driver" >&2
		exit 1
	fi
	docker info --format '{{.ServerVersion}} {{.Architecture}} {{.Driver}}'
}

__main "$@"
