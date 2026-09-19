ARG BASE_IMAGE=docker.io/library/python:3.14-alpine@sha256:016508ba505da24f7139765bc4bb669df4e88eb2f12eeadd571bf2f88d7533df
FROM ${BASE_IMAGE}

COPY probe.sh /usr/local/bin/nscell-ci-container-security-policy-probe
RUN apk add --no-cache strace && chmod +x /usr/local/bin/nscell-ci-container-security-policy-probe

CMD ["/bin/sleep", "3600"]
