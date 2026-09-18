ARG BASE_IMAGE=docker.io/library/docker:29.8.1-dind
FROM ${BASE_IMAGE}

COPY smoke.sh /usr/local/bin/nscell-ci-docker-in-docker-smoke
RUN chmod +x /usr/local/bin/nscell-ci-docker-in-docker-smoke
