ARG BASE_IMAGE=docker.io/library/python:3.14.4-alpine3.23
FROM ${BASE_IMAGE}

COPY probe.py /usr/local/bin/nscell-ci-procfs-cpu-probe
RUN chmod +x /usr/local/bin/nscell-ci-procfs-cpu-probe

CMD ["/usr/local/bin/nscell-ci-procfs-cpu-probe"]
