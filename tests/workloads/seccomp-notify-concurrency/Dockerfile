ARG BASE_IMAGE=docker.io/library/python:3.12-alpine
FROM ${BASE_IMAGE}

COPY probe.py /usr/local/bin/nscell-ci-seccomp-notify-concurrency-probe
RUN chmod +x /usr/local/bin/nscell-ci-seccomp-notify-concurrency-probe

ENTRYPOINT ["nscell-ci-seccomp-notify-concurrency-probe"]
