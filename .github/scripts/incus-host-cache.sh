#!/usr/bin/env bash

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../.." && pwd)"
_package_file="${_repo_root}/.github/incus-host/packages.txt"
_cache_version_file="${_repo_root}/.github/incus-host/cache-version"

__die() {
	printf 'incus host cache: %s\n' "$1" >&2
	return 1
}

__require_command() {
	local _command="$1"

	command -v "${_command}" >/dev/null || __die "missing command: ${_command}"
}

__image_version() {
	local _path _value

	for _path in \
		/imagegeneration/IMAGE_VERSION \
		/imagegeneration/IMAGE_VERSION.txt \
		/opt/hostedtoolcache/IMAGE_VERSION; do
		if [[ -s "${_path}" ]]; then
			_value="$(<"${_path}")"
			printf '%s' "${_value//[$'\r\n']/}"
			return
		fi
	done

	for _value in "${ImageVersion:-}" "${IMAGE_VERSION:-}"; do
		if [[ -n "${_value}" ]]; then
			printf '%s' "${_value}"
			return
		fi
	done

	printf '%s' unknown
}

__installed_package_manifest() {
	dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' |
		awk -F '\t' '$3 == "installed" { print $1 "\t" $2 }' |
		LC_ALL=C sort
}

__package_manifest_hash() {
	__installed_package_manifest | sha256sum | awk '{print $1}'
}

__base_fingerprint() {
	local _systemd_version

	if command -v systemd >/dev/null 2>&1; then
		_systemd_version="$(systemd --version)"
	else
		_systemd_version=unknown
	fi
	{
		printf 'cache-version='; cat "${_cache_version_file}"
		printf '\nrecipe='; sha256sum "${_package_file}" | awk '{print $1}'
		printf '\nscript='; sha256sum "${_script_dir}/incus-host-cache.sh" | awk '{print $1}'
		printf 'image-version='; __image_version
		printf '\nos-release='; cat /etc/os-release
		printf 'architecture='; dpkg --print-architecture
		printf '\nuname='; uname -srvm
		printf '\nsystemd=%s' "${_systemd_version%%$'\n'*}"
		printf '\npackages='; __package_manifest_hash
	} | sha256sum | awk '{print $1}'
}

__cache_key() {
	local _fingerprint _version

	_fingerprint="$(__base_fingerprint)"
	_version="$(tr -d '[:space:]' < "${_cache_version_file}")"
	[[ "${_version}" =~ ^[0-9]+$ ]] || __die "invalid cache version"
	printf 'incus-host-v%s-%s-%s-%s\n' \
		"${_version}" "$(dpkg --print-architecture)" "${_fingerprint}" \
		"$(uname -r | tr '/ ' '__')"
}

__write_key_output() {
	local _output_file="${1:-}"
	local _fingerprint _key _cache_enabled _image_version

	_image_version="$(__image_version)"
	_fingerprint="$(__base_fingerprint)"
	if [[ "${_image_version}" == unknown ]]; then
		_cache_enabled=false
		_key="incus-host-disabled-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}"
	else
		_cache_enabled=true
		_key="$(__cache_key)"
	fi
	if [[ -n "${_output_file}" ]]; then
		{
			printf 'cache_enabled=%s\n' "${_cache_enabled}"
			printf 'base_fingerprint=%s\n' "${_fingerprint}"
			printf 'cache_key=%s\n' "${_key}"
		} > "${_output_file}"
	else
		printf 'cache_enabled=%s\n' "${_cache_enabled}"
		printf 'base_fingerprint=%s\n' "${_fingerprint}"
		printf 'cache_key=%s\n' "${_key}"
	fi
}

__configure_zabbly_source() {
	local _architecture _codename

	sudo install -d -m 0755 /etc/apt/keyrings
	sudo curl -fsSL https://pkgs.zabbly.com/key.asc \
		-o /etc/apt/keyrings/zabbly.asc
	_codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")"
	_architecture="$(dpkg --print-architecture)"
	sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.sources >/dev/null <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${_codename}
Components: main
Architectures: ${_architecture}
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
}

__install_packages() {
	local _repair="${1:-false}"
	local -a _packages=()

	mapfile -t _packages < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${_package_file}")
	((${#_packages[@]} > 0)) || __die "empty package recipe"
	__configure_zabbly_source
	sudo apt-get update
	if [[ "${_repair}" == true || "${_repair}" == repair ]]; then
		sudo apt-get install --yes --no-install-recommends --reinstall \
			"${_packages[@]}"
	else
		sudo apt-get install --yes --no-install-recommends "${_packages[@]}"
	fi
	apt-cache policy incus | grep -F \
		'https://pkgs.zabbly.com/incus/stable' >/dev/null
}

__tar_excludes() {
	cat <<'EOF'
--exclude=./dev
--exclude=./proc
--exclude=./sys
--exclude=./run
--exclude=./tmp
--exclude=./home
--exclude=./mnt
--exclude=./media
--exclude=./lost+found
--exclude=./var/cache/apt
--exclude=./var/cache/man
--exclude=./var/cache/ldconfig
--exclude=./var/cache/private
--exclude=./var/cache/fontconfig
--exclude=./var/lib/apt
--exclude=./var/lib/incus
--exclude=./var/lib/incus-lxcfs
--exclude=./var/lib/systemd
--exclude=./var/lib/NetworkManager
--exclude=./var/lib/dhcp
--exclude=./var/lib/cloud
--exclude=./var/lib/private
--exclude=./var/log
--exclude=./var/tmp
--exclude=./opt/hostedtoolcache
--exclude=./actions
--exclude=./etc/hostname
--exclude=./etc/hosts
--exclude=./etc/resolv.conf
--exclude=./etc/machine-id
--exclude=./etc/passwd
--exclude=./etc/group
--exclude=./etc/shadow
--exclude=./etc/gshadow
--exclude=./etc/subuid
--exclude=./etc/subgid
--exclude=./etc/sudoers
--exclude=./etc/sudoers.d
--exclude=./etc/ssh/ssh_host_*
--exclude=./var/lib/dbus/machine-id
--exclude=./var/lib/systemd/random-seed
EOF
}

__tar_arguments() {
	local _exclude

	while IFS= read -r _exclude; do
		printf '%s\n' "${_exclude}"
	done < <(__tar_excludes)
}

__tar_roots() {
	printf '%s\n' \
		./etc \
		./usr \
		./lib \
		./lib64 \
		./bin \
		./sbin \
		./opt \
		./var/lib \
		./var/cache/debconf
}

__snapshot() {
	local _snapshot_file="$1"
	local -a _tar_args=() _tar_roots=()

	__require_command tar
	mapfile -t _tar_args < <(__tar_arguments)
	mapfile -t _tar_roots < <(__tar_roots)
	sudo tar --create --file=/dev/null \
		--directory=/ --one-file-system \
		--listed-incremental="${_snapshot_file}" \
		--xattrs --acls --selinux --numeric-owner \
		"${_tar_args[@]}" "${_tar_roots[@]}"
}

__build_delta() {
	local _snapshot_file="$1" _output_dir="$2" _base_file="$3"
	local _layer_file="${_output_dir}/layer.tar"
	local _manifest_file="${_output_dir}/manifest"
	local _base_fingerprint _key _post_hash _layer_hash
	local -a _tar_args=() _tar_roots=()

	[[ -s "${_base_file}" ]] || __die "missing base fingerprint file"
	# shellcheck disable=SC1090
	source "${_base_file}"
	[[ -n "${base_fingerprint:-}" && -n "${cache_key:-}" ]] ||
		__die "invalid base fingerprint file"
	_base_fingerprint="${base_fingerprint}"
	_key="${cache_key}"

	mapfile -t _tar_args < <(__tar_arguments)
	mapfile -t _tar_roots < <(__tar_roots)
	install -d -m 0755 "${_output_dir}"
	sudo tar --create --file="${_layer_file}" \
		--directory=/ --one-file-system \
		--listed-incremental="${_snapshot_file}" \
		--xattrs --acls --selinux --numeric-owner \
		"${_tar_args[@]}" "${_tar_roots[@]}"
	sudo chown "$(id -u):$(id -g)" "${_layer_file}"
	_post_hash="$(__package_manifest_hash)"
	_layer_hash="$(sha256sum "${_layer_file}" | awk '{print $1}')"
	{
		printf 'schema=1\n'
		printf 'base_fingerprint=%s\n' "${_base_fingerprint}"
		printf 'cache_key=%s\n' "${_key}"
		printf 'post_packages_sha256=%s\n' "${_post_hash}"
		printf 'layer_sha256=%s\n' "${_layer_hash}"
	} > "${_manifest_file}"

	__validate_archive "${_layer_file}"
	printf 'layer=%s\n' "${_layer_file}"
	printf 'manifest=%s\n' "${_manifest_file}"
}

__manifest_value() {
	local _manifest_file="$1" _name="$2"

	awk -F= -v _name="${_name}" '$1 == _name { print substr($0, length(_name) + 2); exit }' \
		"${_manifest_file}"
}

__validate_archive() {
	local _layer_file="$1" _member

	[[ -s "${_layer_file}" ]] || __die "empty host layer"
	while IFS= read -r _member; do
		[[ "${_member}" != /* && "${_member}" != *../* ]] ||
			__die "host layer contains an unsafe member: ${_member}"
		case "${_member}" in
			./|./etc|./etc/*|./usr|./usr/*|./lib|./lib/*|./lib64|./lib64/*|./bin|./bin/*|./sbin|./sbin/*|./opt|./opt/*|./var|./var/|./var/cache|./var/cache/|./var/cache/debconf|./var/cache/debconf/*|./var/lib|./var/lib/|./var/lib/*)
				;;
			*)
				__die "host layer contains disallowed member: ${_member}"
				;;
		esac
	done < <(tar --list --file="${_layer_file}")
}

__restore() {
	local _cache_dir="$1"
	local _layer_file="${_cache_dir}/layer.tar"
	local _manifest_file="${_cache_dir}/manifest"
	local _expected_base _actual_base _expected_key _actual_key
	local _expected_layer _actual_layer _expected_packages _actual_packages

	[[ -s "${_manifest_file}" && -s "${_layer_file}" ]] ||
		__die "host layer cache is incomplete"
	[[ "$(__manifest_value "${_manifest_file}" schema)" == 1 ]] ||
		__die "unsupported host layer schema"
	_expected_base="$(__manifest_value "${_manifest_file}" base_fingerprint)"
	_expected_key="$(__manifest_value "${_manifest_file}" cache_key)"
	_expected_layer="$(__manifest_value "${_manifest_file}" layer_sha256)"
	_expected_packages="$(__manifest_value "${_manifest_file}" post_packages_sha256)"
	_actual_base="$(__base_fingerprint)"
	_actual_key="$(__cache_key)"
	_actual_layer="$(sha256sum "${_layer_file}" | awk '{print $1}')"

	[[ "${_actual_base}" == "${_expected_base}" ]] ||
		__die "runner base fingerprint mismatch"
	[[ "${_actual_key}" == "${_expected_key}" ]] ||
		__die "cache key mismatch"
	[[ "${_actual_layer}" == "${_expected_layer}" ]] ||
		__die "host layer checksum mismatch"
	__validate_archive "${_layer_file}"

	sudo tar --extract --incremental --file="${_layer_file}" --directory=/ \
		--xattrs --acls --selinux --numeric-owner --same-owner \
		--preserve-permissions \
		--delay-directory-restore
	sudo systemd-sysusers >/dev/null
	sudo systemd-tmpfiles --create >/dev/null
	sudo ldconfig
	_actual_packages="$(__package_manifest_hash)"
	[[ "${_actual_packages}" == "${_expected_packages}" ]] ||
		__die "installed package manifest mismatch after restore"
	sudo dpkg --audit
	command -v incus >/dev/null || __die "incus command missing after restore"
	command -v qemu-system-x86_64 >/dev/null || __die "QEMU command missing after restore"
}

__ensure_forward_rule() {
	local _chain="$1"
	shift

	if sudo iptables --wait 5 --check "${_chain}" "$@" 2>/dev/null; then
		return
	fi
	sudo iptables --wait 5 --insert "${_chain}" 1 "$@"
}

__initialize() {
	local _forward_chain=FORWARD
	local _ipv4_address _ipv4_nat

	sudo systemctl daemon-reload
	sudo systemctl enable --now incus.socket
	sudo incus admin waitready
	sudo incus admin init --minimal

	if sudo iptables --wait 5 --numeric --list DOCKER-USER >/dev/null 2>&1; then
		_forward_chain=DOCKER-USER
	fi
	__ensure_forward_rule "${_forward_chain}" \
		--in-interface incusbr0 \
		--jump ACCEPT
	__ensure_forward_rule "${_forward_chain}" \
		--out-interface incusbr0 \
		--match conntrack \
		--ctstate RELATED,ESTABLISHED \
		--jump ACCEPT

	test "$(sudo sysctl -n net.ipv4.ip_forward)" = 1
	_ipv4_address="$(sudo incus network get incusbr0 ipv4.address)"
	_ipv4_nat="$(sudo incus network get incusbr0 ipv4.nat)"
	test -n "${_ipv4_address}"
	test "${_ipv4_address}" != none
	test "${_ipv4_nat}" = true
	test -c /dev/kvm
	sudo incus version
	sudo incus network show incusbr0
}

__verify() {
	local _package _status
	local -a _packages=()

	mapfile -t _packages < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${_package_file}")
	sudo dpkg --audit
	for _package in "${_packages[@]}"; do
		_status="$(dpkg-query -W -f='${db:Status-Status}' "${_package}" 2>/dev/null || true)"
		[[ "${_status}" == installed ]] || __die "package is not installed: ${_package}"
	done
	sudo incus admin waitready
	sudo incus version
	sudo incus network get incusbr0 ipv4.nat | grep -qx true
	qemu-system-x86_64 --version | head -n1
	test -c /dev/kvm
}

__key() {
	local _output_file="${1:-}"

	__write_key_output "${_output_file}"
}

__install() {
	__install_packages "${2:-false}"
}

__main() {
	local _command="${1:-}"

	case "${_command}" in
		key)
			__key "${2:-}"
			;;
		install)
			__install "$@"
			;;
		snapshot)
			__snapshot "$2"
			;;
		build-delta)
			__build_delta "$2" "$3" "$4"
			;;
		restore)
			__restore "$2"
			;;
		initialize)
			__initialize
			;;
		verify)
			__verify
			;;
		*)
			printf 'usage: %s {key|install|snapshot|build-delta|restore} ...\n' "$0" >&2
			return 2
			;;
	esac
}

__main "$@"
