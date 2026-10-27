# VPS 部署（反代 + 可选 danmu_api 本体）

目标：让 Vercel 上打不通的中国源恢复，并且 **VPS 会自动跟随本仓库更新**。

## 一键安装（Ubuntu/Debian，root）

```bash
# 只装反代（Vercel 继续当主入口，改动最小）
curl -fsSL https://raw.githubusercontent.com/KRy7yG/danmu_api/main/deploy/vps/install.sh | sudo bash

# 反代 + danmu_api 本体（推荐：CN 源全通，延迟最低）
curl -fsSL https://raw.githubusercontent.com/KRy7yG/danmu_api/main/deploy/vps/install.sh | sudo WITH_APP=1 bash
```

装完会打印：

```
反代地址（给 Vercel 用）：
  http://<VPS_IP>:8787/<随机SECRET>
在 Vercel 的 danmu-api 项目里设置：
  PROXY_URL = @http://<VPS_IP>:8787/<随机SECRET>
```

脚本做的事：装 Docker → clone 仓库到 `/opt/danmu-api` → 生成 `.env`（随机 `PROXY_SECRET`）→
装 `danmu-update.timer` → `docker compose up -d --build` → 放行 ufw 端口。

机器建议：香港/日本 1 vCPU / 1 GB 内存足够；只跑反代 512 MB 也行。

## 跟随仓库更新怎么保证

```
systemd timer (每 10 分钟)
  └─ update.sh
       ├─ git fetch origin main
       ├─ git merge --ff-only      # 分叉就报错退出，不会静默搞乱代码
       └─ HEAD 有变 → docker compose up -d --build --force-recreate
```

- 只要 `main` 有新提交（包括上游同步进来的提交），最多 10 分钟自动生效。
- `--ff-only` 保证 VPS 上永远是 GitHub 的历史，不会产生本地合并提交。
- 想立即更新：`/opt/danmu-api/deploy/vps/update.sh`
- 看日志：`journalctl -u danmu-update.service -n 50`

反代容器把仓库以**只读**挂进 `/repo`，代码更新后 `--force-recreate` 会让新代码生效；
`danmu_api` 本体是构建镜像，会重新 build。

### 想改成立即部署（push 即生效）

在仓库加 `.github/workflows/deploy-vps.yml`，用 `appleboy/ssh-action` 在 push 时执行
`/opt/danmu-api/deploy/vps/update.sh`，并把 `VPS_HOST / VPS_USER / VPS_SSH_KEY` 存成 GitHub Secrets。
轮询（现在这套）零密钥、更省事；push 式更快，但要管一把 SSH key。

## Vercel 侧要改的只有一个变量

```
PROXY_URL = @http://<VPS_IP>:8787/<SECRET>
```

`@` 表示「万能反代」——所有源都会经 VPS 出口。设完 Redeploy。

此时可以把中国源加回 `SOURCE_ORDER`：

```
SOURCE_ORDER=dandan,bilibili,animeko,bahamut,aiyifan,maiduidui,douban,360,renren,hanjutv
```

只想让部分源走反代时，`PROXY_URL` 支持专用写法（目前代码里写死这几个键）：
`bahamut@`、`tmdb@`、`bilibili@`、`animeko@`、`aiyifan@`；
`douban/360/renren/hanjutv` 没有专用键，只能走 `@` 万能反代。

## 用 WITH_APP=1 时

- danmu_api 本体监听 `${DANMU_PORT:-9321}`，容器内 `PROXY_URL` 默认指向同 compose 的反代。
- 客户端可以直接用 `http://<VPS_IP>:9321/<TOKEN>/...`，不再依赖 Vercel。
- 缓存目录挂载在 `deploy/vps/data/.cache`，重启不丢。

## 安全

- `PROXY_SECRET` 是路径口令，随机 48 位 hex；不带口令 → 403。
- 想更严：`.env` 里设 `PROXY_ALLOW_HOSTS=360kan.com,douban.com,xiawen.tv`，其它 host 直接拒。
- 不要把无口令的反代暴露在公网，Cloudflare/VPS 供应商都会因为滥用封机器。
- `.env` 权限 600，已被 `.gitignore` 忽略（`deploy/vps/.env`）。

## 排错

| 现象 | 处理 |
|---|---|
| `curl` 反代超时 | 安全组/防火墙没放行 `8787`；`ufw status`、云厂商安全组都要开 |
| 反代 200 但 Vercel 仍 0 结果 | `PROXY_URL` 没写 `@` 前缀，或没 Redeploy |
| `docker: command not found` | 用 `sudo` 重跑 install.sh |
| 更新后行为没变 | `journalctl -u danmu-update.service -n 30` 看是否 `--ff-only` 失败（VPS 上被手动改过代码） |
| 想回滚 | `git -C /opt/danmu-api reset --hard <sha>` 然后跑一次 `update.sh` |
