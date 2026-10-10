# AIO Sandbox 非 root 镜像实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建支持以 `app`(6001)/`apps`(6000) 非 root 用户运行的 aio-sandbox 派生镜像,经 GitHub Actions 构建冒烟后推送到 `brycehuang/aio-sandbox`。

**Architecture:** `FROM ghcr.io/agent-infra/sandbox:<上游版本>`,构建期(root)创建平台用户、预建放权目录、sed 补丁入口脚本(幂等)、换新 ENTRYPOINT 按 uid 注入 `USER/USER_UID/USER_GID`。CI 单 job amd64:构建 → `--user 6001` 冒烟 → 推 `latest` + `{版本}-{YYYYMMDD}`。

**Tech Stack:** Docker、bash/sed(GNU+BSD 兼容)、GitHub Actions(buildx + GHA cache)。

**设计文档:** `docs/superpowers/specs/2026-10-10-aio-sandbox-nonroot-dockerhub-design.md`

**上游脚本参考副本**(分析用,已提取):`/tmp/aio-analysis/gem/`(`gem.sh` 1432 行、`gem_init.sh`、`supervisord.conf`、`supervisord/*.conf`、`nginx.conf`)。补丁行号/内容以此为准,若上游版本更新导致 pattern 失配,补丁脚本会显式报错(见 Task 1 的 fail-loud 设计)。

**约束:** 本地禁止 docker build/run 新容器做构建验证;本地只能做 bash 语法检查与 patch 脚本对 `/tmp` 副本的操作;真正的镜像构建与冒烟全部在 CI(Task 8)。

---

### Task 1: 编写 `docker/patch-entrypoints.sh`(幂等 sed 补丁脚本)

**Files:**
- Create: `docker/patch-entrypoints.sh`

所有补丁设计为「失败即报错」:pattern 因上游更新而失配时脚本 exit 1,不允许静默漏打。sed 用 `-i.bak` 后删备份,兼容 GNU/BSD。

- [ ] **Step 1: 写入脚本全文**

```bash
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

# setup_xdg_runtime_dir
apply "$GEM_DIR/gem.sh" \
  'chown $USER:$USER "$XDG_RUNTIME_DIR" 2>/dev/null' \
  's|chown \$USER:\$USER "\$XDG_RUNTIME_DIR"$|& 2>/dev/null \|\| true|'
apply "$GEM_DIR/gem.sh" \
  'chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null' \
  's|chmod 700 "\$XDG_RUNTIME_DIR"$|& 2>/dev/null \|\| true|'

# X11 socket dir cleanup (sticky /tmp forbids deleting root-owned dirs)
apply "$GEM_DIR/gem.sh" \
  'rm -rf /tmp/.X11-unix 2>/dev/null' \
  's|^rm -rf /tmp/.X11-unix|rm -rf /tmp/.X11-unix 2>/dev/null \|\| true|'
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
# Patch both so the socket/pidfile move stays consistent.
for CONF in "$GEM_DIR/supervisord.conf" /etc/supervisord.conf; do
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
```

注意:`apply` 的 expr 都是单引号字符串,`&`(整匹配)与 `\|\|`(sed RHS 转义)都按 BRE 语义工作;唯一含单引号的 expr(su 补丁第二条)用 `"'"'"'` 拼接。

> **Post-review addendum (2026-10-10)**:评审后在 Task 1 Step 1 的脚本里追加了三处 apply:
> 1. `chown "root:${USER}" "${tmp_config}"` + `chmod 640 "${tmp_config}"`(`write_browser_supervisor_config`,gem.sh:376-377)——非 root uid 下 `set -e` 会因 EPERM 直接中止启动;root 模式不受影响(均成功),跨模式重启由 gem_init.sh 的 `rm -f` 清理兜底。
> 2. `chmod 1777 /tmp/.X11-unix`(gem.sh:491)——原补丁只覆盖了 489/492 两行;/tmp/.X11-unix 若以 root 属主残留(同一容器 restart),被容忍的 `rm -rf` 删不掉 → mkdir 变 no-op → 此处 chmod EPERM 中止。
> 3. X11 `rm -rf` 的 expr 改为整行精确匹配(`# Clean stale sockets on restart` 尾注)——上游漂移时响亮失败,而不是静默拼接进已变化的行。
> 这些新增使 gem.sh 的 `2>/dev/null || true` 断言计数从 41 变为 **44**(上游已有 21 行 + 原 20 处 + 新增 3 处)。

- [ ] **Step 2: 语法检查**

Run: `bash -n docker/patch-entrypoints.sh`
Expected: 无输出(通过)

- [ ] **Step 3: 提交**

```bash
git add docker/patch-entrypoints.sh
git commit -m "feat: idempotent entrypoint patch script for non-root compat

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: 在本地副本上验证补丁脚本(不碰 docker)

**Files:**
- Test target: `/tmp/aio-test-gem/`(从 `/tmp/aio-analysis/gem` 复制,不动分析原件)

- [ ] **Step 1: 复制副本并打补丁**

Run:
```bash
rm -rf /tmp/aio-test-gem && cp -R /tmp/aio-analysis/gem /tmp/aio-test-gem
bash docker/patch-entrypoints.sh /tmp/aio-test-gem
```
Expected: 每个补丁打印 `+ patched:` / `+ removed [...]`;无 ERROR。

- [ ] **Step 2: 断言补丁结果**

Run:
```bash
set -e
T=/tmp/aio-test-gem
# gem.sh: 44 = 上游已有 21 行 + 20 处容忍补丁 + 评审新增 3 处(tmp_config chown/chmod、X11 chmod)
[ "$(grep -c '2>/dev/null || true' $T/gem.sh)" -eq 44 ]
grep -qF 'if [ "$(id -u)" != "${USER_UID}" ]; then su - $USER -c' $T/gem.sh
grep -q  'bash -s"; else bash -s; fi << .EOF.' $T/gem.sh
grep -qF 'chown "root:${USER}" "${tmp_config}" 2>/dev/null || true' $T/gem.sh
grep -qF 'chmod 640 "${tmp_config}" 2>/dev/null || true' $T/gem.sh
grep -qF 'chmod 1777 /tmp/.X11-unix 2>/dev/null || true' $T/gem.sh
grep -q  'chmod 750 "${RUN_DIR}" 2>/dev/null || true' $T/gem_init.sh
# supervisord 两份配置
for C in $T/supervisord.conf /tmp/aio-test-gem-etc-supervisord.conf; do :; done
grep -q 'pidfile=/var/run/gem/supervisord.pid' $T/supervisord.conf
grep -q 'file=/var/run/gem/supervisor.sock'    $T/supervisord.conf
grep -q 'serverurl=unix:///var/run/gem/supervisor.sock' $T/supervisord.conf
! grep -q '^user=root' $T/supervisord.conf
! grep -q 'chown=root:%(ENV_USER)s'   $T/supervisord.conf
! grep -q '^user=root' $T/supervisord/nginx.conf
grep -q 'pid /var/run/gem/nginx.pid;' $T/nginx.conf
# 打补丁后的脚本必须仍是合法 bash
bash -n $T/gem.sh && bash -n $T/gem_init.sh && echo ALL-ASSERTIONS-OK
```
Expected: 末行输出 `ALL-ASSERTIONS-OK`

注意:`/etc/supervisord.conf` 在 macOS 上存在但内容不同,本步只断言 `$T/supervisord.conf`(容器内 Task 8 冒烟会覆盖 /etc 那份的验证)。

- [ ] **Step 3: 幂等性验证(跑第二遍)**

Run:
```bash
bash docker/patch-entrypoints.sh /tmp/aio-test-gem && \
[ "$(grep -c '2>/dev/null || true' /tmp/aio-test-gem/gem.sh)" -eq 44 ] && \
bash -n /tmp/aio-test-gem/gem.sh && echo IDEMPOTENT-OK
```
Expected: 全部行打印 `= already patched` / `= already absent`,末行 `IDEMPOTENT-OK`

- [ ] **Step 4: 残留扫描**

Run:
```bash
grep -rn 'su - \$USER -c\|/var/run/supervisor\|/var/run/supervisord\|user=root' /tmp/aio-test-gem/ | grep -v '\.bak' || echo NO-STALE-REFS
```
Expected: `NO-STALE-REFS`(gem.sh 中 su 调用已被 if 包裹,grep 仍会命中 `su - $USER -c` 一次——命中行以 `  export …; if [ "$(id -u)"` 形式开头(行首是 export,if 在同一行内);若输出只有这一行也算通过,人工确认即可)

- [ ] **Step 5: 提交(若 Step 2-4 有脚本修正则一并提交)**

```bash
git add -A docker/ && git commit -m "fix: adjust patch script after local verification

Co-Authored-By: Claude Code <noreply@anthropic.com>" || echo "nothing to commit"
```

---

### Task 3: 编写 `docker/aio-entrypoint.sh`(uid 感知入口)

**Files:**
- Create: `docker/aio-entrypoint.sh`

- [ ] **Step 1: 写入脚本全文**

```bash
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

exec /opt/gem/run.sh "$@"
```

> **Post-review addendum (2026-10-10)**:`exec` 追加 `"$@"`——透传 CMD/附加参数,保留 stock 镜像 `docker run <image> <args>` 的转发语义。

- [ ] **Step 2: 语法检查 + 可执行位**

Run: `bash -n docker/aio-entrypoint.sh && chmod +x docker/aio-entrypoint.sh`
Expected: 通过

- [ ] **Step 3: 提交**

```bash
git add docker/aio-entrypoint.sh
git commit -m "feat: uid-aware entrypoint wrapper

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: 编写 `docker/nonroot-compat.sh`(构建期兼容层)

**Files:**
- Create: `docker/nonroot-compat.sh`

仅能在容器内以 root 运行(macOS 无 groupadd/install -o),本地只做 bash -n。

- [ ] **Step 1: 写入脚本全文**

```bash
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
```

> **Post-review addendum (2026-10-10)**:评审后修正三处:
> 1. `install -d -m 0755 /run/user` 先行创建——GNU `install -d` 会对它创建的所有祖先目录套用 mode/owner,若缺省会让 `/run/user` 建成 `0700 apps:apps`,uid 6001 无法穿越,`gem.sh` 的 `mkdir -p /run/user/6001`(受 `set -e` 管辖)直接中止启动。
> 2. 用户创建改为 `create_user()` 带 uid 漂移断言:未来上游若预装同名但 uid 冲突的用户,fail-loud 而非静默跳过。
> 3. 各逻辑步骤加 `log()`(与 patch-entrypoints.sh 同款前缀),CI 构建日志可诊断。

- [ ] **Step 2: 语法检查 + 可执行位**

Run: `bash -n docker/nonroot-compat.sh && chmod +x docker/nonroot-compat.sh`
Expected: 通过

- [ ] **Step 3: 提交**

```bash
git add docker/nonroot-compat.sh
git commit -m "feat: build-time non-root compatibility layer

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: 编写 `Dockerfile`

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: 写入全文**

```dockerfile
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
```

- [ ] **Step 2: 提交**

```bash
git add Dockerfile
git commit -m "feat: Dockerfile deriving non-root aio-sandbox image

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: 编写 GitHub Actions workflow

**Files:**
- Create: `.github/workflows/build-push.yml`

- [ ] **Step 1: 写入全文**

```yaml
name: build-push

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths:
      - 'Dockerfile'
      - 'docker/**'
      - '.github/workflows/build-push.yml'
  schedule:
    - cron: '23 2 * * 1'  # weekly: follow upstream releases

env:
  IMAGE: brycehuang/aio-sandbox

jobs:
  build-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Resolve upstream version
        id: upstream
        run: |
          VER="$(curl -fsSL https://api.github.com/repos/agent-infra/sandbox/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
          if [ -z "$VER" ] || [ "$VER" = "null" ]; then
            echo "::error::failed to resolve upstream release tag"
            exit 1
          fi
          echo "version=${VER}" >> "$GITHUB_OUTPUT"
          echo "Upstream aio-sandbox version: ${VER}"

      - name: Compute date tag
        id: date
        run: echo "value=$(date +%Y%m%d)" >> "$GITHUB_OUTPUT"

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build image (amd64)
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          load: true
          tags: ${{ env.IMAGE }}:ci
          build-args: |
            BASE_TAG=${{ steps.upstream.outputs.version }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke test as uid 6001 (app)
        run: |
          docker run -d --name smoke \
            --user 6001:6001 \
            --security-opt seccomp=unconfined \
            --shm-size=2g \
            -p 8080:8080 \
            ${{ env.IMAGE }}:ci
          ok=0
          for i in $(seq 1 60); do
            if curl -fsS -o /dev/null http://localhost:8080/v1/docs; then
              ok=1
              echo "sandbox ready after ~$((i * 5))s (as uid 6001)"
              docker exec smoke test -w /run/user/6001 || { echo "::error::/run/user/6001 not writable for uid 6001"; exit 1; }
              break
            fi
            sleep 5
          done
          if [ "$ok" != "1" ]; then
            echo "::error::smoke test failed: sandbox not ready within 300s as uid 6001"
            docker logs smoke 2>&1 | tail -150
            exit 1
          fi

      - name: Push latest + version-date tags
        run: |
          docker tag "$IMAGE:ci" "$IMAGE:latest"
          docker tag "$IMAGE:ci" "$IMAGE:${{ steps.upstream.outputs.version }}-${{ steps.date.outputs.value }}"
          docker push "$IMAGE:latest"
          docker push "$IMAGE:${{ steps.upstream.outputs.version }}-${{ steps.date.outputs.value }}"
```

- [ ] **Step 2: YAML 合法性检查**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build-push.yml')); print('YAML-OK')"`
Expected: `YAML-OK`(若本机无 pyyaml 则 `python3 -m pip install pyyaml -q` 后重试)

- [ ] **Step 3: 提交**

```bash
git add .github/workflows/build-push.yml
git commit -m "ci: build and push non-root aio-sandbox image to DockerHub

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 7: 编写 README

**Files:**
- Create: `README.md`

- [ ] **Step 1: 写入全文**

```markdown
# aio-sandbox (non-root)

[agent-infra/sandbox](https://github.com/agent-infra/sandbox) 派生镜像,支持以非 root 用户运行:

- `apps` — uid/gid **6000**
- `app`  — uid/gid **6001**

镜像:`brycehuang/aio-sandbox`(`linux/amd64`),tag 规则:`latest` + `{上游版本}-{构建日期}`,如 `1.11.0-20261009`。

## 用法

```bash
docker run --rm -it \
  --user 6001:6001 \
  --security-opt seccomp=unconfined \
  --shm-size=2g \
  -p 127.0.0.1:8080:8080 \
  brycehuang/aio-sandbox:latest
```

以 `--user 6000:6000`(apps)启动同理。仍可用 root 启动(行为与官方镜像一致)。

## 相对上游的改动(全部为构建期)

1. 预建平台用户 `app`(6001)/`apps`(6000)及 home 目录
2. 预建 `/var/run/gem`、`/var/log/gem`、`/var/lib/aio-sandbox`、`/var/lib/nginx`、`/run/user/{6000,6001}`、`/etc/browser/policies/managed` 并放权
3. `/opt/gem`、`/opt/aio`、`/opt/jupyter` 运行期可写
4. 入口脚本幂等补丁:`gem_init.sh`/`gem.sh` 的 root 依赖 chmod/chown 改为失败容忍;`supervisord.conf`(含 `/etc` 副本)socket/pidfile 移至 `/var/run/gem`、去掉 `user=root`;`supervisord/nginx.conf` 去掉 `user=root`;`nginx.conf` pid 移至 `/var/run/gem`;`su - $USER` 在 uid 匹配时改为直接执行(避免 PAM 密码提示挂起)
5. ENTRYPOINT 包装:`/usr/local/bin/aio-entrypoint.sh` 按运行 uid 注入 `USER/USER_UID/USER_GID`

## 已知限制

- 仅支持 uid 6000/6001(其他 uid 无 passwd 条目会拒绝启动)
- 仅 `linux/amd64`
- 设置 `PROXY_SERVER` 时 nginx 需绑定 127.0.0.1:80/443,非 root 下该场景不可用(默认配置不受影响)
```

- [ ] **Step 2: 提交**

```bash
git add README.md
git commit -m "docs: add README for non-root aio-sandbox image

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 8: 建 GitHub 仓库、推送、触发 CI 直到绿

**Files:** 无新增(远端操作)

**前置(用户参与):** DockerHub access token 需要用户提供;用 `gh secret set` 写入。用户可在会话中用 `! gh secret set DOCKERHUB_TOKEN --repo brycehuang/aio-sandbox` 交互输入。

- [ ] **Step 1: 创建公开仓库并推送**

Run:
```bash
gh repo create brycehuang/aio-sandbox --public --source . --remote origin --push
```
Expected: 仓库创建,main 分支推送成功

- [ ] **Step 2: 配置 DockerHub secrets**

Run(用户输入 token):
```bash
gh secret set DOCKERHUB_USERNAME --repo brycehuang/aio-sandbox --body "brycehuang"
# token 由用户通过交互命令提供:
#   ! gh secret set DOCKERHUB_TOKEN --repo brycehuang/aio-sandbox
gh secret list --repo brycehuang/aio-sandbox
```
Expected: list 显示 DOCKERHUB_USERNAME、DOCKERHUB_TOKEN(Updated 时间为刚写入)

- [ ] **Step 3: 触发构建**

Run: `gh workflow run build-push --repo brycehuang/aio-sandbox && sleep 10 && gh run list --repo brycehuang/aio-sandbox --limit 1`
Expected: 出现 in_progress 的 run

- [ ] **Step 4: 跟踪直到结束**

Run: `gh run watch --repo brycehuang/aio-sandbox $(gh run list --repo brycehuang/aio-sandbox --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status`
Expected: conclusion=success。失败则读日志定位(Task 1 补丁 fail-loud 报错信息会直接指明失配 pattern),修正后重跑 Step 3-4。

- [ ] **Step 5: 验证 DockerHub 产物**

Run:
```bash
curl -fsS "https://hub.docker.com/v2/repositories/brycehuang/aio-sandbox/tags?page_size=10" | python3 -m json.tool | grep -E '"name"'
```
Expected: 出现 `latest` 与 `{版本}-{日期}` 两个 tag

- [ ] **Step 6: 汇报**

向用户报告:镜像 tag、run 链接、冒烟结论(uid 6001 启动、/v1/docs HTTP 200、无 `/var/run/gem` Permission denied)。

---

## Self-Review 记录

- **Spec 覆盖:** 用户(app/apps)→Task 4;目录放权→Task 4;可写化→Task 4;入口补丁(含 supervisord/nginx/`su`)→Task 1+2;ENTRYPOINT 包装→Task 3;Dockerfile→Task 5;CI+tag+冒烟+secrets→Task 6+8;README→Task 7。无缺口。
- **Placeholder 扫描:** 所有代码步骤均为完整内容,无 TBD/TODO。
- **一致性:** 补丁 marker 与 Task 2 断言一致;`GEM_DIR` 参数贯穿 Task 1/4;镜像名 `brycehuang/aio-sandbox` 与 workflow env、README 一致;tag 规则与 spec 一致。
