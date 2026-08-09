ARG BASE_IMAGE=docker.io/library/python:3.12-alpine
FROM ${BASE_IMAGE}

RUN apk add --no-cache build-base

COPY probe.py /usr/local/bin/nscell-ci-procfs-memory-probe

CMD ["python3", "/usr/local/bin/nscell-ci-procfs-memory-probe"]
