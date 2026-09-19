ARG BASE_IMAGE=docker.io/library/python:3.14-alpine@sha256:016508ba505da24f7139765bc4bb669df4e88eb2f12eeadd571bf2f88d7533df
FROM ${BASE_IMAGE}

COPY probe.py /usr/local/bin/nscell-ci-seccomp-notify-concurrency-probe
RUN chmod +x /usr/local/bin/nscell-ci-seccomp-notify-concurrency-probe

ENTRYPOINT ["nscell-ci-seccomp-notify-concurrency-probe"]
