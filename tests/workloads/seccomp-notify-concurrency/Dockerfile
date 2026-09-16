ARG BASE_IMAGE=docker.io/library/python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a
FROM ${BASE_IMAGE}

COPY probe.py /usr/local/bin/nscell-ci-seccomp-notify-concurrency-probe
RUN chmod +x /usr/local/bin/nscell-ci-seccomp-notify-concurrency-probe

ENTRYPOINT ["nscell-ci-seccomp-notify-concurrency-probe"]
