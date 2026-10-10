#!/bin/bash
# Build-time compatibility layer for running the sandbox as a non-root
# platform user (apps=6000, app=6001). Runs as root inside the image.
# 1. create the platform users so getent/su/chown resolve at runtime
# 2. pre-create every path the stock entrypoint creates as root, with
#    permissive modes
# 3. make the trees the entrypoint renders configs into writable
# 4. patch the entrypoint scripts (see patch-entrypoints.sh)
set -euo pipefail

GEM_DIR="${1:-/opt/gem}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- platform users ---
getent group apps >/dev/null 2>&1 || groupadd -g 6000 apps
id -u apps        >/dev/null 2>&1 || useradd -u 6000 -g 6000 -m -s /bin/bash apps
getent group app  >/dev/null 2>&1 || groupadd -g 6001 app
id -u app         >/dev/null 2>&1 || useradd -u 6001 -g 6001 -m -s /bin/bash app

# --- runtime dirs that stock scripts create as root ---
install -d -m 0777 /var/run/gem
install -d -m 1777 /var/log/gem
install -d -m 0777 /var/lib/aio-sandbox
install -d -m 0777 /var/lib/aio-sandbox/nginx
for d in body proxy fastcgi scgi uwsgi; do
  install -d -m 0777 "/var/lib/aio-sandbox/nginx/$d"
done
install -d -m 1777 /var/lib/nginx
install -d -m 0700 -o apps -g apps /run/user/6000
install -d -m 0700 -o app  -g app  /run/user/6001
install -d -m 0777 /etc/browser/policies/managed

# --- trees the runtime stage writes rendered configs into ---
chmod -R a+rwX /opt/gem /opt/aio /opt/jupyter

# --- entrypoint script patches ---
bash "$SCRIPT_DIR/patch-entrypoints.sh" "$GEM_DIR"

echo "[nonroot-compat] done"
