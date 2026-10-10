#!/bin/bash
# Entrypoint wrapper for non-root operation.
#
# The stock image assumes root startup: run.sh creates the sandbox user at
# runtime. Here the platform starts us directly as apps(6000)/app(6001),
# so derive USER/USER_UID/USER_GID from the real uid before handing over
# to the stock bootstrap. Root startup is passed through unchanged.
set -euo pipefail

CUR_UID="$(id -u)"
if [ "${CUR_UID}" != "0" ]; then
  CUR_GID="$(id -g)"
  CUR_USER="$(getent passwd "${CUR_UID}" 2>/dev/null | cut -d: -f1 || true)"
  if [ -z "${CUR_USER}" ]; then
    echo "ERROR: uid ${CUR_UID} has no passwd entry in this image." \
         "Supported non-root uids: 6000 (apps), 6001 (app)." >&2
    exit 1
  fi
  export USER="${AIO_USER:-${CUR_USER}}"
  export USER_UID="${CUR_UID}"
  export USER_GID="${CUR_GID}"
  export HOME="/home/${USER}"
fi

exec /opt/gem/run.sh
