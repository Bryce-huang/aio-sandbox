# aio-sandbox with non-root support (platform users: apps=6000, app=6001).
# Derived from the official agent-infra sandbox image; all changes are
# build-time (users, directory permissions, entrypoint patches).
# CI passes BASE_TAG=<latest upstream release>; default pins 1.11.0.
ARG BASE_TAG=1.11.0
FROM ghcr.io/agent-infra/sandbox:${BASE_TAG}

COPY docker/aio-entrypoint.sh /usr/local/bin/aio-entrypoint.sh
COPY docker/patch-entrypoints.sh /tmp/patch-entrypoints.sh
COPY docker/nonroot-compat.sh /tmp/nonroot-compat.sh

RUN bash /tmp/nonroot-compat.sh && rm -f /tmp/nonroot-compat.sh /tmp/patch-entrypoints.sh

ENTRYPOINT ["/usr/local/bin/aio-entrypoint.sh"]
