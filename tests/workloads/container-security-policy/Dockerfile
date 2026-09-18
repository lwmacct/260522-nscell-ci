ARG BASE_IMAGE=docker.io/library/python:3.12-alpine@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a
FROM ${BASE_IMAGE}

COPY probe.sh /usr/local/bin/nscell-ci-container-security-policy-probe
COPY thermal-mask.sh /usr/local/bin/nscell-ci-container-security-policy-thermal-mask
RUN apk add --no-cache strace jq runc && \
  chmod +x \
    /usr/local/bin/nscell-ci-container-security-policy-probe \
    /usr/local/bin/nscell-ci-container-security-policy-thermal-mask

CMD ["/bin/sleep", "3600"]
