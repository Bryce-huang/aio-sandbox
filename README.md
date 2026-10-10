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

## 环境变量

除上游 aio-sandbox 的全部环境变量外,本镜像入口新增:

| 变量 | 默认 | 说明 |
|---|---|---|
| `AIO_USER` | 运行 uid 的 passwd 用户名 | 覆盖自动解析的用户名。仅在需要与 passwd 条目不同的名字时设置;设错会导致 `HOME` 指向不存在的目录 |

## 相对上游的改动(全部为构建期)

1. 预建平台用户 `app`(6001)/`apps`(6000)及 home 目录
2. 预建 `/var/run/gem`、`/var/log/gem`、`/var/lib/aio-sandbox`、`/var/lib/nginx`、`/run/user/{6000,6001}`、`/etc/browser/policies/managed` 并放权
3. `/opt/gem`、`/opt/aio`、`/opt/jupyter` 运行期可写
4. 入口脚本幂等补丁:`gem_init.sh`/`gem.sh` 的 root 依赖 chmod/chown 改为失败容忍;`supervisord.conf`(含 `/etc` 副本)socket/pidfile 移至 `/var/run/gem`、去掉 `user=root`;`supervisord/nginx.conf` 去掉 `user=root`;`nginx.conf` pid 移至 `/var/run/gem`;`su - $USER` 在 uid 匹配时改为直接执行(避免 PAM 密码提示挂起)
5. ENTRYPOINT 包装:`/usr/local/bin/aio-entrypoint.sh` 按运行 uid 注入 `USER/USER_UID/USER_GID`

## 已知限制

- 仅支持 uid 6000(apps)/6001(app);无 passwd 条目的其他 uid 会在入口处拒绝启动,有 passwd 条目的其他 uid 虽能通过入口检查,仍可能在启动过程中失败
- 仅 `linux/amd64`
- 设置 `PROXY_SERVER` 时 nginx 需绑定 127.0.0.1:80/443,非 root 下该场景不可用(默认配置不受影响)
- root 模式下 supervisor control socket 为 root:root 0770(原 chown=root:%(ENV_USER)s 行已移除),以 root 启动时容器内非 root 用户调用 supervisorctl(如 browser-ctl.sh)可能无法连接;非 root 模式不受影响
