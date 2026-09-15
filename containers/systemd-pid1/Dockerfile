# syntax=docker/dockerfile:1

FROM docker.io/library/ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ARG IMAGE_CHANNEL=systemd-pid1
ARG VCS_REF=unknown

ENV container=docker
STOPSIGNAL SIGRTMIN+3

RUN <<'RUN_EOF'
set -eux

__main() {
	apt-get update
	apt-get install --no-install-recommends -y \
		ca-certificates \
		cron \
		curl \
		dbus \
		dbus-user-session \
		iproute2 \
		kmod \
		less \
		locales \
		openssh-server \
		procps \
		rsyslog \
		systemd \
		systemd-sysv \
		sudo \
		udev \
		vim-tiny
	apt-get clean
	rm -rf /var/lib/apt/lists/*
	install -d -m 0755 /work /run/sshd
	systemctl set-default multi-user.target
	systemctl mask \
		dev-hugepages.mount \
		sys-fs-fuse-connections.mount \
		systemd-firstboot.service \
		systemd-hwdb-update.service \
		systemd-journal-flush.service \
		systemd-machine-id-commit.service \
		systemd-modules-load.service \
		systemd-remount-fs.service \
		systemd-sysusers.service \
		systemd-tmpfiles-setup-dev.service \
		systemd-udev-trigger.service \
		systemd-udevd.service
	systemctl disable ssh.socket
	systemctl enable ssh.service cron.service rsyslog.service
}

__main "$@"
RUN_EOF

VOLUME ["/sys/fs/cgroup"]
CMD ["/usr/bin/systemd"]

LABEL org.opencontainers.image.source="https://github.com/lwmacct/260522-nscell-ci" \
	org.opencontainers.image.description="Ubuntu 26.04 systemd PID 1 workload base" \
	org.opencontainers.image.version="${IMAGE_CHANNEL}" \
	org.opencontainers.image.revision="${VCS_REF}"
