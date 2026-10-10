# AIO Sandbox 非 root 兼容镜像 — 设计文档

日期:2026-10-10
状态:已批准

## 背景与目标

基于 [agent-infra/sandbox](https://github.com/agent-infra/sandbox) 官方镜像(ENTRYPOINT `/opt/gem/run.sh`,设计为 root 启动后在运行时创建 `gem` 用户 uid 1000),构建一个派生镜像,使其能以**非 root 用户 `app`(uid 6001)/ `apps`(uid 6000)运行**,修复启动报错:

```
INFO run: starting trusted init stage
mkdir: cannot create directory '/var/run/gem': Permission denied
mkdir: cannot create directory '/var/log/gem': Permission denied
```

产物通过 GitHub Actions 构建并推送到 DockerHub `brycehuang/aio-sandbox`。本地不执行任何 docker 构建,构建验证全部在 CI 完成。

## 问题根源(已验证)

- `gem_init.sh`(trusted init stage):`RUN_DIR=/var/run/gem` 硬编码,`mkdir -p /var/run/gem /var/log/gem` + `chmod 750`,脚本 `set -euo pipefail`,非 root 必挂。
- `gem.sh`(runtime stage):运行时 `useradd` 创建用户、大量 `chown`(root-owned 目录)、写 `/opt/gem` 下渲染配置、`/var/lib/aio-sandbox`、`/tmp/.X11-unix` 清理等 root 依赖。
- `supervisord.conf`:`user=root`、`pidfile=/var/run/supervisord.pid`、`unix_http_server file=/var/run/supervisor.sock`、`chown=root:%(ENV_USER)s`。
- `supervisord/nginx.conf`:nginx master `user=root`。
- 可行前提(已确认):supervisord 所有子服务配置都用 `%(ENV_USER)s` 动态取用户;镜像内无 `gem` 用户(运行时创建),`/home` 构建时为空。

## 方案(已批准:派生镜像)

`FROM ghcr.io/agent-infra/sandbox:<上游版本>`,构建期以 root 一次性完成兼容层,运行期零 root 依赖:

1. **用户**:创建 `apps`(6000/6000)、`app`(6001/6001),带 home 目录与 bash shell → 平台 `--user 6000/6001` 时 `getent`/`su`/`chown` 全部可解析。
2. **目录放权**:预创建 `/var/run/gem`(0777)、`/var/log/gem`(1777)、`/var/lib/aio-sandbox` 及其 `nginx/{body,proxy,fastcgi,scgi,uwsgi}` 子目录(0777)、`/var/lib/nginx`(1777)、`/run/user/6000`、`/run/user/6001`(各 0700 属主对应用户)、`/etc/browser/policies/managed`(0777)。
3. **可写化**:`chmod -R a+rwX /opt/gem /opt/aio /opt/jupyter`(运行时需写渲染后的 nginx/mcp-hub/gost/proxy.pac 配置与 index.html)。
4. **入口脚本补丁**(sed,幂等,每处带 pattern 守卫,只改必要点,全部为失败容忍型):
   - `gem_init.sh`:`chmod 750 "${RUN_DIR}"` → 追加 `2>/dev/null || true`。
   - `gem.sh`:root-owned 目录上的 `chmod/chown`(LOG_DIR、RUN_DIR、/var/lib/aio-sandbox、nginx 运行时目录、/opt/jupyter、/tmp/.X11-unix 的 `rm -rf` 等)→ `2>/dev/null || true`。
   - `supervisord.conf`:删除 `user=root` 行与 `chown=root:%(ENV_USER)s` 行;`pidfile`/`socket`/`serverurl` 由 `/var/run/` 改到 `/var/run/gem/`。
   - `supervisord/nginx.conf`:删除 `user=root` 行(非 root master 下 nginx 忽略 `user nobody` 指令仅告警,worker 以当前用户运行,temp 目录已放权)。
5. **新 ENTRYPOINT** `/usr/local/bin/aio-entrypoint.sh`:`id -u` 为 0 时直接 `exec /opt/gem/run.sh`(保持 root 兼容);非 0 时按当前 uid 用 `getent` 解析出用户名,导出 `USER`/`USER_UID`/`USER_GID`/`HOME` 再 `exec /opt/gem/run.sh`。
6. **root 模式保持兼容**:所有补丁均为失败容忍型或路径无关,以 root 启动行为不变。

## CI/CD(.github/workflows/build-push.yml)

- 触发:`workflow_dispatch`、push 到 main(限 Dockerfile/docker/** 变更)、每周 schedule(跟随上游)。
- 流程:查上游 `agent-infra/sandbox` latest release → `docker/setup-buildx` → DockerHub 登录(secrets)→ 构建 `linux/amd64`(单架构)→ **冒烟测试**(以 `--user 6001:6001` 启动,轮询 `curl localhost:8080` 直到 200,超时 5 分钟失败即终止)→ 推送。
- 镜像 tag:`latest` + `{上游版本}-{YYYYMMDD}`(如 `1.11.0-20261009`)。
- Secrets:`DOCKERHUB_USERNAME=brycehuang`、`DOCKERHUB_TOKEN`。
- GitHub 仓库:新建公开仓库 `brycehuang/aio-sandbox`。

## 验收标准

1. CI 全绿:构建成功 + `--user 6001:6001` 冒烟测试通过(HTTP 8080 可访问)。
2. 不再出现 `mkdir: cannot create directory '/var/run/gem'` 报错。
3. root 启动模式仍可正常工作(补丁不破坏原行为)。

## 明确不做(YAGNI)

- 不支持除 6000/6001 之外的任意 uid(平台固定这两个)。
- 不构建 arm64(用户明确只要 amd64)。
- 不设置 `PROXY_SERVER` 场景下的非 root 绑定 80/443(默认配置不涉及;后续有需要再处理)。
- 不复刻官方 Dockerfile、不搬运火山引擎源镜像。
