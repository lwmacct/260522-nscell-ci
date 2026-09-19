ARG BASE_IMAGE=docker.io/library/python:3.14.4-alpine3.23
FROM ${BASE_IMAGE}

COPY probe.sh /usr/local/bin/nscell-ci-container-security-policy-probe
RUN apk add --no-cache strace && chmod +x /usr/local/bin/nscell-ci-container-security-policy-probe

CMD ["/bin/sleep", "3600"]
