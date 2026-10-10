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

log() { echo "[nonroot-compat] $*"; }

# --- platform users ---
getent group apps >/dev/null 2>&1 || groupadd -g 6000 apps
getent group app  >/dev/null 2>&1 || groupadd -g 6001 app
# uid-drift assert: a plain `id -u || useradd` guard silently skips a
# pre-existing user with a conflicting uid (future upstream ship); fail
# loud instead so uid assumptions (6NNN paths, entrypoint mapping) hold.
create_user() {
  local name="$1" uid="$2"
  if id -u "$name" >/dev/null 2>&1; then
    [ "$(id -u "$name")" = "$uid" ] || {
      echo "ERROR: uid drift for $name: expected $uid, found $(id -u "$name")" >&2
      exit 1
    }
    log "= user $name ($uid) already present"
  else
    useradd -u "$uid" -g "$uid" -m -s /bin/bash "$name"
    log "+ user $name ($uid)"
  fi
}
create_user apps 6000
create_user app 6001

# --- runtime dirs that stock scripts create as root ---
install -d -m 0777 /var/run/gem
install -d -m 1777 /var/log/gem
install -d -m 0777 /var/lib/aio-sandbox
install -d -m 0777 /var/lib/aio-sandbox/nginx
for d in body proxy fastcgi scgi uwsgi; do
  install -d -m 0777 "/var/lib/aio-sandbox/nginx/$d"
done
install -d -m 1777 /var/lib/nginx
# /run/user must be world-traversable; GNU install -d would otherwise
# create it 0700 owned by apps, locking app(6001) out of /run/user/6001.
install -d -m 0755 /run/user
install -d -m 0700 -o apps -g apps /run/user/6000
install -d -m 0700 -o app  -g app  /run/user/6001
install -d -m 0777 /etc/browser/policies/managed
log "+ dirs /var/run/gem /var/log/gem /var/lib/{aio-sandbox,nginx}+subdirs (0777/1777)"
log "+ dirs /run/user 0755 (world-traversable), /run/user/{6000,6001} 0700 per-user"
log "+ dirs /etc/browser/policies/managed 0777"

# --- trees the runtime stage writes rendered configs into ---
chmod -R a+rwX /opt/gem /opt/aio /opt/jupyter
log "+ chmod -R a+rwX /opt/gem /opt/aio /opt/jupyter"

# --- entrypoint script patches ---
log "+ patch entrypoints (patch-entrypoints.sh, GEM_DIR=$GEM_DIR)"
bash "$SCRIPT_DIR/patch-entrypoints.sh" "$GEM_DIR"

log "done"
