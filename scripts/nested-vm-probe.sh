#!/usr/bin/env bash
set -euo pipefail

_log_dir="${PROBE_LOG_DIR:-/tmp/nested-vm-probe}"
_summary="${_log_dir}/summary.log"
_qemu_log="${_log_dir}/qemu.log"
_work_dir=""

__cleanup() {
	if [[ -n "$_work_dir" ]]; then
		rm -rf -- "$_work_dir"
	fi
}

__log() {
	printf '\n==> %s\n' "$*" | tee -a "$_summary"
}

__probe_host_kvm() {
	__log "host virtualization"
	{
		id
		uname -a
		systemd-detect-virt || true
		grep -m1 -E '\b(vmx|svm)\b' /proc/cpuinfo
		if [[ ! -c /dev/kvm ]]; then
			modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
		fi
		ls -l /dev/kvm
		qemu-system-x86_64 --version | head -1
		qemu-system-x86_64 -accel help
	} 2>&1 | tee -a "$_summary"

	test -c /dev/kvm
}

__find_guest_kernel() {
	local _kernel

	_kernel="$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -print | sort -V | tail -1)"
	if [[ -z "$_kernel" ]]; then
		echo "no guest kernel found below /boot" >&2
		return 1
	fi
	printf '%s\n' "$_kernel"
}

__build_guest_initramfs() {
	local _root="$1"
	local _busybox

	_busybox="$(command -v busybox)"
	mkdir -p "${_root}/bin" "${_root}/dev" "${_root}/proc" "${_root}/sys"
	cp "$_busybox" "${_root}/bin/busybox"
	cat >"${_root}/init" <<'EOF'
#!/bin/busybox sh

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mkdir -p /sys/kernel/security /sys/fs/bpf

echo "nscell-nested-vm-probe-start"
/bin/busybox uname -a

_failed=0
if ! /bin/busybox mount -t securityfs securityfs /sys/kernel/security; then
	echo "securityfs-mount-failed"
	_failed=1
fi
if ! /bin/busybox mount -t bpf bpf /sys/fs/bpf; then
	echo "bpffs-mount-failed"
	_failed=1
fi
if [[ -r /sys/kernel/security/lsm ]]; then
	_lsm="$(/bin/busybox cat /sys/kernel/security/lsm)"
	echo "active-lsm=${_lsm}"
	if ! echo "$_lsm" | /bin/busybox grep -qw bpf; then
		echo "bpf-lsm-inactive"
		_failed=1
	fi
else
	echo "active-lsm-unavailable"
	_failed=1
fi
if [[ -r /sys/kernel/btf/vmlinux ]]; then
	echo "kernel-btf=available"
else
	echo "kernel-btf=unavailable"
	_failed=1
fi
if /bin/busybox mount | /bin/busybox grep -q ' on /sys/fs/bpf type bpf '; then
	echo "bpffs=mounted"
else
	echo "bpffs=unavailable"
	_failed=1
fi

if [[ "$_failed" == "0" ]]; then
	echo "nscell-nested-vm-bpf-lsm-ok"
else
	echo "nscell-nested-vm-bpf-lsm-failed"
fi

/bin/busybox sync
/bin/busybox poweroff -f
EOF
	chmod 0755 "${_root}/init"
	(
		cd "$_root"
		find . -print0 | cpio --null -o --format=newc
	) | gzip -9 >"${_work_dir}/initramfs.img"
}

__boot_guest() {
	local _kernel="$1"
	local _kernel_version="${_kernel##*/vmlinuz-}"
	local _kernel_config="/boot/config-${_kernel_version}"

	__log "guest kernel"
	{
		echo "kernel=${_kernel}"
		grep -E '^CONFIG_(BPF_LSM|DEBUG_INFO_BTF|SECURITYFS)=' "$_kernel_config"
		grep -qx 'CONFIG_BPF_LSM=y' "$_kernel_config"
		grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$_kernel_config"
		grep -qx 'CONFIG_SECURITYFS=y' "$_kernel_config"
	} 2>&1 | tee -a "$_summary"

	__log "KVM guest boot"
	set +e
	timeout 120s qemu-system-x86_64 \
		-machine q35 \
		-accel kvm \
		-cpu host \
		-smp 1 \
		-m 512M \
		-kernel "$_kernel" \
		-initrd "${_work_dir}/initramfs.img" \
		-append "console=ttyS0 rdinit=/init panic=-1 lsm=lockdown,capability,landlock,yama,apparmor,bpf" \
		-nographic \
		-no-reboot \
		-monitor none >"$_qemu_log" 2>&1
	_qemu_status=$?
	set -e

	tee -a "$_summary" <"$_qemu_log"
	if ! grep -q '^nscell-nested-vm-bpf-lsm-ok$' < <(tr -d '\r' <"$_qemu_log"); then
		echo "guest did not report successful BPF LSM probe (qemu status ${_qemu_status})" >&2
		return 1
	fi
	if [[ "$_qemu_status" != "0" ]]; then
		echo "qemu exited with status ${_qemu_status} after guest poweroff" | tee -a "$_summary"
	fi
}

__main() {
	local _kernel

	if [[ "$(uname -m)" != "x86_64" ]]; then
		echo "nested VM probe currently supports x86_64 only" >&2
		exit 2
	fi

	install -d -m 0755 "$_log_dir"
	: >"$_summary"
	_work_dir="$(mktemp -d "${_log_dir}/work.XXXXXX")"
	trap __cleanup EXIT

	__probe_host_kvm
	_kernel="$(__find_guest_kernel)"
	__build_guest_initramfs "${_work_dir}/root"
	__boot_guest "$_kernel"

	printf '\nnested-vm-probe-ok\n' | tee -a "$_summary"
}

__main "$@"
