ARG BASE_IMAGE=docker.io/library/python:3.12-alpine
FROM ${BASE_IMAGE}

COPY probe.py /usr/local/bin/nscell-ci-procfs-cpu-probe

CMD ["python3", "/usr/local/bin/nscell-ci-procfs-cpu-probe"]
