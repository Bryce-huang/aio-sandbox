#!/bin/bash
# Patch the AIO sandbox entrypoint scripts so the stock root-oriented
# bootstrap also works when the container runs as a non-root uid
# (platform users: apps=6000, app=6001).
#
# Idempotent: every patch is guarded by a post-patch marker; re-running
# is a no-op. Every patch fails loudly if its pattern no longer matches
# (upstream drift), so silent partial patching is impossible.
#
# Usage: patch-entrypoints.sh [GEM_DIR]   (default: /opt/gem)
set -euo pipefail

GEM_DIR="${1:-/opt/gem}"

log() { echo "[patch-entrypoints] $*"; }

# apply <file> <marker> <sed-expr>
#   marker: fixed string that exists ONLY after the patch is applied.
apply() {
  local file="$1" marker="$2" expr="$3"
  if [ ! -f "$file" ]; then
    echo "ERROR: patch target not found: $file" >&2
    exit 1
  fi
  if grep -qF -- "$marker" "$file"; then
    log "= already patched: $file"
    return 0
  fi
  sed -i.bak -e "$expr" "$file"
  rm -f "$file.bak"
  if ! grep -qF -- "$marker" "$file"; then
    echo "ERROR: patch did not apply to $file  expr: $expr" >&2
    exit 1
  fi
  log "+ patched: $file"
}

# del <file> <fixed-string>: remove lines containing the fixed string.
del() {
  local file="$1" pattern="$2"
  if [ ! -f "$file" ]; then
    echo "ERROR: patch target not found: $file" >&2
    exit 1
  fi
  if grep -qF -- "$pattern" "$file"; then
    grep -vF -- "$pattern" "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
    log "+ removed [$pattern] from $file"
  else
    log "= already absent in $file: [$pattern]"
  fi
}

# ---------------- gem_init.sh (trusted init stage) ----------------
# chmod on pre-created root-owned /var/run/gem fails for non-root.
apply "$GEM_DIR/gem_init.sh" \
  'chmod 750 "${RUN_DIR}" 2>/dev/null' \
  's|chmod 750 "${RUN_DIR}"$|chmod 750 "${RUN_DIR}" 2>/dev/null \|\| true|'

# ---------------- gem.sh (runtime stage) ----------------
# Every chown/chmod below targets a path that is root-owned in the image
# and pre-created with permissive modes by nonroot-compat.sh.

# browser supervisor config dir (write_browser_supervisor_config)
apply "$GEM_DIR/gem.sh" \
  'chown "root:${USER}" "${RUN_DIR}" 2>/dev/null' \
  's|chown "root:${USER}" "${RUN_DIR}"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chmod 750 "${RUN_DIR}" 2>/dev/null' \
  's|chmod 750 "${RUN_DIR}"$|& 2>/dev/null \|\| true|'

# browser supervisor config tmp file (write_browser_supervisor_config):
# same root-owned parent; chown/chmod as non-root must not abort the boot.
# Root mode unchanged (both succeed as root); cross-mode restarts are
# covered by gem_init.sh's `rm -f` of the stale config.
apply "$GEM_DIR/gem.sh" \
  'chown "root:${USER}" "${tmp_config}" 2>/dev/null' \
  's|chown "root:\${USER}" "\${tmp_config}"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chmod 640 "${tmp_config}" 2>/dev/null' \
  's|chmod 640 "\${tmp_config}"$|& 2>/dev/null \|\| true|'

# setup_xdg_runtime_dir
apply "$GEM_DIR/gem.sh" \
  'chown $USER:$USER "$XDG_RUNTIME_DIR" 2>/dev/null' \
  's|chown \$USER:\$USER "\$XDG_RUNTIME_DIR"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null' \
  's|chmod 700 "\$XDG_RUNTIME_DIR"$|& 2>/dev/null \|\| true|'

# X11 socket dir cleanup (sticky /tmp forbids deleting root-owned dirs).
# The rm expr exact-matches the known full line so upstream drift fails
# loud instead of silently splicing into a changed line.
apply "$GEM_DIR/gem.sh" \
  'rm -rf /tmp/.X11-unix 2>/dev/null' \
  's|^rm -rf /tmp/.X11-unix  # Clean stale sockets on restart$|rm -rf /tmp/.X11-unix 2>/dev/null \|\| true  # Clean stale sockets on restart|'
# If /tmp/.X11-unix pre-exists root-owned (docker restart on the same
# container), the tolerated rm cannot remove it; mkdir is then a no-op and
# this chmod would EPERM-abort without the guard.
apply "$GEM_DIR/gem.sh" \
  'chmod 1777 /tmp/.X11-unix 2>/dev/null' \
  's|^chmod 1777 /tmp/.X11-unix$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown $USER /tmp/.X11-unix/ 2>/dev/null' \
  's|chown \$USER /tmp/.X11-unix/$|& 2>/dev/null \|\| true|'

# log dir (pre-created 1777, chown/chmod by non-owner must not abort)
apply "$GEM_DIR/gem.sh" \
  'chmod 1777 "$LOG_DIR" 2>/dev/null' \
  's|chmod 1777 "\$LOG_DIR"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown $USER "$LOG_DIR" 2>/dev/null' \
  's|chown \$USER "\$LOG_DIR"$|& 2>/dev/null \|\| true|'

# service state dir + home + downloads + workspace + shutdown hooks
apply "$GEM_DIR/gem.sh" \
  'chown $USER:$USER /var/lib/aio-sandbox 2>/dev/null' \
  's|chown \$USER:\$USER /var/lib/aio-sandbox$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown $USER:$USER "$BROWSER_DOWNLOAD_DIR_EFFECTIVE" 2>/dev/null' \
  's|chown \$USER:\$USER "\$BROWSER_DOWNLOAD_DIR_EFFECTIVE"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown $USER:$USER /home/$USER 2>/dev/null' \
  's|chown \$USER:\$USER /home/\$USER$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown "$USER:$USER" "$WORKSPACE" 2>/dev/null' \
  's|chown "\$USER:\$USER" "\$WORKSPACE"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown $USER:$USER /var/lib/aio-sandbox/shutdown-hooks.json 2>/dev/null' \
  's|chown \$USER:\$USER /var/lib/aio-sandbox/shutdown-hooks.json$|& 2>/dev/null \|\| true|'

# nginx runtime dirs (pre-created 1777/0777 at build time)
apply "$GEM_DIR/gem.sh" \
  'chmod 1777 /var/lib/nginx 2>/dev/null' \
  's|chmod 1777 /var/lib/nginx$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown nobody /var/lib/nginx 2>/dev/null' \
  's|chown nobody /var/lib/nginx$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chmod 755 /var/lib/aio-sandbox "${NGINX_RUNTIME_DIR}" 2>/dev/null' \
  's|chmod 755 /var/lib/aio-sandbox "\${NGINX_RUNTIME_DIR}"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown nobody:root "${NGINX_RUNTIME_DIR}" 2>/dev/null' \
  's|chown nobody:root "\${NGINX_RUNTIME_DIR}"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chown nobody:root "${NGINX_RUNTIME_DIR}/${temp_dir}" 2>/dev/null' \
  's|chown nobody:root "\${NGINX_RUNTIME_DIR}/\${temp_dir}"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chmod 700 "${NGINX_RUNTIME_DIR}/${temp_dir}" 2>/dev/null' \
  's|chmod 700 "\${NGINX_RUNTIME_DIR}/\${temp_dir}"$|& 2>/dev/null \|\| true|'

# jupyter tree
apply "$GEM_DIR/gem.sh" \
  'chown -R $USER:$USER /opt/jupyter 2>/dev/null' \
  's|chown -R \$USER:\$USER /opt/jupyter$|& 2>/dev/null \|\| true|'

# ---------------- browser-supervisor.py ----------------
# Started directly by gem_init.sh as the container uid; two root-only
# operations make it crash-loop as non-root (Popen re-raises preexec
# failures in the parent, so the launch loop retries forever and the
# browser silently never comes up).

# drop_privileges: as uid 6000/6001 the demote() preexec would
# setgroups(2) without CAP_SETGID (EPERM). Already unprivileged means
# there is nothing to drop: return None -> preexec_fn=None (subprocess
# default) and Chrome runs as the current uid. Root mode unchanged.
apply "$GEM_DIR/browser-supervisor.py" \
  'os.geteuid() != 0' \
  '/^    def demote() -> None:$/i\
    if os.geteuid() != 0:\
        return None'

# write_pid_file: chown to uid 0 (root:gid) is EPERM as non-root. Skip
# under non-root — the tmp file already belongs to the current user.
# Root mode unchanged.
apply "$GEM_DIR/browser-supervisor.py" \
  'os.geteuid() == 0' \
  '/^    os.chown(tmp_path, 0, gid)$/c\
    if os.geteuid() == 0:\
        os.chown(tmp_path, 0, gid)'

# user-setup payload: `su - $USER -c` hangs when a non-root user su's to
# itself (PAM password prompt). Export the payload env, then run directly
# when the current uid already is the target uid; keep `su` otherwise so
# root mode is unchanged.
apply "$GEM_DIR/gem.sh" \
  'if [ "$(id -u)" != "${USER_UID}" ]; then su' \
  's|^  su - \$USER -c "|  export AIO_CLI_SKILL_ENABLED="${COPY_SKILLS_TO_USER_HOME}" BROWSER_LANG="${BROWSER_LANG:-en-US}" BROWSER_DOWNLOAD_DIR_EFFECTIVE="${BROWSER_DOWNLOAD_DIR_EFFECTIVE}" OPENCODE_RENDERED="${OPENCODE_RENDERED}" CLAUDE_RENDERED="${CLAUDE_RENDERED}"; if [ "$(id -u)" != "${USER_UID}" ]; then su - $USER -c "|'
apply "$GEM_DIR/gem.sh" \
  'bash -s"; else bash -s; fi << '"'"'EOF'"'"'' \
  "s|bash -s\" << 'EOF'\$|bash -s\"; else bash -s; fi << 'EOF'|"

# ---------------- supervisord configs ----------------
# /opt/gem/supervisord.conf is used by `supervisord -n -c`;
# /etc/supervisord.conf (identical copy) is what `supervisorctl` reads.
# Patch both so the socket/pidfile move stays consistent. Outside the
# sandbox image (e.g. a host supervisord.conf) the file either does not
# exist or does not look like the sandbox conf — skip it. The guard
# string matches both the pre-patch (unix:///var/run/supervisor.sock)
# and post-patch (unix:///var/run/gem/supervisor.sock) forms so the
# already-patched file is still recognized as its own.
for CONF in "$GEM_DIR/supervisord.conf" /etc/supervisord.conf; do
  if [ -f "$CONF" ] && grep -qE 'unix:///var/run/(gem/)?supervisor\.sock' "$CONF"; then
    del "$CONF" 'user=root'
    del "$CONF" 'chown=root:%(ENV_USER)s'
    apply "$CONF" \
      'pidfile=/var/run/gem/supervisord.pid' \
      's|^pidfile=/var/run/supervisord.pid$|pidfile=/var/run/gem/supervisord.pid|'
    apply "$CONF" \
      'file=/var/run/gem/supervisor.sock' \
      's|^file=/var/run/supervisor.sock$|file=/var/run/gem/supervisor.sock|'
    apply "$CONF" \
      'serverurl=unix:///var/run/gem/supervisor.sock' \
      's|^serverurl=unix:///var/run/supervisor.sock$|serverurl=unix:///var/run/gem/supervisor.sock|'
  else
    log "= skipping (missing or not the sandbox supervisord conf): $CONF"
  fi
done

# supervisord spawns nginx master with user=root; as non-root that setuid
# fails and nginx dies. Removing the line keeps root mode equivalent
# (nginx.conf still drops workers via its own `user` directive).
del "$GEM_DIR/supervisord/nginx.conf" 'user=root'

# ---------------- nginx.conf ----------------
# nginx master writes its pid; /var/run is root-owned.
apply "$GEM_DIR/nginx.conf" \
  'pid /var/run/gem/nginx.pid;' \
  's|^pid /var/run/nginx.pid;$|pid /var/run/gem/nginx.pid;|'

log "all patches applied"
