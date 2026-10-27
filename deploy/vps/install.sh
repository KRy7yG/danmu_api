#!/usr/bin/env bash
# 一键在 Ubuntu/Debian VPS 上装好：Docker + 仓库 + 反代（可选 danmu_api 本体）
# + systemd timer（每 10 分钟跟随 GitHub 更新）
#
# 用法：
#   sudo bash install.sh              # 只装反代
#   sudo WITH_APP=1 bash install.sh   # 反代 + danmu_api 本体（推荐，CN 源全通）
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/KRy7yG/danmu_api.git}"
REPO_DIR="${REPO_DIR:-/opt/danmu-api}"
BRANCH="${BRANCH:-main}"
WITH_APP="${WITH_APP:-0}"

log() { printf '[install] %s\n' "$*"; }

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 或 sudo 运行" >&2
  exit 1
fi

# ---------- 1. 依赖 ----------
if ! command -v git >/dev/null 2>&1; then
  log "安装 git"
  apt-get update -qq
  apt-get install -y -qq git curl ca-certificates
fi

if ! command -v docker >/dev/null 2>&1; then
  log "安装 Docker"
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker >/dev/null 2>&1 || true

if ! openssl version >/dev/null 2>&1; then
  apt-get install -y -qq openssl
fi

# ---------- 2. 仓库 ----------
if [ -d "$REPO_DIR/.git" ]; then
  log "更新已有仓库 $REPO_DIR"
  git -C "$REPO_DIR" fetch --prune origin "$BRANCH"
  git -C "$REPO_DIR" merge --ff-only "origin/$BRANCH"
else
  log "克隆 $REPO_URL 到 $REPO_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

# ---------- 3. 配置 ----------
ENV_FILE="$REPO_DIR/deploy/vps/.env"
if [ ! -f "$ENV_FILE" ]; then
  cp "$REPO_DIR/deploy/vps/.env.example" "$ENV_FILE"
  SECRET="$(openssl rand -hex 24)"
  sed -i "s/^PROXY_SECRET=.*/PROXY_SECRET=$SECRET/" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "已生成 .env（PROXY_SECRET=$SECRET）"
fi

SECRET="$(grep -E '^PROXY_SECRET=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')"
if [ -z "$SECRET" ] || [ "$SECRET" = "change-me-to-a-long-random-string" ]; then
  SECRET="$(openssl rand -hex 24)"
  sed -i "s/^PROXY_SECRET=.*/PROXY_SECRET=$SECRET/" "$ENV_FILE"
  log "已重新生成 PROXY_SECRET"
fi

if [ "$WITH_APP" = "1" ]; then
  if ! grep -qE '^PROXY_URL=.+' "$ENV_FILE"; then
    sed -i "s|^PROXY_URL=.*|PROXY_URL=@http://proxy:8787/$SECRET|" "$ENV_FILE"
    log "已把 PROXY_URL 指向本机反代"
  fi
fi

chmod +x "$REPO_DIR/deploy/vps/update.sh"

# ---------- 4. systemd timer（跟随仓库更新）----------
cat >/etc/systemd/system/danmu-update.service <<UNIT
[Unit]
Description=danmu-api 跟随 GitHub 更新（git pull + docker compose）
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=REPO_DIR=$REPO_DIR
Environment=WITH_APP=$WITH_APP
ExecStart=$REPO_DIR/deploy/vps/update.sh
UNIT

cat >/etc/systemd/system/danmu-update.timer <<UNIT
[Unit]
Description=每 10 分钟检查 danmu-api 仓库更新

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Unit=danmu-update.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now danmu-update.timer >/dev/null
log "已启用 danmu-update.timer（每 10 分钟）"

# ---------- 5. 启动 ----------
cd "$REPO_DIR/deploy/vps"
if [ "$WITH_APP" = "1" ]; then
  docker compose --profile app up -d --build
else
  docker compose up -d --build
fi

# ---------- 6. 防火墙提示 + 输出 ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  PROXY_PORT="$(grep -E '^PROXY_PORT=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')"
  ufw allow "${PROXY_PORT:-8787}/tcp" >/dev/null || true
  log "已放行 ufw ${PROXY_PORT:-8787}/tcp"
fi

IP="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || echo '<你的VPS_IP>')"
PROXY_PORT="$(grep -E '^PROXY_PORT=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')"
PROXY_PORT="${PROXY_PORT:-8787}"

cat <<EOF

================ 完成 ================
反代地址（给 Vercel 用）：
  http://$IP:$PROXY_PORT/$SECRET

在 Vercel 的 danmu-api 项目里设置：
  PROXY_URL = @http://$IP:$PROXY_PORT/$SECRET
然后 Redeploy 即可让 douban/360/renren/hanjutv 等中国源恢复。

自检：
  curl -s -m 20 "http://$IP:$PROXY_PORT/$SECRET/https://api.so.360kan.com/index?force_v=1&kw=%E7%B9%81%E8%8A%B1&pageno=1&v_ap=1&tab=all" | head -c 200

跟随仓库更新：
  systemctl status danmu-update.timer     # 每 10 分钟
  journalctl -u danmu-update.service -n 30
  $REPO_DIR/deploy/vps/update.sh          # 手动立即更新

本地 danmu_api 实例（WITH_APP=1 时）：
  http://$IP:${DANMU_PORT:-9321}/{TOKEN}/api/v2/search/anime?keyword=繁花
======================================
EOF
