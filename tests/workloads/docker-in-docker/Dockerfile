ARG BASE_IMAGE=docker.io/library/docker:29.8.1-dind
FROM ${BASE_IMAGE}

RUN apk add --no-cache jq
COPY smoke.sh /usr/local/bin/nscell-ci-docker-in-docker-smoke
COPY thermal-mask.sh /usr/local/bin/nscell-ci-docker-in-docker-thermal-mask
RUN chmod +x /usr/local/bin/nscell-ci-docker-in-docker-smoke /usr/local/bin/nscell-ci-docker-in-docker-thermal-mask
